import Foundation
import CoreGraphics

/// "Brain": the state machine that runs the whole loop.
///
///   lobby (click Play) → walkToEvent (walk onto the summer pad until "Join Matchmaking?")
///   → matchmaking (Find Match → read code → type it → Submit)
///   → loadingStage (vote Yes) → playStage (identify map by minimap → replay w/ verification)
///   → results → lobby …
///
/// Every state first *waits until it recognizes its screen* (template or OCR), then acts.
/// If a state times out, it tries to recover by going back to the lobby.
@MainActor
final class MacroEngine: ObservableObject {
    enum State: String {
        case idle, lobby, walkToEvent, matchmaking, enterCode, loadingStage, playStage, results, recovering
    }

    @Published var state: State = .idle
    @Published var log: [String] = []
    @Published var runsCompleted = 0
    @Published var currentMap = ""
    @Published var wins = 0
    @Published var losses = 0
    /// Summer Pearls earned this session (sum of the results panel's "+N") and secrets seen.
    @Published var sessionPearls = 0
    @Published var sessionSecrets = 0
    /// When the last match ended (for the "no match finished in 45 min" Discord ping).
    private var lastMatchEnded = Date()
    private var lastStuckPing = Date.distantPast
    private var secretFoundThisMatch = false

    private func notify(_ text: String, image: CGImage? = nil) {
        let hook = store?.settings.discordWebhook ?? ""
        guard !hook.isEmpty else { return }
        Discord.send(text, image: image, webhook: hook)
    }
    @Published var startedAt: Date?
    weak var store: Store?

    private var task: Task<Void, Never>?

    // MARK: Cards interrupt everything
    /// Set by the watcher when the card screen appears; the next click/key anywhere votes first.
    private var cardsPending: CGImage?
    private var handlingCards = false
    /// Bumped every time a card vote interrupts something, so that routine can tell its last
    /// attempt was disturbed (and not blame the spot).
    private(set) var cardInterrupts = 0
    private var cardWatcher: Task<Void, Never>?

    private func startCardWatcher() {
        InputController.beforeAction = { [weak self] in await self?.yieldToCards() }
        guard cardWatcher == nil else { return }
        cardWatcher = Task { [weak self] in
            while !Task.isCancelled {
                if let self, self.inStage, !self.handlingCards, self.cardsPending == nil,
                   let img = try? await ScreenCapture.captureRoblox(), Self.cardScreenVote(img) != nil {
                    self.cardsPending = img
                }
                try? await Task.sleep(nanoseconds: 800_000_000)
            }
        }
    }
    private func stopCardWatcher() { cardWatcher?.cancel(); cardWatcher = nil; cardsPending = nil }

    /// Pause point: if cards are up, drop whatever unit is held, vote, then return so the
    /// interrupted routine carries on.
    func yieldToCards() async {
        guard !handlingCards, let img = cardsPending else { return }
        handlingCards = true
        cardsPending = nil
        cardInterrupts += 1
        say("Cards! Pausing to vote, then resuming")
        await input.key("q")                                 // let go of a held unit (gate is re-entrant-safe)
        try? await Task.sleep(nanoseconds: 200_000_000)
        cardVotedAt = .distantPast
        try? await handleCards(img)
        handlingCards = false
    }
    /// Keeps the Mac (and its display) awake while the macro runs — a sleeping display stops
    /// Roblox from being drawn, and a locked Mac ignores the macro's clicks.
    private var awakeToken: NSObjectProtocol?
    private func stayAwake(_ on: Bool) {
        if on, awakeToken == nil {
            awakeToken = ProcessInfo.processInfo.beginActivity(
                options: [.idleDisplaySleepDisabled, .idleSystemSleepDisabled, .userInitiated],
                reason: "AA Macro is running")
        } else if !on, let t = awakeToken {
            ProcessInfo.processInfo.endActivity(t)
            awakeToken = nil
        }
    }
    /// True between match start and results — enables the card watcher.
    private var inStage = false
    /// Consecutive recoveries without a completed run; used to escalate.
    private var recoverAttempts = 0
    /// Buttons that end a match. A loss and a win may show different screens —
    /// drop a template for each into the templates folder; any of them counts.
    private var input: InputController {
        let s = store?.settings ?? MacroSettings()
        return InputController(delayMs: Int(Double(s.inputDelayMs) * max(1, s.lagFactor)))
    }

    /// Every wait goes through here, so the Lag setting slows the whole macro down evenly.
    private func lag(_ ns: UInt64) -> UInt64 {
        UInt64(Double(ns) * max(0.5, store?.settings.lagFactor ?? 1))
    }

    // MARK: - Watchdog
    /// When the current run must have finished by. Past it, the run is treated as stuck.
    private var runDeadline: Date?
    private var lossStreak = 0

    private func checkWatchdog() throws {
        guard let d = runDeadline, Date() > d else { return }
        runDeadline = nil
        inStage = false
        throw MacroError.timedOut("whole run (over \(store?.settings.stuckMinutes ?? 45) min — looked stuck, starting over)")
    }

    /// Map name read off the summer event board before joining (e.g. "magic town").
    private var boardHint = ""
    /// The map name read off the matchmaking popup (big, clean text) — a second opinion for the
    /// stage title, which is often misread.
    private var popupMapHint = ""
    /// Placement cost per hotbar slot, read from the hotbar once per stage.
    private var slotCosts: [Int: Int] = [:]
    /// Set after voting on a weather card so the same vote screen isn't handled twice.
    private var cardVotedAt = Date.distantPast
    /// Raw stage title of the current match (e.g. "Magic Town Summer Hunt").
    private var currentTitle = ""
    /// What auto mode did this match — saved as a recording if the match is won.
    private var autoLog: [MacroAction] = []
    private var lastResultWasVictory = false
    /// Where enemies have been seen this match (their "3.8/3.8" health labels sit on the lane).
    private var enemyLane: [NormPoint] = []
    private var lastEnemyScan = Date.distantPast

    /// Records enemy positions from their health labels. Cheap, throttled to ~1/s.
    private var enemyScanRunning = false
    private func scanEnemies(_ img: CGImage) {
        guard inStage, !enemyScanRunning, Date().timeIntervalSince(lastEnemyScan) > 1.2 else { return }
        lastEnemyScan = Date()
        enemyScanRunning = true
        // The labels are tiny: needs the accurate reader, which is slow — so run it in the
        // background and fold the results in when done (never blocks clicks or cards).
        Task.detached(priority: .utility) { [weak self] in
            let lines = (try? OCR.read(img, region: CGRect(x: 0, y: 0.2, width: 0.79, height: 0.62), fast: false)) ?? []
            await self?.addEnemySightings(lines)
        }
    }

    private func addEnemySightings(_ lines: [OCR.Line]) {
        enemyScanRunning = false
        guard inStage else { return }
        for l in lines {
            let t = l.text.replacingOccurrences(of: " ", with: "")
            // "3.8/3.8", "11572/16167", "44.6K/92.6K" — an enemy health label.
            guard t.range(of: #"\d+(\.\d+)?[KMB]?/\d+(\.\d+)?[KMB]?"#, options: [.regularExpression, .caseInsensitive]) != nil,
                  !AutoPlanner.hud.contains(where: { $0.contains(CGPoint(x: l.box.midX, y: l.box.midY)) }) else { continue }
            // The label floats just above the enemy's feet.
            enemyLane.append(NormPoint(x: l.box.midX, y: min(0.86, l.box.midY + 0.025)))
        }
        if enemyLane.count > 4000 { enemyLane.removeFirst(1000) }
    }

    /// Before the first placement: watch the enemies for a few seconds to learn the lane.
    private func learnLane(seconds: Double) async {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end, enemyLane.count < 60, !Task.isCancelled {
            if let img = try? await ScreenCapture.captureRoblox() {
                scanEnemies(img)
                try? await handleCards(img)
            }
            try? await Task.sleep(nanoseconds: lag(400_000_000))
        }
        say("Lane: \(enemyLane.count) enemy sightings\(enemyLane.count >= 25 ? " — using them as the path" : " — not enough yet, using colours")")
    }

    /// Set once the VICTORY/DEFEAT panel was seen, so the screens after it count as end-of-match.
    private var sawResultPanel = false

    // MARK: - Control

    func start() {
        guard task == nil else { return }
        if (store?.settings.mode ?? .summerHunt) == .portal {
            say("🗺️ Portal mode isn't automatic yet — use Teach portal / Test plan in a portal match. Switch the mode back to Summer Hunt to farm.")
            return
        }
        runsCompleted = 0
        inStage = false; recoverAttempts = 0
        Self.knownLimits = [:]; Self.limitVotes = [:]     // team may have changed since the last start
        DebugLog.cleanup()
        // Preflight: say exactly what's missing instead of silently doing nothing.
        var problems: [String] = []
        if !Permissions.screenRecording { problems.append("Screen Recording permission missing") }
        if !Permissions.accessibility { problems.append("Accessibility permission missing") }
        if WindowManager.robloxFrame() == nil { problems.append("Roblox window not found (open it, windowed, not minimized)") }
        if !problems.isEmpty {
            for p in problems { say("⚠️ \(p)") }
            say("⚠️ Not starting. Running from Xcode? Grant these to Xcode too (System Settings → Privacy & Security), then quit and re-run.")
            return
        }
        DockPanel.shared.releaseKeyboard()
        say("Starting \((store?.settings.mode ?? .summerHunt).rawValue) mode. Press F6 any time to stop.")
        stayAwake(true)
        startCardWatcher()
        startedAt = Date(); wins = 0; losses = 0; lossStreak = 0; runDeadline = nil
        sessionPearls = 0; sessionSecrets = 0; lastMatchEnded = Date(); lastStuckPing = .distantPast
        if let problem = WindowManager.lockAndFocus() { say("⚠️ \(problem)") }
        task = Task { await runLoop() }
    }

    /// Diagnose button: screenshot + full OCR dump into the logs folder, without running anything.
    func diagnose() {
        Task {
            say("Diagnose: capturing screen + OCR → logs folder")
            let r = await DebugLog.snapshot("diagnose")
            say(r.contains("Capture failed") ? "⚠️ Diagnose: capture failed (see logs)" : "Diagnose saved")
        }
    }

    /// Camera button: run just the zoom-out + top-down step, then snapshot the result.
    func testCamera() {
        Task {
            WindowManager.lockAndFocus()
            try? await Task.sleep(nanoseconds: lag(400_000_000))
            say("Camera test: zooming out + top-down")
            var s = store?.settings ?? MacroSettings(); s.cameraReset = true
            await Camera.reset(input, settings: s)
            await DebugLog.snapshot("camera")
            say("Camera test done (screenshot saved to logs)")
        }
    }

    func stop() {
        if let st = startedAt, wins + losses > 0 {
            let h = max(Date().timeIntervalSince(st) / 3600, 0.01)
            notify("⏹ AA Macro stopped — \(wins)W / \(losses)L, \(sessionPearls) Summer Pearls (\(Int(Double(sessionPearls) / h))/h)"
                   + (sessionSecrets > 0 ? ", ✦ \(sessionSecrets) secret(s)" : "") + String(format: " in %.1f h", h))
        }
        stayAwake(false)
        stopCardWatcher()
        task?.cancel(); task = nil
        scanTask?.cancel(); scanTask = nil; scanning = false
        if manualTeachTask == nil { teachNowActive = false; teachNextMatch = false }
        startedAt = nil
        state = .idle
        say("Stopped.")
    }

    private func say(_ s: String) {
        let t = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        log.append("[\(t)] \(s)")
        if log.count > 500 { log.removeFirst(100) }
        DebugLog.append("[\(t)] [\(state.rawValue)] \(s)")
    }

    // MARK: - Main loop

    private func runLoop() async {
        state = .lobby
        while !Task.isCancelled {
            WindowManager.ensureLocked()          // keeps every run pixel-identical
            do {
                // Outside matchmaking/voting, clear anything blocking the screen first.
                if [.lobby, .walkToEvent, .results, .recovering].contains(state) {
                    if await handleDisconnect() { continue }
                    if await choosePrivateServer() { continue }
                    await clearPopups()
                }
                switch state {
                case .lobby:        try await doLobby()
                case .walkToEvent:
                    switch store?.settings.mode ?? .summerHunt {
                    case .summerHunt: try await doWalkToEvent()
                    case .portal: stop(); return          // never reached: start() blocks Portal mode
                    }
                case .matchmaking:  try await doMatchmaking()
                case .enterCode:    break   // handled inside doMatchmaking (needs the code it read)
                case .loadingStage: try await doVote()
                case .playStage:    try await doPlayStage()
                case .results:      try await doResults()
                case .recovering:   try await doRecover()
                case .idle:         return
                }
            } catch is CancellationError {
                return
            } catch {
                if Task.isCancelled || state == .idle { return }      // stopped mid-wait: not a failure
                say("⚠️ \(error.localizedDescription)")
                await DebugLog.snapshot("fail-\(state.rawValue)")
                state = .recovering
            }
        }
    }

    // MARK: - Popups & disconnects

    /// Buttons that dismiss a popup without doing anything harmful. Matched exactly (whole line).
    private static let dismissWords = ["close", "ok", "okay", "nothanks", "later", "maybelater", "skip",
                                       "continue", "claim", "collect", "decline", "gotit", "dismiss"]
    private var lastPopupCheck = Date.distantPast

    /// Clicks a dismiss button if a popup is blocking the screen (level up, rewards, daily login,
    /// trade/party invites…). Never touches the matchmaking / code / vote / card screens.
    @discardableResult
    private func clearPopups(_ frame: CGImage? = nil) async -> Bool {
        lastPopupCheck = Date()
        var captured = frame
        if captured == nil { captured = try? await ScreenCapture.captureRoblox() }
        guard let img = captured, let lines = try? OCR.read(img, fast: true) else { return false }
        let text = lines.map { OCR.norm($0.text) }
        let protected = ["enterthistext", "joinmatchmaking", "findmatch", "votestart", "weathershifts", "voteends"]
        if text.contains(where: { t in protected.contains { t.contains($0) } }) { return false }
        // Ignore the left HUD buttons (Units, Store, …) and the hotbar.
        let candidates = lines.filter { l in
            !Region.lobbyHUD.contains(CGPoint(x: l.box.midX, y: l.box.midY)) && l.box.midY < 0.85
        }
        guard let button = candidates.first(where: { l in
            let t = OCR.norm(l.text)
            return Self.dismissWords.contains(t) || (t.count <= 8 && ["claim", "close", "decline"].contains { t.hasPrefix($0) })
        }) else { return false }
        say("Popup: clicking \"\(button.text)\"")
        await input.click(button.center)
        try? await Task.sleep(nanoseconds: lag(800_000_000))
        return true
    }

    /// After "Return to lobby" the game asks Public or Private server — always pick Private
    /// (nobody else's units in the way). Returns true if it clicked.
    @discardableResult
    private func choosePrivateServer(_ frame: CGImage? = nil) async -> Bool {
        var captured = frame
        if captured == nil { captured = try? await ScreenCapture.captureRoblox() }
        guard let img = captured, let lines = try? OCR.read(img, fast: true),
              let priv = lines.first(where: { OCR.norm($0.text).contains("privateserver") }),
              lines.contains(where: { OCR.norm($0.text).contains("publicserver") }) else { return false }
        say("Choosing Private Server")
        await input.click(priv.center)
        try? await Task.sleep(nanoseconds: lag(5_000_000_000))           // teleport
        return true
    }

    /// Roblox's "Disconnected" dialog → click Reconnect and start the loop over.
    private func handleDisconnect() async -> Bool {
        guard let img = try? await ScreenCapture.captureRoblox(),
              let lines = try? OCR.read(img, region: Region.centerPopup, fast: true),
              lines.contains(where: { ["disconnected", "lostconnection", "errorcode"].contains(where: OCR.norm($0.text).contains) })
        else { return false }
        say("⚠️ Disconnected from the game")
        await DebugLog.snapshot("disconnected")
        if let rc = lines.first(where: { OCR.norm($0.text).contains("reconnect") }) {
            say("Clicking Reconnect — waiting 30s for the game to load")
            await input.click(rc.center)
            try? await Task.sleep(nanoseconds: lag(30_000_000_000))
        } else {
            say("No Reconnect button — waiting 60s")
            try? await Task.sleep(nanoseconds: lag(60_000_000_000))
        }
        inStage = false
        state = .lobby
        return true
    }

    // MARK: - States

    /// Lobby: click "Play" in the left HUD (exact match, so it ignores "Play Here").
    private func doLobby() async throws {
        say("Lobby: looking for Play")
        runDeadline = Date().addingTimeInterval(Double((store?.settings.stuckMinutes ?? 45) * 60))
        let play = try await poll(timeout: 90, what: "Play button") { img in
            // Already standing on the pad? Skip straight to matchmaking.
            if try OCR.find("join matchmaking", in: img, region: Region.centerPopup) != nil { return NormPoint(x: -1, y: -1) }
            if try OCR.find("enter this text", in: img, region: Region.centerPopup, fast: true) != nil { return NormPoint(x: -1, y: -1) }
            return try OCR.find("play", in: img, region: Region.lobbyHUD, exact: true)?.center
        }
        if play.x < 0 { state = .matchmaking; return }
        await input.click(play)
        state = .walkToEvent
    }

    /// Summer area: note which map the board says is up, then walk onto the pad.
    /// Walking stops the moment "Join Matchmaking?" appears, so small timing
    /// differences don't matter.
    private func doWalkToEvent() async throws {
        say("Walking to summer event")
        try await Task.sleep(nanoseconds: lag(3_000_000_000))          // teleport + load
        if let img = try? await ScreenCapture.captureRoblox(),
           let lines = try? OCR.read(img, region: Region.eventBoard) {
            boardHint = OCR.norm(lines.map(\.text).joined(separator: " "))
        }
        func popupUp() async -> Bool {
            guard let img = try? await ScreenCapture.captureRoblox() else { return false }
            return (try? OCR.find("join matchmaking", in: img, region: Region.centerPopup, fast: true)) != nil
                || (try? OCR.find("enter this text", in: img, region: Region.centerPopup, fast: true)) != nil
        }
        // 1) Recorded walk, in 0.3 s slices so we can stop early.
        for action in store?.settings.lobbyWalk ?? [] {
            if case let .walk(k, secs) = action {
                var left = secs
                while left > 0 {
                    if await popupUp() { state = .matchmaking; return }
                    await input.hold(k, seconds: min(0.3, left)); left -= 0.3
                }
            }
            if case let .wait(secs) = action { try await Task.sleep(nanoseconds: lag(UInt64(secs * 1e9))) }
        }
        // 2) Steer toward the "Summer Event" board — the pad sits right under it. Each step:
        //    read where the board is, strafe (A/D) to keep it centred, then step forward (W).
        //    Works from any spawn spot and walks around players blocking the way.
        var lostBoard = 0
        for step in 0..<45 {
            if await popupUp() { state = .matchmaking; return }
            guard let img = try? await ScreenCapture.captureRoblox() else { continue }
            let board = (try? OCR.read(img, region: CGRect(x: 0.05, y: 0.05, width: 0.90, height: 0.60), fast: true))?
                .first { ["summerevent", "summerhunt", "specialrewards"].contains(where: OCR.norm($0.text).contains) }
            if let board {
                lostBoard = 0
                let off = board.box.midX - 0.5
                if abs(off) > 0.06 { await input.hold(off > 0 ? "d" : "a", seconds: min(0.6, abs(off) * 2.5)) }
                // The board grows as we get closer; take smaller steps once it's big.
                await input.hold("w", seconds: board.box.width > 0.15 ? 0.25 : 0.5)
            } else {
                lostBoard += 1
                // Lost sight of it (too close, or something in front): small step forward,
                // and every few misses sidestep to get around whatever is in the way.
                await input.hold(lostBoard % 4 == 0 ? (step % 8 < 4 ? "a" : "d") : "w", seconds: 0.3)
            }
        }
        throw MacroError.timedOut("Join Matchmaking popup (couldn't reach the summer event pad)")
    }

    /// "Join Matchmaking?" → Find Match → read the code → type it → CHECK it's in the box → Submit.
    /// Every step waits for the screen to confirm it instead of assuming, so lag doesn't break it.
    private func doMatchmaking() async throws {
        let s = store?.settings ?? MacroSettings()
        say("Matchmaking: Find Match")
        popupMapHint = ""
        let find: NormPoint
        do {
            find = try await poll(timeout: 20, what: "Find Match button") { img in
                // The code popup is already up (left open by an earlier try)? Go straight to it.
                if try OCR.find("enter this text", in: img, region: Region.centerPopup, fast: true) != nil {
                    return NormPoint(x: -1, y: -1)
                }
                return try OCR.find("find match", in: img, region: Region.centerPopup)?.center
            }
        } catch {
            say("⚠️ Couldn't see Find Match — saving a screenshot")
            _ = await DebugLog.snapshot("no-find-match")
            throw error
        }
        if find.x >= 0 {
            await input.click(find)
            say("Clicked Find Match — reading the code")
        } else {
            say("Code popup already open — reading the code")
        }

        for attempt in 1...4 {
            // 1) Read the code — and only accept it once the popup has STOPPED moving
            //    (it animates in; positions read mid-animation make the click miss).
            var lastSubmit: CGPoint?
            var lastCode = ""
            var snapped = false
            let start = Date()
            let (code, codeLine, submit) = try await poll(timeout: 25, what: "matchmaking code") { img -> (String, OCR.Line, OCR.Line)? in
                let lines = try OCR.read(img, region: Region.centerPopup)
                if self.popupMapHint.isEmpty {
                    for l in lines { if let k = Store.knownMap(l.text) { self.popupMapHint = k; break } }
                }
                if !snapped, Date().timeIntervalSince(start) > 8 {
                    snapped = true
                    self.say("Still no code after 8s — the popup reads: " + lines.prefix(10).map(\.text).joined(separator: " | "))
                    Task { _ = await DebugLog.snapshot("no-code") }
                }
                guard let prompt = lines.first(where: { let n = OCR.norm($0.text)
                          return n.contains("enterthistext") || n.contains("enterthis") || n.contains("pleaseenter") || n.contains("thistextin") }),
                      let submit = lines.first(where: { OCR.norm($0.text).hasPrefix("submit") }) else { return nil }
                // The code sits centred right under the prompt. Ignore name tags behind the popup
                // ("Elf" off to the side) and whatever junk an earlier try left typed in the box.
                let between = lines.filter { $0.box.minY > prompt.box.maxY - 0.005 && $0.box.maxY < submit.box.minY }
                guard let codeLine = between
                        .filter({ abs($0.box.midX - prompt.box.midX) < 0.08 })
                        .filter({ (4...10).contains($0.text.filter { $0.isLetter || $0.isNumber }.count) })
                        .min(by: { $0.box.minY < $1.box.minY }) else { return nil }
                let code = codeLine.text.filter { $0.isLetter || $0.isNumber }
                // Settled = the same code read twice in a row with the popup in about the same place.
                // (Was: Submit within 0.8 % — a pulsing Submit button never passed that.)
                let here = CGPoint(x: prompt.box.midX, y: prompt.box.midY)
                defer { lastSubmit = here; lastCode = code }
                guard let prev = lastSubmit, lastCode == code,
                      abs(prev.x - here.x) < 0.02, abs(prev.y - here.y) < 0.02 else { return nil }
                return (code, codeLine, submit)
            }
            say("Code: \(code) (attempt \(attempt))")
            state = .enterCode
            let box = NormPoint(x: codeLine.box.midX, y: (codeLine.box.midY + submit.box.midY) / 2)

            // 2) Type it, then read the box back. Retype until what's in the box matches.
            var entered = false
            for typing in 1...3 {
                await WindowManager.focusRoblox()                         // keys only reach the active app
                // One click in the middle of the box (this is what reliably focuses it).
                await input.click(box)
                try await Task.sleep(nanoseconds: lag(400_000_000))
                // Always clear first: move to the end with → (no extra clicks — those can land outside
                // the box and drop focus), then delete plenty. Junk from an earlier try (or dropped
                // keys during lag) otherwise piles up: one night it grew to 25 characters.
                for _ in 0..<30 { await input.key("right", holdMs: 15) }
                for _ in 0..<40 { await input.key("backspace", holdMs: 20) }
                try await Task.sleep(nanoseconds: lag(150_000_000))
                // Lag drops keys ("6890" for "68903"): type slower on every retry.
                await input.type(code.lowercased(), extraDelayMs: s.typeDelayMs * typing)
                try await Task.sleep(nanoseconds: lag(500_000_000))            // let Roblox draw the text
                let inBox = await readInputBox(below: codeLine, above: submit)
                if Self.codesMatch(inBox, code) { entered = true; break }
                say("Box shows \"\(inBox.isEmpty ? "?" : inBox)\" — retyping (\(typing)/3)")
            }
            guard entered else {
                say("⚠️ Couldn't get the code into the box — cancelling for a fresh popup")
                await closeMatchmakingPopups()
                try await Task.sleep(nanoseconds: lag(1_500_000_000))
                throw MacroError.timedOut("code entry (will walk back onto the pad)")
            }

            // 3) Submit, then wait for the popup to actually close.
            say("Code entered ✓ — submitting")
            await input.click(submit.center)
            let closed = (try? await poll(timeout: 6, what: "code popup to close") { img -> Bool? in
                try OCR.find("enter this text", in: img, region: Region.centerPopup, fast: true) == nil ? true : nil
            }) ?? false
            if closed { state = .loadingStage; return }
            say("Code not accepted — reading a fresh code")
        }
        await closeMatchmakingPopups()
        throw MacroError.timedOut("accepted matchmaking code")
    }

    /// Text currently in the "?" input box (between the code and the Submit button).
    private func readInputBox(below codeLine: OCR.Line, above submit: OCR.Line) async -> String {
        guard let img = try? await ScreenCapture.captureRoblox(),
              let lines = try? OCR.read(img, region: Region.centerPopup) else { return "" }
        // Only text inside the box: below the code, above Submit, and horizontally near the code
        // (the world behind the popup has floating name tags like "Elf Mage" that OCR also sees).
        return lines.filter { $0.box.minY > codeLine.box.midY && $0.box.maxY < submit.box.minY + 0.005
                              && abs($0.box.midX - codeLine.box.midX) < 0.12 }
            .map(\.text).joined().filter { $0.isLetter || $0.isNumber }
    }

    /// Same code, allowing for OCR look-alikes (O/0, I/l/1, S/5, B/8).
    static func codesMatch(_ a: String, _ b: String) -> Bool {
        // All-digit codes: compare the digits only (stray letters are background noise).
        if b.allSatisfy(\.isNumber) {
            let digits = a.filter(\.isNumber)
            return digits == b
        }
        func canon(_ s: String) -> String {
            String(s.uppercased().map { c -> Character in
                switch c { case "O": return "0"; case "I", "L": return "1"; case "S": return "5"; case "B": return "8"; default: return c }
            })
        }
        return !a.isEmpty && canon(a) == canon(b)
    }

    /// Click Cancel / the red X on any matchmaking popup so the next attempt starts clean.
    private func closeMatchmakingPopups() async {
        guard let img = try? await ScreenCapture.captureRoblox(),
              let lines = try? OCR.read(img, region: Region.centerPopup) else { return }
        if let cancel = lines.first(where: { OCR.norm($0.text) == "cancel" }) {
            say("Closing matchmaking popup")
            await input.click(cancel.center)
        }
    }

    /// After submitting: wait for the stage to actually load (vote box, wave counter or stage title).
    /// If nothing loads within the match timeout, back out and retry the whole loop.
    private func doVote() async throws {
        let s = store?.settings ?? MacroSettings()
        say("Waiting for the match to load (up to \(s.matchTimeoutSec)s)")
        enum Loaded { case vote(NormPoint), started }
        let result: Loaded
        do {
            result = try await poll(timeout: Double(s.matchTimeoutSec), what: "match to load") { img -> Loaded? in
                if try OCR.find("vote start", in: img, region: Region.voteBox, fast: true) != nil,
                   let yes = try OCR.find("yes", in: img, region: Region.voteBox, exact: true) {
                    return .vote(yes.center)
                }
                if try OCR.find("wave", in: img, region: Region.waveCounter, fast: true) != nil { return .started }
                return nil
            }
        } catch MacroError.timedOut {
            say("⚠️ No match after \(s.matchTimeoutSec)s — going back to retry")
            await closeMatchmakingPopups()
            throw MacroError.timedOut("match to load")
        }
        if case .vote(var yes) = result {
            // Let the stage finish loading before voting — clicks during loading get dropped.
            say("Vote box up — waiting 2s for the stage to settle")
            try await Task.sleep(nanoseconds: lag(2_000_000_000))
            var voted = false
            for attempt in 1...5 {
                await WindowManager.focusRoblox()
                await input.click(yes)
                try await Task.sleep(nanoseconds: lag(1_500_000_000))
                guard let img = try? await ScreenCapture.captureRoblox() else { continue }
                // Done when the vote box is gone (match started) or the count is no longer 0/N.
                let box = (try? OCR.read(img, region: Region.voteBox)) ?? []
                let stillVoting = box.contains { OCR.norm($0.text).contains("votestart") }
                let zero = box.contains { $0.text.replacingOccurrences(of: " ", with: "").hasPrefix("0/") }
                if !stillVoting || !zero { voted = true; say("Voted Yes ✓"); break }
                say("Vote didn't register yet (attempt \(attempt)) — clicking Yes again")
                if let y = box.first(where: { OCR.norm($0.text) == "yes" }) { yes = y.center }
            }
            if !voted { say("⚠️ Vote never registered — the match should still start when the timer runs out") }
        } else {
            say("Match already running — skipping vote")
        }
        await teleportToSpawn()
        if s.cameraReset {
            say("Camera: zooming out + top-down")
            await Camera.reset(input, settings: s)
        }
        didSpawnReset = true
        slotCosts = [:]
        slotNames = [:]
        enemyLane = []
        state = .playStage
    }

    /// Recognize which map this is, then replay its recording with verification.
    private func doPlayStage() async throws {
        let settings0 = store?.settings ?? MacroSettings()
        autoLog = []
        let map: MapRecording
        do {
            if settings0.preferAuto { throw MacroError.unknownMap("auto mode preferred") }
            map = try await identifyMap()
        } catch MacroError.unknownMap(let seen) {
            guard settings0.autoWhenNoRecording || settings0.preferAuto else { throw MacroError.unknownMap(seen) }
            say("No recording for this map — playing it in auto mode")
            currentMap = (currentTitle.isEmpty ? "unknown" : currentTitle) + " · auto"
            try await autoPlay()
            state = .results
            return
        }
        inStage = true
        currentMap = map.name
        say("Map: \(map.name) — \(map.actions.count) actions")
        // Keyed by the placement's index *in the recording*, so upgrades still find
        // the right unit after priority reordering.
        var placed: [Int: NormPoint] = [:]
        var placedSlot: [Int: Int] = [:]
        let settings = store?.settings ?? MacroSettings()

        // Priority pass: actions are reordered so units in priority slots are placed + upgraded first.
        let ordered = prioritize(map.actions, prioritySlots: settings.prioritySlots)

        for (action, placeIndex) in ordered {
            try Task.checkCancellation()
            if try await checkResults() { break }                     // match ended early (win or loss)
            try await handleCards()
            switch action {
            case let .walk(k, s):
                await input.hold(k, seconds: s)
            case let .wait(s):
                try await sleepWatchingCards(s)
            case let .waitForWave(w):
                _ = try await poll(timeout: 600, what: "wave \(w)") { img -> Bool? in
                    let n = Self.readWave(img) ?? 0
                    return n >= w ? true : nil
                }
            case let .place(slot, at):
                // A failed placement shouldn't kill the run — skip it and keep going.
                do {
                    let p = try await placeVerified(slot: slot, at: at)
                    if let placeIndex { placed[placeIndex] = p; placedSlot[placeIndex] = slot }
                } catch MacroError.placementFailed(let s) {
                    say("⚠️ Couldn't place slot \(s), skipping")
                }
            case let .upgrade(i, times):
                guard let p = placed[i] else { continue }
                await upgrade(at: p, times: times, maxLevel: placedSlot[i].flatMap { settings.maxLevelPerSlot[$0] })
            }
        }
        state = .results
    }

    /// Wait for the results screen and go back to the lobby.
    /// Waits for the match to end, then clicks through it: Next → any item drops → Return to lobby.
    /// Every click is followed by a fresh look at the screen, so extra drop screens or lag
    /// just mean a few more clicks.
    private func doResults() async throws {
        say("Waiting for the match to end")
        _ = try await poll(timeout: 3600, what: "end of match") { [self] img in endScreen(in: img) }
        say(lastResultWasVictory ? "Result: VICTORY" : "Result: no victory seen (counting as a loss)")
        writeMatchReport(won: lastResultWasVictory)
        lastMatchEnded = Date(); secretFoundThisMatch = false
        if let img = try? await ScreenCapture.captureRoblox(), let p = Self.pearlsEarned(img) {
            sessionPearls += p
            say("Summer Pearls this match: +\(p) — session total \(sessionPearls)")
        }
        // Per-map record + how far it got, so weak maps stand out (give them their own [Map] steps).
        if let img = try? await ScreenCapture.captureRoblox(), let lines = try? OCR.read(img, fast: true) {
            let wave = lines.first { OCR.norm($0.text).contains("wavescompleted") }
                .flatMap { l in l.text.split(separator: ":").last.flatMap { Int($0.filter(\.isNumber)) } }
                .flatMap { $0 > 0 ? $0 : nil }
            let name = activeProfile?.name ?? store?.canonicalName(Self.mapName(fromTitle: currentTitle)) ?? ""
            if !name.isEmpty, var prof = store?.profiles.first(where: { $0.name == name }) {
                if lastResultWasVictory { prof.wins = (prof.wins ?? 0) + 1 } else { prof.losses = (prof.losses ?? 0) + 1 }
                store?.saveProfile(prof)
                if activeProfile?.name == name { activeProfile = prof }
                say("\(name): \(lastResultWasVictory ? "won" : "lost")\(wave.map { " at wave \($0)" } ?? "") — record \(prof.wins ?? 0)W / \(prof.losses ?? 0)L")
            } else if let wave {
                say("Waves completed: \(wave)")
            }
        }
        await DebugLog.snapshot(lastResultWasVictory ? "victory" : "result")

        var leftStage = false
        for step in 1...30 {
            try Task.checkCancellation()
            guard let img = try? await ScreenCapture.captureRoblox() else { continue }
            if await choosePrivateServer(img) { continue }
            // Back in the lobby? Done.
            if (try? OCR.find("play", in: img, region: Region.lobbyHUD, exact: true)) != nil,
               (try? OCR.find("returntolobby", in: img, fast: true)) == nil {
                leftStage = true; break
            }
            switch endScreen(in: img) {
            case .lobbyButton(let p)?:
                say("Clicking Return to lobby")
                await input.click(p)
                try? await Task.sleep(nanoseconds: lag(4_000_000_000))      // teleport
            case .result(let next?)?:
                say("Clicking Next")
                await input.click(next)
                try? await Task.sleep(nanoseconds: lag(1_500_000_000))
                // Reward / item-drop screens come up now, BEFORE "Return to lobby": click through them.
                for r in 0..<4 {
                    guard let rimg = try? await ScreenCapture.captureRoblox() else { break }
                    checkForSecret(rimg)
                    if case .lobbyButton? = endScreen(in: rimg), r > 0 { break }     // rewards done
                    if !(await clearPopups(rimg)) { await input.click(NormPoint(x: 0.5, y: 0.6)) }
                    say("Clicking through rewards…")
                    try? await Task.sleep(nanoseconds: lag(1_200_000_000))
                }
            case .result(nil)?, .drops?, nil:
                checkForSecret(img)
                // Item drop / reward screens: use a dismiss button if there is one,
                // otherwise click the middle of the screen to skip the animation.
                if !(await clearPopups(img)) {
                    if step % 3 == 0 { say("Clicking through reward screens…") }
                    await input.click(NormPoint(x: 0.5, y: 0.6))
                }
                try? await Task.sleep(nanoseconds: lag(1_200_000_000))
            }
        }
        sawResultPanel = false
        if teachNowActive, !teachNextMatch, manualTeachTask == nil { teachNowActive = false }
        if !leftStage { say("⚠️ Didn't see the lobby after the results — recovering") }

        // (Winning auto layouts are no longer saved as recordings: the map's scan already learned
        //  every spot that worked, and a recording would bypass the smarter placement.)
        autoLog = []
        inStage = false
        recoverAttempts = 0
        runsCompleted += 1
        if lastResultWasVictory { wins += 1; lossStreak = 0 } else { losses += 1; lossStreak += 1 }
        runDeadline = nil
        if let limit = store?.settings.stopAfterLosses, limit > 0, lossStreak >= limit {
            say("⚠️ Lost \(lossStreak) in a row — stopping so it doesn't keep failing. Check the logs.")
            await DebugLog.snapshot("loss-streak")
            stop(); return
        }
        lastResultWasVictory = false
        say("Run \(runsCompleted) done")
        if let max = store?.settings.maxRuns, max > 0, runsCompleted >= max { stop(); return }
        state = leftStage ? .lobby : .recovering
    }

    /// Something went wrong. Figure out where we are from the screen and resume from there,
    /// instead of blindly assuming we're in the lobby.
    private func doRecover() async throws {
        recoverAttempts += 1
        say("Recovering (attempt \(recoverAttempts))…")
        if recoverAttempts > 5 {
            // Something is badly wrong (disconnect, kicked, update). Leave the stage and start over.
            // (Not Escape — in Roblox that opens the game menu and the macro gets stuck behind it.)
            say("Too many failures in a row — cooling down 30s, then starting over")
            await closeMatchmakingPopups()
            try await Task.sleep(nanoseconds: lag(30_000_000_000))
            recoverAttempts = 0
        }
        guard let img = try? await ScreenCapture.captureRoblox() else {
            try await Task.sleep(nanoseconds: lag(5_000_000_000)); return       // Roblox closed/minimized
        }
        func seen(_ name: String) -> NormPoint? {
            guard let t = store?.template(name) else { return nil }
            return Matcher.find(t, in: img)?.point
        }
        if let p = seen("close_popup") { await input.click(p) }
        // A results button the end-screen check didn't recognise ("Next", "Return to lobby",
        // "Replay")? Click Next / Return and let the results flow take it from there.
        if let lines = try? OCR.read(img, fast: true), !Self.isSettingsMenu(lines.map { OCR.norm($0.text) }) {
            if let back = lines.first(where: { OCR.norm($0.text).contains("returntolobby") }) {
                say("Recovery: found Return to lobby — clicking it")
                await input.click(back.center)
                inStage = true; state = .results; return
            }
            if let next = lines.first(where: { Self.looksLikeNext($0.text) }) {
                say("Recovery: found a Next button — clicking it")
                await input.click(next.center)
                sawResultPanel = true; inStage = true; state = .results; return
            }
        }
        if endScreen(in: img) != nil {
            // On a results screen (win or loss): run the results flow to click out of it.
            state = .results
        } else if (try? OCR.find("play", in: img, region: Region.lobbyHUD, exact: true)) != nil {
            inStage = false; state = .lobby
        } else if inStage || Self.readWave(img) != nil {
            // Still mid-match (e.g. a placement failed): ride it out until the match ends.
            inStage = true
            state = .results
        } else {
            try await Task.sleep(nanoseconds: lag(3_000_000_000))
            state = .lobby
        }
    }

    // MARK: - Auto mode

    /// Plays a map with no recording: reads the placement overlay, places units where they
    /// cover the most path, then keeps upgrading (priority slots first) until the match ends.
    // MARK: - Spawn & map scans

    /// Settings (gear, bottom-left) → "Teleport back to Spawn" → close. Puts the character on
    /// the same spot every match, so the view (and every saved point) lines up.
    @discardableResult
    func teleportToSpawn() async -> Bool {
        await WindowManager.focusRoblox()
        await input.click(NormPoint(x: 0.033, y: 0.962))                  // gear
        try? await Task.sleep(nanoseconds: lag(900_000_000))
        guard let img = try? await ScreenCapture.captureRoblox(),
              let lines = try? OCR.read(img, region: Region.centerPopup) else { return false }
        guard let row = lines.first(where: { OCR.norm($0.text).contains("teleportbacktospawn") || OCR.norm($0.text).contains("teleporttospawn") }) else {
            say("⚠️ Couldn't find \"Teleport back to Spawn\" in Settings")
            if let title = lines.first(where: { OCR.norm($0.text) == "settings" }) {
                await input.click(NormPoint(x: 0.68, y: title.box.midY - 0.02))
            }
            return false
        }
        await input.click(NormPoint(x: 0.622, y: row.box.midY + 0.01))   // the arrow button on that row
        try? await Task.sleep(nanoseconds: lag(900_000_000))
        // Close Settings with its red X (top-right of the panel), if it's still open.
        if let img2 = try? await ScreenCapture.captureRoblox(),
           let title = (try? OCR.read(img2, region: Region.centerPopup))?.first(where: { OCR.norm($0.text) == "settings" }) {
            await input.click(NormPoint(x: 0.68, y: title.box.midY - 0.02))
            try? await Task.sleep(nanoseconds: lag(500_000_000))
        }
        say("Teleported to spawn")
        return true
    }

    @Published var scanning = false

    // MARK: Dungeon watch (button) — collects labelled screenshots of every dungeon screen while
    // YOU play a dungeon, so the Dungeon mode can be built from the real screens.
    @Published var dungeonWatching = false
    private var dungeonWatchTask: Task<Void, Never>?

    func toggleDungeonWatch() {
        if dungeonWatching {
            dungeonWatchTask?.cancel(); dungeonWatchTask = nil; dungeonWatching = false
            say("🗺️ Dungeon watch stopped — screenshots are in logs/dungeon")
            return
        }
        dungeonWatching = true
        let folder = DebugLog.dir.appendingPathComponent("dungeon")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        say("🗺️ Dungeon watch on — play a dungeon normally; every dungeon screen is saved to logs/dungeon")
        dungeonWatchTask = Task { [weak self] in
            var lastKind = ""
            var lastSaved = Date.distantPast
            var count = 0
            while !Task.isCancelled {
                guard let self else { return }
                if let img = try? await ScreenCapture.captureRoblox(), let lines = try? OCR.read(img, fast: true) {
                    let t = lines.map { OCR.norm($0.text) }
                    func has(_ w: String...) -> Bool { t.contains { line in w.contains { line.contains($0) } } }
                    let kind: String
                    if has("dungeondepth") { kind = "path" }
                    else if has("continuedungeon", "returntodungeon") { kind = "after-match" }
                    else if has("treasurechest", "rarechest") && has("open") { kind = "chests" }
                    else if has("relic") { kind = "relic" }
                    else if has("buy", "purchase") && (has("shop") || has("hoard")) { kind = "shop" }
                    else if has("blessing", "curse") { kind = "curse-blessing" }
                    else if has("victory") || has("defeat") || has("wavescompleted") { kind = "result" }
                    else if has("retry", "livesleft", "attempts", "tries") { kind = "retry" }
                    else if has("dungeon") && has("key", "start", "enter") { kind = "dungeon-start" }
                    else { kind = "" }
                    // Save when the screen changes, and every 12 s while on a dungeon screen.
                    if !kind.isEmpty, kind != lastKind || Date().timeIntervalSince(lastSaved) > 12 {
                        count += 1
                        let name = "\(DebugLog.stamp())-\(kind)"
                        DebugLog.savePNG(img, name: "dungeon/\(name).png")
                        var report = "=== \(kind) @ \(name) (\(img.width)×\(img.height)) ===\n"
                        let full = (try? OCR.read(img)) ?? lines
                        for l in full.sorted(by: { ($0.box.minY, $0.box.minX) < ($1.box.minY, $1.box.minX) }) {
                            report += String(format: "  (%.3f, %.3f) w%.3f h%.3f  %@\n", l.box.midX, l.box.midY, l.box.width, l.box.height, l.text)
                        }
                        try? report.write(to: folder.appendingPathComponent("\(name).txt"), atomically: true, encoding: .utf8)
                        if kind != lastKind { self.say("🗺️ Dungeon watch: saved \(kind) screen (#\(count))") }
                        lastKind = kind; lastSaved = Date()
                    } else if kind.isEmpty {
                        lastKind = ""
                    }
                }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
    }

    // MARK: Walks (Portal mode groundwork) — record a right-click walk, replay it, line up.
    @Published var walkRecording = false
    private var walkListener: TeachListener?
    private var walkName = ""

    /// "Record walk": start at spawn, right-click your way to your spot, press again to save.
    func toggleRecordWalk(name: String) {
        if walkRecording, let l = walkListener {
            l.stop(); walkListener = nil; walkRecording = false
            let pts = l.rightClicks
            guard !pts.isEmpty else { say("🚶 No right clicks recorded — nothing saved"); return }
            var gaps: [Double] = []
            for i in 1..<max(1, pts.count) where i < pts.count { gaps.append(pts[i].time.timeIntervalSince(pts[i - 1].time)) }
            let name = walkName
            Task {
                try? await Task.sleep(nanoseconds: 1_500_000_000)          // let the character arrive
                var w = WalkRecording(name: name, clicks: pts.map(\.at), gaps: gaps, referenceImage: nil)
                if let img = try? await ScreenCapture.captureRoblox() { w.referenceImage = store?.saveReference(img, name: "walk-\(name)") }
                store?.saveWalk(w)
                say("🚶 Saved walk for \(name): \(w.clicks.count) clicks + end view")
            }
            return
        }
        var n = name.trimmingCharacters(in: .whitespaces)
        if n.isEmpty { n = store?.canonicalName(Self.mapName(fromTitle: currentTitle)) ?? "" }
        if n.isEmpty { say("🚶 Type the map name in the Map name box first"); return }
        let l = TeachListener(); l.start()
        guard l.isListening else { say("⚠️ Can't watch your input (Accessibility / Input Monitoring)"); return }
        walkListener = l; walkName = n; walkRecording = true
        say("🚶 Recording walk for \(n): from spawn, RIGHT-click your way to your spot, then press Stop & save walk")
    }

    /// "Test walk": replays the saved walk for this map, then lines the view up with the saved end view.
    func testWalk(name: String) {
        var n = name.trimmingCharacters(in: .whitespaces)
        if n.isEmpty { n = store?.canonicalName(Self.mapName(fromTitle: currentTitle)) ?? "" }
        guard let w = store?.walk(named: n) else { say("🚶 No saved walk for \"\(n)\" — record one first"); return }
        Task { await self.playWalk(w) }
    }

    /// Waits until the view stops moving (character arrived), up to `timeout` seconds.
    private func waitUntilStill(timeout: Double) async {
        let end = Date().addingTimeInterval(timeout)
        var prev = try? await ScreenCapture.captureRoblox()
        var still = 0
        while Date() < end {
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard let cur = try? await ScreenCapture.captureRoblox() else { continue }
            if let p = prev, let m = Matcher.viewShift(reference: p, current: cur, maxShift: 4),
               abs(m.dx) < 0.004, abs(m.dy) < 0.004 { still += 1 } else { still = 0 }
            if still >= 2 { return }
            prev = cur
        }
    }

    @discardableResult
    func playWalk(_ w: WalkRecording) async -> Bool {
        await WindowManager.focusRoblox()
        say("🚶 Walking (\(w.clicks.count) clicks)…")
        for (i, p) in w.clicks.enumerated() {
            await input.rightClick(p)
            let gap = i < w.gaps.count ? w.gaps[i] : 2
            await waitUntilStill(timeout: gap * 2 + 3)
        }
        // Line up with the saved end view: wherever the reference centre now appears, walk there.
        guard let file = w.referenceImage, let ref = store?.reference(file) else { say("🚶 Walk done (no end view saved)"); return true }
        for attempt in 1...5 {
            guard let cur = try? await ScreenCapture.captureRoblox(),
                  let m = Matcher.viewShift(reference: ref, current: cur, maxShift: 24) else { break }
            say(String(format: "🚶 Line-up %d: off by (%+.3f, %+.3f), match %.2f", attempt, m.dx, m.dy, m.score))
            if abs(m.dx) < 0.006 && abs(m.dy) < 0.006 { say("🚶 Lined up ✓"); return true }
            if m.score > 0.30 { say("⚠️ The view doesn't look like the saved end view — walk may have gone wrong"); return false }
            await input.rightClick(NormPoint(x: 0.5 + m.dx, y: 0.5 + m.dy))
            await waitUntilStill(timeout: 4)
        }
        say("🚶 Close enough — couldn't line up exactly")
        return false
    }

    // MARK: Teach portal — one session records the walk, every placement and the upgrade order.
    @Published var planTeaching = false
    private var planTask: Task<Void, Never>?
    private var planListener: TeachListener?

    func togglePlanTeach(name: String) {
        if planTeaching { planTask?.cancel(); return }      // the task saves on its way out
        var n = name.trimmingCharacters(in: .whitespaces)
        if n.isEmpty { n = store?.canonicalName(Self.mapName(fromTitle: currentTitle)) ?? "" }
        if n.isEmpty { say("🗺️ Type the map name in the Map name box first"); return }
        let l = TeachListener(); l.start()
        guard l.isListening else { say("⚠️ Can't watch your input (Accessibility / Input Monitoring)"); return }
        planListener = l; planTeaching = true
        let upKey = store?.settings.upgradeKey.lowercased() ?? "r"
        say("🗺️ Teaching \(n): 1) RIGHT-click your way from spawn to your spot  2) place units  3) upgrade them (click a unit, press \(upKey.uppercased())) — in the order you want. Press Stop & save when done.")
        planTask = Task { [weak self] in
            guard let self else { return }
            var walkClicks: [(NormPoint, Date)] = []
            var reference: CGImage?
            var lastRight = Date.distantPast
            var actions: [PortalPlan.Action] = []
            var units: [(slot: Int, at: NormPoint)] = []
            var selected: Int?
            var pendingUnsure: [(slot: Int, at: NormPoint, time: Date)] = []
            while !Task.isCancelled {
                // walk end view: a still frame after the last right click, before any placement
                if units.isEmpty, !walkClicks.isEmpty, Date().timeIntervalSince(lastRight) > 1.5,
                   let img = try? await ScreenCapture.captureRoblox() { reference = img }
                // placements. Confirmed when the unit panel pops up — checked for up to ~2 s, since it
                // can open late. No panel and no "can't place" message = unsure: kept, unless you
                // tried the same slot again within 8 s (then it was a miss you corrected).
                for c in l.take(olderThan: 0.6) {
                    var confirmed = false, refused = false
                    for _ in 0..<4 where !confirmed && !refused {
                        if let img = try? await ScreenCapture.captureRoblox() {
                            let r = Self.readAfterClick(img)
                            confirmed = r.panel; refused = r.failed || r.limit || r.noYen
                        }
                        if !confirmed && !refused { try? await Task.sleep(nanoseconds: 450_000_000) }
                    }
                    if confirmed {
                        units.append((c.slot, c.at)); actions.append(.place(slot: c.slot, at: c.at)); selected = units.count - 1
                        self.say(String(format: "🗺️ #%d: place slot %d at (%.3f, %.3f) ✓", units.count, c.slot, c.at.x, c.at.y))
                    } else if refused {
                        self.say(String(format: "🗺️ Slot %d click at (%.3f, %.3f) was refused by the game — not saved", c.slot, c.at.x, c.at.y))
                    } else {
                        pendingUnsure.append((c.slot, c.at, c.time))
                    }
                }
                // settle unsure clicks: keep them unless the same slot was tried again soon after
                let now = Date()
                for u in pendingUnsure where now.timeIntervalSince(u.time) > 8 {
                    let retried = l.allClicks.contains { $0.slot == u.slot && $0.time > u.time && $0.time.timeIntervalSince(u.time) < 8 }
                    if retried {
                        self.say(String(format: "🗺️ Slot %d click at (%.3f, %.3f) looks like a miss you retried — not saved", u.slot, u.at.x, u.at.y))
                    } else {
                        units.append((u.slot, u.at)); actions.append(.place(slot: u.slot, at: u.at)); selected = units.count - 1
                        self.say(String(format: "🗺️ #%d: place slot %d at (%.3f, %.3f) (no panel seen — kept)", units.count, u.slot, u.at.x, u.at.y))
                    }
                }
                pendingUnsure.removeAll { now.timeIntervalSince($0.time) > 8 }
                // walk clicks, selections and upgrade presses, in order
                while l.cursor < l.events.count {
                    let (ev, t) = l.events[l.cursor]; l.cursor += 1
                    switch ev {
                    case .right(let p):
                        if units.isEmpty {
                            walkClicks.append((p, t)); lastRight = t
                            self.say(String(format: "🗺️ walk click %d at (%.3f, %.3f)", walkClicks.count, p.x, p.y))
                        } else {
                            self.say("🗺️ right click after placing started — not part of the walk")
                        }
                    case .left(let p):
                        selected = units.indices.min { a, b in
                            hypot(units[a].at.x - p.x, units[a].at.y - p.y) < hypot(units[b].at.x - p.x, units[b].at.y - p.y)
                        }.flatMap { hypot(units[$0].at.x - p.x, units[$0].at.y - p.y) < 0.045 ? $0 : nil } ?? selected
                    case .key(let k) where k == upKey:
                        guard let u = selected else { continue }
                        if case let .upgrade(lu, times)? = actions.last, lu == u { actions[actions.count - 1] = .upgrade(unit: u, times: times + 1) }
                        else { actions.append(.upgrade(unit: u, times: 1)) }
                    default: break
                    }
                }
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            // save — unsure clicks still waiting are kept unless retried
            for u in pendingUnsure {
                let retried = l.allClicks.contains { $0.slot == u.slot && $0.time > u.time && $0.time.timeIntervalSince(u.time) < 8 }
                if !retried { units.append((u.slot, u.at)); actions.append(.place(slot: u.slot, at: u.at)) }
            }
            l.stop()
            var walk: WalkRecording?
            if !walkClicks.isEmpty {
                var gaps: [Double] = []
                for i in 1..<max(1, walkClicks.count) where i < walkClicks.count { gaps.append(walkClicks[i].1.timeIntervalSince(walkClicks[i - 1].1)) }
                walk = WalkRecording(name: n, clicks: walkClicks.map(\.0), gaps: gaps,
                                     referenceImage: reference.flatMap { self.store?.saveReference($0, name: "walk-\(n)") })
            }
            if walkClicks.isEmpty {
                self.say("🗺️ No walk recorded — right clicks seen: \(l.rightClicksSeen) (outside the Roblox window: \(l.rightClicksOutside))")
            }
            let plan = PortalPlan(name: n, walk: walk, actions: actions)
            self.store?.savePlan(plan)
            let ups = actions.reduce(0) { if case let .upgrade(_, t) = $1 { return $0 + t }; return $0 }
            self.say("🗺️ Saved plan for \(n): walk \(walk?.clicks.count ?? 0) clicks, \(units.count) placements, \(ups) upgrades")
            self.planTeaching = false; self.planListener = nil; self.planTask = nil
        }
    }

    /// Plays a taught plan strictly: walk + line up, then each placement/upgrade in your order.
    /// After the plan, keeps upgrading the units in the order you first upgraded them, to MAX.
    func runPlan(_ plan: PortalPlan) async {
        if let w = plan.walk { await playWalk(w) }
        var placed: [Int: (slot: Int, at: NormPoint)] = [:]     // plan unit index → where it actually went
        var unitNo = 0
        for action in plan.actions {
            if Task.isCancelled { return }
            if (try? await checkResults()) == true { say("🗺️ Match over during the plan"); return }
            switch action {
            case let .place(slot, at):
                let idx = unitNo; unitNo += 1
                if let price = await cost(of: slot) {
                    _ = try? await poll(timeout: 900, what: "\(price)¥ for slot \(slot)") { img -> Bool? in self.enoughYen(img, price) }
                }
                var ok = false
                // the exact spot first, then tiny nudges (a summon or effect can sit on it)
                for d in [(0.0, 0.0), (0.008, 0.0), (-0.008, 0.0), (0.0, 0.012), (0.0, -0.012)] {
                    let p = NormPoint(x: at.x + d.0, y: at.y + d.1)
                    switch await placeOnce(slot: slot, at: p, trusted: true, forceTry: true) {
                    case .placed: placed[idx] = (slot, p); ok = true
                    case .cantAfford:
                        try? await sleepWatchingCards(3)
                    default: break
                    }
                    if ok { break }
                }
                say(ok ? "🗺️ Plan: unit #\(idx + 1) (slot \(slot)) placed" : "⚠️ Plan: couldn't place unit #\(idx + 1) (slot \(slot)) at its spot")
            case let .upgrade(unit, times):
                guard let u = placed[unit] else { continue }
                _ = await upgradeUnit(slot: u.slot, at: u.at, times: times)
            }
        }
        // then everything to MAX, in the order you upgraded
        var order: [Int] = []
        for a in plan.actions { if case let .upgrade(u, _) = a, !order.contains(u) { order.append(u) } }
        for u in placed.keys.sorted() where !order.contains(u) { order.append(u) }
        for u in order {
            guard let p = placed[u] else { continue }
            if (try? await checkResults()) == true { return }
            _ = await upgradeUnit(slot: p.slot, at: p.at, times: 99)
        }
        say("🗺️ Plan finished")
    }

    /// "Test plan" button: run this map's plan now (in a match, at spawn).
    func testPlan(name: String) {
        var n = name.trimmingCharacters(in: .whitespaces)
        if n.isEmpty { n = store?.canonicalName(Self.mapName(fromTitle: currentTitle)) ?? "" }
        guard let plan = store?.plan(named: n) else { say("🗺️ No plan saved for \"\(n)\" — teach one first"); return }
        inStage = true
        Task { await self.runPlan(plan); self.inStage = false }
    }

    // MARK: Teach now (button) — teach any time, without turning on Teach mode or restarting
    @Published var teachNowActive = false
    private var manualTeachTask: Task<Void, Never>?
    /// Set by "Teach now" while the macro runs: the next match is taught too.
    private var teachNextMatch = false

    /// "Teach now" button.
    ///  • Macro running, in a match → from now on it asks you to place units (rest of this match),
    ///    and the NEXT match is taught too (so units already placed this match get taught then).
    ///  • Macro running, between matches → the next match is taught.
    ///  • Macro stopped → you play; every unit you place (slot key + click, panel pops up) is saved
    ///    for this map. Press again to stop.
    func teachNow(name: String) {
        if teachNowActive { stopTeachNow(); return }
        let s = store?.settings ?? MacroSettings()
        if state != .idle {
            teachNowActive = true
            teachNextMatch = true
            if inStage, state == .playStage {
                let n = activeProfile?.name ?? store?.canonicalName(Self.mapName(fromTitle: currentTitle)) ?? Self.mapName(fromTitle: currentTitle)
                if !n.isEmpty {
                    if !teachingThisMatch { teachName = n; teachSpots = [] }
                    teachingThisMatch = true
                    say("🎓 Teach now: I'll ask you for \(s.teachHillsOnly ? "hill units" : "units") from here on in this match, and teach the next match too.")
                    return
                }
            }
            say("🎓 Teach now: the next match will be taught.")
            return
        }
        startManualTeach(name: name)
    }

    private func stopTeachNow() {
        teachNextMatch = false
        if let t = manualTeachTask {
            t.cancel(); manualTeachTask = nil
            say("🎓 Teaching stopped — \(teachSpots.count) spot(s) saved for \(teachName)")
        } else {
            say("🎓 Teach now cancelled (spots already learned stay saved)")
        }
        teachNowActive = false
    }

    private func startManualTeach(name: String) {
        teachNowActive = true
        manualTeachTask = Task { [weak self] in
            guard let self else { return }
            var title = name
            if title.isEmpty, let img = try? await ScreenCapture.captureRoblox() {
                title = (try? OCR.read(img, region: Region.stageTitle).map(\.text).joined(separator: " ")) ?? ""
            }
            let raw = name.isEmpty ? Self.mapName(fromTitle: title) : name
            let mapName = self.store?.canonicalName(raw) ?? raw
            guard !mapName.isEmpty else {
                self.say("🎓 Couldn't read the map name — type it in the Map name box, then press Teach now")
                self.teachNowActive = false; self.manualTeachTask = nil; return
            }
            self.teachName = mapName; self.teachSpots = []; self.mapShift = (0, 0)
            self.activeProfile = self.store?.profiles.first { $0.name == mapName }
            let l = TeachListener(); l.start()
            guard l.isListening else {
                self.say("⚠️ Teach can't watch your input (Accessibility / Input Monitoring)")
                self.teachNowActive = false; self.manualTeachTask = nil; return
            }
            self.say("🎓 Teaching \(mapName): place your units (slot key, then click). Each one that lands is saved. Press Stop teaching when done.")
            while !Task.isCancelled {
                for c in l.take(olderThan: 0.7) {
                    guard let img = try? await ScreenCapture.captureRoblox() else { continue }
                    if Self.unitPanelOpen(img) {
                        self.saveTaught(slot: c.slot, at: c.at)
                        self.say(String(format: "🎓 Learned slot %d at (%.3f, %.3f) ✓", c.slot, c.at.x, c.at.y))
                    } else {
                        self.say(String(format: "🎓 Slot %d click at (%.3f, %.3f) didn't place — not saved", c.slot, c.at.x, c.at.y))
                    }
                }
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            l.stop()
        }
    }
    @Published var scanProgress = ""
    private var scanTask: Task<Void, Never>?

    /// Scan button: learn a map in a normal stage. Name = the box's text, or read from the title.
    func scanMap(name: String) {
        guard scanTask == nil, state == .idle else { return }
        DockPanel.shared.releaseKeyboard()
        scanning = true
        stayAwake(true)
        startCardWatcher()
        scanTask = Task {
            do { try await runScan(name: name) }
            catch { say("Scan stopped: \(error.localizedDescription)") }
            inStage = false; scanning = false; scanProgress = ""; scanTask = nil
            if self.task == nil { stayAwake(false) }
        }
    }

    private func runScan(name typed: String) async throws {
        let s = store?.settings ?? MacroSettings()
        WindowManager.lockAndFocus()
        try await Task.sleep(nanoseconds: lag(500_000_000))
        inStage = true
        enemyLane = []
        slotCosts = [:]

        // You start the stage and place one unit yourself first; the scan works around it
        // (its spot shows as taken, which is correct).
        // Map name: what you typed, else the stage title.
        var name = typed.trimmingCharacters(in: .whitespaces)
        if name.isEmpty { name = Self.mapName(fromTitle: await waitForTitle()) }
        guard !name.isEmpty else { say("⚠️ Scan: couldn't read the map name — type it in the Map name box"); return }
        say("Scanning \(name)…")

        await teleportToSpawn()
        await Camera.reset(input, settings: { var c = s; c.cameraReset = true; return c }())
        // Reference view for the camera check in later matches.
        var refFile: String?
        if let img = try? await ScreenCapture.captureRoblox() { refFile = store?.saveReference(img, name: "scan-\(name)") }

        // One ground unit (cheapest non-hill slot that still has room) and one hill unit.
        func hasRoom(_ slot: Int) async -> Bool {
            for _ in 0..<2 {                                         // read twice before guessing
                await input.key(String(slot))
                try? await Task.sleep(nanoseconds: lag(400_000_000))
                let img = try? await ScreenCapture.captureRoblox()
                await input.key("q")
                try? await Task.sleep(nanoseconds: lag(200_000_000))
                guard let img else { continue }
                if Self.placementLimitMessage(img) { return false }
                if let c = Self.readSlotCounter(img, slot: slot) { return c.placed < c.limit }
            }
            return true
        }
        var groundSlot: Int?
        var cheapest = Int.max
        // (Units that can't be sold are never used — a test unit has to be sold right after.)
        for slot in 1...6 where !s.hillSlots.contains(slot) && !s.unsellableSlots.contains(slot) {
            if let c = await cost(of: slot), c < cheapest, await hasRoom(slot) { cheapest = c; groundSlot = slot }
        }
        var hillSlot: Int?
        for slot in s.hillSlots.sorted() where hillSlot == nil && !s.unsellableSlots.contains(slot) {
            if await hasRoom(slot) { hillSlot = slot }
        }
        say("Scan units: ground = slot \(groundSlot.map(String.init) ?? "none"), hill = slot \(hillSlot.map(String.init) ?? "none")")
        var ground: [NormPoint] = [], hill: [NormPoint] = []
        var badGround: [NormPoint] = [], badHill: [NormPoint] = []
        func current() -> MapProfile {
            MapProfile(name: name, ground: ground, hill: hill, lane: enemyLane, scannedAt: Date(),
                       badGround: badGround, badHill: badHill, referenceImage: refFile)
        }
        func saveSoFar() { store?.saveProfile(current()) }
        // Keep what an earlier (partial) scan of this map found, if this one gets cut short.
        if let old = store?.profiles.first(where: { $0.name == name }) {
            ground = old.ground; hill = old.hill; enemyLane = old.lane
            badGround = old.badGround ?? []; badHill = old.badHill ?? []
            if refFile == nil { refFile = old.referenceImage }
        }
        func pictureSoFar() async {
            if let img = try? await ScreenCapture.captureRoblox() {
                saveScanPicture(current(), over: img)
            }
        }
        if let g = groundSlot {
            ground = try await probeGrid(slot: g, label: "ground", hill: false); badGround += scanBad
            saveSoFar(); await pictureSoFar()
        }
        if let h = hillSlot {
            hill = try await probeGrid(slot: h, label: "hill", hill: true); badHill += scanBad
            if lastScanHitLimit {
                // That hill unit turned out to be full — try the other hill units.
                for other in s.hillSlots.sorted() where other != h && !s.unsellableSlots.contains(other) {
                    say("Scan: slot \(h) is full — trying hill slot \(other) instead")
                    let more = try await probeGrid(slot: other, label: "hill", hill: true); badHill += scanBad
                    if !lastScanHitLimit { hill = more; break }
                }
                if lastScanHitLimit {
                    say("⚠️ Every hill unit is at its limit, so hill spots couldn't be test-placed. Sell one hill unit (or start a fresh stage with only a ground unit down) and scan again.")
                }
            }
            saveSoFar(); await pictureSoFar()
        }
        else { say("No unit ticked as Hill — skipping the hill scan") }

        // Lane: keep watching enemies until there are plenty of sightings.
        scanProgress = "watching enemies for the lane…"
        let end = Date().addingTimeInterval(150)
        while enemyLane.count < 80, Date() < end {
            try Task.checkCancellation()
            if let img = try? await ScreenCapture.captureRoblox() { scanEnemies(img); try? await handleCards(img) }
            try await Task.sleep(nanoseconds: lag(500_000_000))
        }

        let profile = current()
        store?.saveProfile(profile)
        if let img = try? await ScreenCapture.captureRoblox() { saveScanPicture(profile, over: img) }
        say("✓ Scan saved for \(name): \(ground.count) ground spots, \(hill.count) hill spots, \(enemyLane.count) lane points")
    }

    /// Scans the current event map mid-match (ground + hill), counting our own placed units as
    /// valid spots for their type, and saves it like a normal Scan.
    private func learnMapNow() async throws {
        let s = store?.settings ?? MacroSettings()
        let name = store?.canonicalName(Self.mapName(fromTitle: currentTitle)) ?? Self.mapName(fromTitle: currentTitle)
        guard !name.isEmpty else { return }
        say("Learning \(name) while the team holds — scanning placeable spots for next time")
        // A unit can only be held to test spots if its slot isn't at its placement limit.
        let usable = (1...6).filter { !autoFull.contains($0) && !s.unsellableSlots.contains($0) }
        var groundSlot: Int?, cheapest = Int.max
        for slot in usable where !s.hillSlots.contains(slot) {
            if let c = await cost(of: slot), c < cheapest { cheapest = c; groundSlot = slot }
        }
        let hillSlot = usable.filter { s.hillSlots.contains($0) }.first

        var ground: [NormPoint] = [], hill: [NormPoint] = []
        if let g = groundSlot {
            if try await checkResults() { return }
            ground = try await probeGrid(slot: g, label: "ground", hill: false)
        }
        if let h = hillSlot {
            if try await checkResults() { return }
            hill = try await probeGrid(slot: h, label: "hill", hill: true)
            // The colour check finds few hill spots on busy maps: test around our own hill units too.
            let around = ringsAround(autoPlaced.filter { s.hillSlots.contains($0.slot) }.map(\.at), radii: [0.035, 0.055, 0.075])
                .filter { p in !hill.contains { abs($0.x - p.x) < 0.015 && abs($0.y - p.y) < 0.02 } }
            var extra = 0
            for p in around.prefix(24) {
                if try await checkResults() { break }
                let ci = cardInterrupts
                let r = await testPlaceAndSell(slot: h, at: p)
                if cardInterrupts != ci && r != true { continue }
                if r == true { hill.append(p); extra += 1 } else if r == nil { break }
            }
            if !around.isEmpty { say("Learning: \(extra) more hill spots found around our hill units") }
        }
        // Our own units stand on spots that are valid by definition.
        for u in autoPlaced {
            if s.hillSlots.contains(u.slot) { hill.append(u.at) } else { ground.append(u.at) }
        }
        guard !ground.isEmpty || !hill.isEmpty else { say("Learning \(name): nothing usable found — skipped"); return }
        var profile = activeProfile ?? MapProfile(name: name, ground: [], hill: [], lane: [], scannedAt: Date())
        profile.ground += ground.map(unshifted); profile.hill += hill.map(unshifted)
        if profile.lane.count < enemyLane.count { profile.lane = enemyLane.map(unshifted) }
        if profile.referenceImage == nil, let img = try? await ScreenCapture.captureRoblox() {
            profile.referenceImage = store?.saveReference(img, name: "scan-\(name)")
        }
        activeProfile = profile
        mapShift = (0, 0)                      // learned from this exact view
        store?.saveProfile(profile)
        if let img = try? await ScreenCapture.captureRoblox() { saveScanPicture(profile, over: img) }
        say("✓ Learned \(name): \(ground.count) ground / \(hill.count) hill spots, \(enemyLane.count) lane points")
    }

    /// Test scan button: in a stage, try to place every unit on its saved spots (front of the map
    /// first) and report how many saved spots were actually good.
    func testScan(name: String) {
        guard scanTask == nil, state == .idle else { return }
        DockPanel.shared.releaseKeyboard()
        scanning = true
        scanTask = Task {
            do { try await runTestScan(name: name) }
            catch { say("Test stopped: \(error.localizedDescription)") }
            inStage = false; scanning = false; scanProgress = ""; scanTask = nil
        }
    }

    private func runTestScan(name typed: String) async throws {
        let s = store?.settings ?? MacroSettings()
        WindowManager.lockAndFocus()
        try await Task.sleep(nanoseconds: lag(500_000_000))
        inStage = true; slotCosts = [:]
        var title = typed
        if title.trimmingCharacters(in: .whitespaces).isEmpty { title = await waitForTitle() }
        guard let prof = store?.profile(forTitle: title) ?? store?.profiles.first(where: { OCR.norm($0.name) == OCR.norm(title) }) else {
            say("⚠️ Test: no scan found for \"\(title)\" — scan the map first (or type its name in the Map name box)")
            return
        }
        say("Testing the scan for \(prof.name) — middle of the map first")
        await teleportToSpawn()
        await Camera.reset(input, settings: { var c = s; c.cameraReset = true; return c }())

        // Try spots in the MIDDLE of the map first (around the middle of the lane, or the
        // screen centre if no lane was learned) — the entrance is often too cramped.
        let aspect = Double(WindowManager.lockedSize.height / WindowManager.lockedSize.width)
        func d(_ a: NormPoint, _ b: NormPoint) -> Double { let dx = a.x - b.x, dy = (a.y - b.y) * aspect; return (dx * dx + dy * dy).squareRoot() }
        let middle: NormPoint = prof.lane.isEmpty ? NormPoint(x: 0.42, y: 0.52)
            : NormPoint(x: prof.lane.map(\.x).reduce(0, +) / Double(prof.lane.count),
                        y: prof.lane.map(\.y).reduce(0, +) / Double(prof.lane.count))
        func frontDistance(_ p: NormPoint) -> Double { d(middle, p) }

        var placedHere: [NormPoint] = []
        var tried: [(NormPoint, Bool)] = []
        var report: [String] = []
        for slot in 1...6 {
            try Task.checkCancellation()
            let hill = s.hillSlots.contains(slot)
            let pool = (hill ? prof.hill : prof.ground)
                .filter { p in !placedHere.contains { d($0, p) < 0.03 } && !prof.lane.contains { d($0, p) < 0.018 } }
                .sorted { frontDistance($0) < frontDistance($1) }
            guard !pool.isEmpty else { report.append("slot \(slot): no saved \(hill ? "hill" : "ground") spots"); continue }
            if let price = await cost(of: slot) {
                scanProgress = "slot \(slot): waiting for \(price)¥…"
                _ = try await poll(timeout: 600, what: "\(price)¥ for slot \(slot)") { img -> Bool? in
                    self.enoughYen(img, price)
                }
            }
            var rejected = 0, result = "not placed"
            for p in pool.prefix(12) {
                try Task.checkCancellation()
                scanProgress = "slot \(slot): trying saved spot \(rejected + 1)…"
                switch await placeOnce(slot: slot, at: p) {
                case .placed:
                    placedHere.append(p); tried.append((p, true))
                    result = rejected == 0 ? "placed on the 1st saved spot ✓" : "placed after \(rejected) bad spot(s)"
                case .failed:
                    rejected += 1; tried.append((p, false)); continue
                case .cantAfford:
                    result = "ran out of yen"
                case .limitReached:
                    result = rejected == 0 ? "already at its placement limit (spot not tested)" : "at its placement limit after \(rejected) bad spot(s)"
                }
                break
            }
            if result == "not placed" { result = "all \(rejected) tried spots failed ✗" }
            report.append("slot \(slot) (\(hill ? "hill" : "ground")): \(result)")
            say("Test slot \(slot): \(result)")
        }
        say("Test summary for \(prof.name): " + report.joined(separator: " · "))

        // Picture: green = placed there, red = saved spot that didn't work.
        if let img = try? await ScreenCapture.captureRoblox() {
            let W = img.width, H = img.height
            if let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                                   space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                ctx.draw(img, in: CGRect(x: 0, y: 0, width: W, height: H))
                ctx.setLineWidth(6)
                for (p, ok) in tried {
                    ctx.setStrokeColor(ok ? CGColor(red: 0, green: 1, blue: 0.3, alpha: 1) : CGColor(red: 1, green: 0.1, blue: 0.1, alpha: 1))
                    ctx.strokeEllipse(in: CGRect(x: p.x * Double(W) - 16, y: Double(H) - p.y * Double(H) - 16, width: 32, height: 32))
                }
                if let out = ctx.makeImage() { DebugLog.savePNG(out, name: "test-\(prof.name).png") }
            }
        }
    }

    /// The stage title above the base health bar. It only appears once the stage has started
    /// (after the vote), so keep looking for up to a minute.
    private func waitForTitle() async -> String {
        let end = Date().addingTimeInterval(60)
        var said = false
        while Date() < end, !Task.isCancelled {
            if let img = try? await ScreenCapture.captureRoblox() {
                let t = (try? OCR.read(img, region: Region.stageTitle).map(\.text).joined(separator: " ")) ?? ""
                let n = Self.mapName(fromTitle: t)
                if !n.isEmpty, Self.plausibleTitle(t, name: n, known: store?.profiles.map(\.name) ?? []) {
                    // Not a map we know ("Navw Ba")? It's often a misread: look a few more times
                    // and take a reading that matches a known map, if one comes up.
                    let known = store?.profiles.map(\.name) ?? []
                    if !known.isEmpty, !known.contains(store?.canonicalName(n) ?? n) {
                        for _ in 0..<6 {
                            try? await Task.sleep(nanoseconds: lag(700_000_000))
                            guard let img2 = try? await ScreenCapture.captureRoblox() else { continue }
                            let t2 = (try? OCR.read(img2, region: Region.stageTitle).map(\.text).joined(separator: " ")) ?? ""
                            let n2 = Self.mapName(fromTitle: t2)
                            if !n2.isEmpty, known.contains(store?.canonicalName(n2) ?? n2) {
                                say("Stage: \(t2) (re-read; first read was \"\(t)\")"); return t2
                            }
                        }
                    }
                    say("Stage: \(t)"); return t
                }
            }
            if !said { say("Waiting for the stage title (start the stage with the vote)…"); said = true }
            try? await Task.sleep(nanoseconds: lag(1_000_000_000))
        }
        return ""
    }

    /// Rejects OCR garbage like "ve U Locang...a": the title must name the mode
    /// (Summer Hunt / Act / Infinite…) or match a map we already know.
    static func plausibleTitle(_ title: String, name: String, known: [String]) -> Bool {
        let t = OCR.norm(title)
        if ["summerhunt", "summer", "hunt", "infinite", "act", "story", "raid", "challenge", "legend"].contains(where: { t.contains($0) }) {
            return name.count >= 4 && name.filter(\.isLetter).count >= name.count * 2 / 3
        }
        let n = OCR.norm(name)
        return known.contains { k in let kn = OCR.norm(k); return kn.count >= 4 && n.count >= 4 && (n.contains(kn) || kn.contains(n)) }
    }

    /// "Navy Bay Summer Hunt" / "Navy Bay Act 2" → "Navy Bay"
    static func mapName(fromTitle title: String) -> String {
        // The vote box ("Vote start: 0/6") sits where the title will appear — never a map name.
        if OCR.norm(title).contains("vote") { return "" }
        var t = title
        // Everything after the mode is junk the reader picked up ("… Summer Hunt ЛAASA").
        // "Summer Hunt" and misreads of it ("Smmer Hunt", "Summer Hnt", "Sumer Hunt").
        if let r = t.range(of: #"s[a-z]{0,2}m{1,2}[a-z]{0,2}r\s*h[a-z]{0,2}n?t"#, options: [.regularExpression, .caseInsensitive]) {
            t = String(t[..<r.lowerBound])
        }
        // Boss HP and loading text that sometimes ride along ("68250/68250 Loading…").
        if let r = t.range(of: #"\d+\s*/\s*\d+|loading"#, options: [.regularExpression, .caseInsensitive]) { t = String(t[..<r.lowerBound]) }
        // Stray symbols the reader adds in front ("•Planet Greenie", "Ouou •Planet…") and non-Latin junk.
        if let dot = t.lastIndex(where: { "•*·".contains($0) }) { t = String(t[t.index(after: dot)...]) }
        t = String(t.unicodeScalars.filter { $0.isASCII }.map(Character.init))
        // Junk the reader puts in front ("ve O walled city"): drop leading 1–2 letter fragments.
        var words = t.split(separator: " ").map(String.init)
        while words.count > 1, let f = words.first, f.filter(\.isLetter).count <= 2 { words.removeFirst() }
        t = words.joined(separator: " ")
        for junk in ["Summer Hunt", "Infinite Mode", "Infinite", "Story Mode", "Story", "Raid", "Challenge",
                     "Legend Stage", "Tournament Stage", "Mode"] {
            t = t.replacingOccurrences(of: junk, with: "", options: .caseInsensitive)
        }
        if let r = t.range(of: #"\s*(Act|Stage)\s*\d+.*$"#, options: [.regularExpression, .caseInsensitive]) { t.removeSubrange(r) }
        // "(Summer)", "[Event]"… variants are the same map.
        t = t.replacingOccurrences(of: #"[\(\[][^\)\]]*[\)\]]?"#, with: "", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    }

    /// Holds the unit and hovers a grid of points; keeps the ones where the range circle turns blue.
    private var scanBad: [NormPoint] = []          // filled by probeGrid: spots a real test-place rejected
    private var lastScanHitLimit = false

    private func probeGrid(slot: Int, label: String, hill: Bool) async throws -> [NormPoint] {
        scanBad = []
        lastScanHitLimit = false
        if let price = await cost(of: slot) {
            scanProgress = "\(label): waiting for \(price)¥ to hold slot \(slot)…"
            _ = try await poll(timeout: 900, what: "\(price)¥ for slot \(slot)") { img -> Bool? in
                self.enoughYen(img, price)
            }
        }
        var points: [NormPoint] = []
        for y in stride(from: 0.24, through: 0.83, by: 0.05) {
            for x in stride(from: 0.04, through: 0.78, by: 0.04) {
                let p = NormPoint(x: x, y: y)
                if !AutoPlanner.hud.contains(where: { $0.contains(CGPoint(x: x, y: y)) }) { points.append(p) }
            }
        }
        func hold() async -> CGImage? {
            await WindowManager.focusRoblox()
            await input.key(String(slot))
            try? await Task.sleep(nanoseconds: lag(400_000_000))
            input.move(NormPoint(x: 0.5, y: 0.95))
            try? await Task.sleep(nanoseconds: lag(250_000_000))
            return try? await ScreenCapture.captureRoblox()
        }
        // Reference shot with NO unit held, so the overlay (green hills / red lane) can be isolated.
        await input.key("q")
        input.move(NormPoint(x: 0.5, y: 0.95))
        try await Task.sleep(nanoseconds: lag(500_000_000))
        guard let base = try? await ScreenCapture.captureRoblox(), var parked = await hold() else { return [] }
        let overlay = AutoPlanner(bases: [base], helds: [parked])
        var valid: [NormPoint] = []
        var maybe: [NormPoint] = []
        var rejected = 0
        for (n, p) in points.enumerated() {
            try Task.checkCancellation()
            let ci = cardInterrupts
            await yieldToCards()
            if cardInterrupts != ci, let pk = await hold() { parked = pk }      // cards took the unit away
            scanProgress = "\(label) scan: \(n + 1)/\(points.count) · \(valid.count) valid"
            input.move(p)
            try await Task.sleep(nanoseconds: lag(120_000_000))
            guard let hovering = try? await ScreenCapture.captureRoblox() else { continue }
            if n % 20 == 0 {
                scanEnemies(hovering)
                if Self.cardScreenVote(hovering) != nil {             // cards: release, vote, pick back up
                    await input.key("q"); cardVotedAt = .distantPast
                    try? await handleCards(hovering)
                    if let pk = await hold() { parked = pk }
                    continue
                }
            }
            // Two independent checks must agree:
            //  1) the range circle turned clearly BLUE, and
            //  2) the overlay agrees — hill units: inside the green hill area; ground: not red.
            let verdict = Self.rangeCircleVerdict(parked: parked, hovering: hovering, at: p, strict: true)
            let c = overlay?.overlayCounts(at: p) ?? (green: 0, red: 0)
            let overlayOK = overlay == nil || (hill ? c.green >= 5 : c.red <= 2)
            if verdict == .valid {
                if overlayOK { valid.append(p) } else { rejected += 1 }
            } else if verdict == .unsure && overlayOK {
                maybe.append(p)                 // colour check unsure: let the real test decide
            }
            if n % 40 == 39 {                                             // refresh the reference shot
                input.move(NormPoint(x: 0.5, y: 0.95))
                try? await Task.sleep(nanoseconds: lag(200_000_000))
                if let pk = try? await ScreenCapture.captureRoblox() { parked = pk }
            }
        }
        await input.key("q")
        say("Scan (\(label), slot \(slot)): \(valid.count) of \(points.count) points look placeable, \(maybe.count) unsure (\(rejected) blue-but-not-\(hill ? "green" : "free") rejected)")

        // The colour checks can be fooled (e.g. blue tint on a blue map). Confirm each candidate
        // for real: place the unit, check the counter went up, sell it with X right away.
        // Test the likely spots plus the unsure ones (the colour check misses real spots too).
        func spread(_ a: [NormPoint], _ k: Int) -> [NormPoint] {
            guard a.count > k else { return a }
            let step = Double(a.count) / Double(k)
            return (0..<k).map { a[Int(Double($0) * step)] }
        }
        var candidates = spread(valid, 60) + spread(maybe, 40)
        guard !candidates.isEmpty else { return valid }
        candidates.shuffle()                            // even coverage if it gets cut short
        var confirmed: [NormPoint] = []
        var problems = 0
        var tested = Set<String>()
        func key(_ p: NormPoint) -> String { String(format: "%.3f,%.3f", p.x, p.y) }
        for (n, p) in candidates.enumerated() {
            tested.insert(key(p))
            try Task.checkCancellation()
            if try await checkResults() { break }
            scanProgress = "\(label): test-placing \(n + 1)/\(candidates.count) · \(confirmed.count) confirmed"
            let ciT = cardInterrupts
            let result = await testPlaceAndSell(slot: slot, at: p)
            if cardInterrupts != ciT && result != true { continue }        // disturbed by cards: don't judge the spot
            switch result {
            case .some(true): confirmed.append(p); problems = 0
            case .some(false): scanBad.append(p); problems = 0
            case .none:
                problems += 1
                if problems >= 3 {
                    say("Scan: stopped test-placing after 3 problems in a row (see the lines above)")
                    if confirmed.isEmpty { lastScanHitLimit = true }
                    return confirmed.isEmpty ? valid : confirmed
                }
                try? await Task.sleep(nanoseconds: lag(2_000_000_000))      // e.g. wait for yen
            }
        }
        say("Scan (\(label)): \(confirmed.count) of \(candidates.count) candidate spots confirmed by actually placing")

        // Fill in around good spots: test the half-step neighbours of each confirmed spot.
        var extra: [NormPoint] = []
        for c in confirmed {
            for (dx, dy) in [(0.02, 0.0), (-0.02, 0.0), (0.0, 0.025), (0.0, -0.025)] {
                let q = NormPoint(x: c.x + dx, y: c.y + dy)
                guard q.x > 0.02, q.x < 0.79, q.y > 0.22, q.y < 0.85,
                      !AutoPlanner.hud.contains(where: { $0.contains(CGPoint(x: q.x, y: q.y)) }),
                      !tested.contains(key(q)) else { continue }
                tested.insert(key(q)); extra.append(q)
            }
        }
        extra = Array(extra.shuffled().prefix(40))
        var added = 0
        problems = 0
        for (n, q) in extra.enumerated() {
            try Task.checkCancellation()
            if try await checkResults() { break }
            scanProgress = "\(label): filling in around good spots \(n + 1)/\(extra.count)"
            switch await testPlaceAndSell(slot: slot, at: q) {
            case .some(true): confirmed.append(q); added += 1; problems = 0
            case .some(false): scanBad.append(q); problems = 0
            case .none:
                problems += 1
                if problems >= 3 { break }
                try? await Task.sleep(nanoseconds: lag(2_000_000_000))
            }
            if problems >= 3 { break }
        }
        if !extra.isEmpty { say("Scan (\(label)): filled in \(added) more spots next to confirmed ones") }
        return confirmed
    }

    /// The unit panel that pops up right after a placement. Unsellable units (e.g. slot 6) have
    /// no Sell button, so look for any of the panel's own words.
    /// Everything worth knowing right after a placement click, from ONE text read (it used to be
    /// five separate reads, ~1 s per failed try).
    struct AfterClick { var panel = false, limit = false, noYen = false, failed = false }
    static func readAfterClick(_ img: CGImage) -> AfterClick {
        var r = AfterClick()
        guard let lines = try? OCR.read(img, region: CGRect(x: 0, y: 0.28, width: 0.92, height: 0.64)) else { return r }
        let panelWords = ["upgrade", "upg", "targeting", "target", "first", "strongest", "weakest", "last",
                          "damage", "range", "spa", "totaldamage"]
        var hits = 0
        for l in lines {
            let t = OCR.norm(l.text)
            if l.box.midX < 0.48 {
                if t.hasPrefix("sell") { r.panel = true }
                if panelWords.contains(where: { t.hasPrefix($0) }) { hits += 1 }
            }
            if t.contains("cannotplacemore") || t.contains("placemorethan") || t.contains("uniqueunits")
                || t.contains("maynotbeplaced") || t.contains("othersofitskind") { r.limit = true }
            else if t.contains("cannotplace") || t.contains("cantplace") || t.contains("invalidplacement")
                || t.contains("invalidposition") || t.contains("toocloseto") || t.contains("mustbeplaced")
                || t.contains("cannotbeplaced") || t.contains("unabletoplace") || t.contains("placementinvalid") { r.failed = true }
            if t.contains("notenough") || t.contains("cannotafford") || t.contains("insufficient") || t.contains("needmore") { r.noYen = true }
        }
        if hits >= 2 { r.panel = true }
        return r
    }

    static func unitPanelOpen(_ img: CGImage) -> Bool {
        if sellButton(img) != nil { return true }
        guard let lines = try? OCR.read(img, region: CGRect(x: 0, y: 0.30, width: 0.48, height: 0.62)) else { return false }
        let words = lines.map { OCR.norm($0.text) }
        let hits = words.filter { t in
            t.hasPrefix("upgrade") || t.hasPrefix("upg") || t.hasPrefix("targeting") || t.hasPrefix("target")
                || t.hasPrefix("first") || t.hasPrefix("strongest") || t.hasPrefix("weakest") || t.hasPrefix("last")
                || t.hasPrefix("damage") || t.hasPrefix("range") || t.hasPrefix("spa") || t.hasPrefix("totaldamage")
        }
        return hits.count >= 2
    }

    /// Where the placed unit's panel shows its Sell button (the panel auto-opens after placing).
    static func sellButton(_ img: CGImage) -> OCR.Line? {
        guard let lines = try? OCR.read(img, region: CGRect(x: 0, y: 0.30, width: 0.48, height: 0.62)) else { return nil }
        return lines.first { OCR.norm($0.text).hasPrefix("sell") }
    }

    /// Test-places the unit at p and sells it again.
    /// true = placed (spot is good), false = didn't place (spot is bad), nil = can't keep testing.
    private func testPlaceAndSell(slot: Int, at p: NormPoint) async -> Bool? {
        await WindowManager.focusRoblox()
        await input.key(String(slot))
        try? await Task.sleep(nanoseconds: lag(300_000_000))
        if let held = try? await ScreenCapture.captureRoblox() {
            if Self.placementLimitMessage(held) { await input.key("q"); say("Scan: slot \(slot) is at its limit"); return nil }
            if Self.notEnoughYenMessage(held) { await input.key("q"); say("Scan: not enough yen to test-place"); return nil }
            if let c = Self.readSlotCounter(held, slot: slot), c.placed >= c.limit {
                await input.key("q"); say("Scan: slot \(slot) is full (\(c.placed)/\(c.limit))"); return nil
            }
        }
        input.move(p)
        try? await Task.sleep(nanoseconds: lag(200_000_000))
        await input.click(p)
        try? await Task.sleep(nanoseconds: lag(700_000_000))
        guard let after = try? await ScreenCapture.captureRoblox() else { await input.key("q"); return false }
        if Self.notEnoughYenMessage(after) { await input.key("q"); say("Scan: not enough yen to test-place"); return nil }
        if Self.placementLimitMessage(after) { await input.key("q"); say("Scan: slot \(slot) hit its limit"); return nil }

        // Placed = the unit's panel popped up (it has a Sell button).
        guard let sell = Self.sellButton(after) else {
            await input.key("q")                              // still holding it → spot was bad
            try? await Task.sleep(nanoseconds: lag(150_000_000))
            return false
        }
        // Sell it: click the Sell button; X as a backup; confirm if the game asks.
        for attempt in 0..<3 {
            if attempt == 0 { await input.click(sell.center) } else { await input.key("x") }
            try? await Task.sleep(nanoseconds: lag(500_000_000))
            guard let img = try? await ScreenCapture.captureRoblox() else { continue }
            if let confirm = (try? OCR.read(img, region: Region.centerPopup, fast: true))?
                .first(where: { ["yes", "confirm", "sell"].contains(OCR.norm($0.text)) }) {
                await input.click(confirm.center)
                try? await Task.sleep(nanoseconds: lag(400_000_000))
            }
            if let img2 = try? await ScreenCapture.captureRoblox(), Self.sellButton(img2) == nil { return true }
        }
        say("⚠️ Scan: placed a test unit at (\(String(format: "%.2f, %.2f", p.x, p.y))) but couldn't sell it")
        await input.click(Region.unitPanelClose)
        return nil
    }

    /// Saves logs/scan-<map>.png: blue dots = ground spots, green = hill spots, yellow = lane.
    private func saveScanPicture(_ p: MapProfile, over img: CGImage) {
        let W = img.width, H = img.height
        guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: W, height: H))
        func dot(_ q: NormPoint, _ c: CGColor, _ r: Double) {
            ctx.setFillColor(c)
            ctx.fillEllipse(in: CGRect(x: q.x * Double(W) - r, y: Double(H) - q.y * Double(H) - r, width: 2 * r, height: 2 * r))
        }
        for q in p.lane { dot(q, CGColor(red: 1, green: 0.9, blue: 0, alpha: 0.8), 5) }
        for q in p.ground { dot(q, CGColor(red: 0.2, green: 0.5, blue: 1, alpha: 0.9), 9) }
        for q in p.hill { dot(q, CGColor(red: 0.1, green: 1, blue: 0.3, alpha: 0.9), 7) }
        if let out = ctx.makeImage() { DebugLog.savePNG(out, name: "scan-\(p.name).png") }
    }

    // MARK: Map knowledge used during a match

    /// The scan in use this match (updated as we learn), and how far today's view is shifted from it.
    private var activeProfile: MapProfile?
    private var mapShift = (dx: 0.0, dy: 0.0)

    /// Loads this map's scan and lines it up with the current view (camera check).
    private func loadProfileForMatch() async {
        activeProfile = nil; mapShift = (0, 0)
        guard let prof = store?.profile(forTitle: currentTitle) else { return }
        if let file = prof.referenceImage, let ref = store?.reference(file),
           let cur = try? await ScreenCapture.captureRoblox(),
           let m = Matcher.viewShift(reference: ref, current: cur) {
            if m.score > 0.25 {
                // Weather, other players' units and effects change the picture a lot even when the
                // camera is the same — throwing the scan away made every repeat map start from zero.
                // Use it anyway (unshifted, unless the shift clearly helped); every spot is still
                // checked before and after clicking.
                mapShift = (0, 0)
                say(String(format: "View looks different from the %@ scan (difference %.2f — weather/units) — using the scan anyway, checking each spot", prof.name, m.score))
                activeProfile = prof
                return
            }
            if abs(m.dx) > 0.025 || abs(m.dy) > 0.035 {
                // The camera reset gives the same view every time; a shift this big is the
                // matcher being fooled by weather/units. (A +9 % "shift" moved every spot off target.)
                mapShift = (0, 0)
                say(String(format: "Camera check vs %@ scan: ignoring a shift of (%+.3f, %+.3f) — too big to be real", prof.name, m.dx, m.dy))
            } else {
                mapShift = (0, 0)     // camera reset is identical every match — never shift saved spots
                say(String(format: "Camera check vs %@ scan: shift (%+.3f, %+.3f), difference %.2f", prof.name, m.dx, m.dy, m.score))
            }
        } else {
            say("Using the \(prof.name) scan (no reference view saved — rescan to enable the camera check)")
        }
        activeProfile = prof
        cleanTaughtFromBad()
    }

    /// Your taught spots can never be "bad": remove any bad/suspect entries sitting on them
    /// (a wrong camera shift once made the macro miss them and blame the spots).
    private func cleanTaughtFromBad() {
        guard var prof = activeProfile, let taught = prof.taught, !taught.isEmpty else { return }
        func onTaught(_ p: NormPoint) -> Bool { taught.contains { abs($0.at.x - p.x) < 0.025 && abs($0.at.y - p.y) < 0.035 } }
        let before = (prof.badGround?.count ?? 0) + (prof.badHill?.count ?? 0) + (prof.suspectGround?.count ?? 0) + (prof.suspectHill?.count ?? 0)
        prof.badGround?.removeAll(where: onTaught); prof.badHill?.removeAll(where: onTaught)
        prof.suspectGround?.removeAll(where: onTaught); prof.suspectHill?.removeAll(where: onTaught)
        let after = (prof.badGround?.count ?? 0) + (prof.badHill?.count ?? 0) + (prof.suspectGround?.count ?? 0) + (prof.suspectHill?.count ?? 0)
        if after < before {
            store?.saveProfile(prof); activeProfile = prof
            say("Cleared \(before - after) wrong 'bad spot' marks that were sitting on your taught spots")
        }
    }

    private func shifted(_ p: NormPoint) -> NormPoint { NormPoint(x: p.x + mapShift.dx, y: p.y + mapShift.dy) }
    private func unshifted(_ p: NormPoint) -> NormPoint { NormPoint(x: p.x - mapShift.dx, y: p.y - mapShift.dy) }

    /// Every real placement teaches the map: good spots are added, clicked-and-failed spots are
    /// remembered as bad. Creates the map's entry if it has none yet.
    private func learnSpot(_ p: NormPoint, hill: Bool, good: Bool) {
        let name = activeProfile?.name ?? store?.canonicalName(Self.mapName(fromTitle: currentTitle)) ?? Self.mapName(fromTitle: currentTitle)
        guard !name.isEmpty else { return }
        var prof = activeProfile ?? store?.profiles.first(where: { $0.name == name })
            ?? MapProfile(name: name, ground: [], hill: [], lane: enemyLane, scannedAt: Date())
        let q = unshifted(p)
        func near(_ list: [NormPoint]) -> Bool { list.contains { abs($0.x - q.x) < 0.012 && abs($0.y - q.y) < 0.015 } }
        if good {
            if hill { if !near(prof.hill) { prof.hill.append(q) }; prof.badHill?.removeAll { abs($0.x - q.x) < 0.012 && abs($0.y - q.y) < 0.015 } }
            else { if !near(prof.ground) { prof.ground.append(q) }; prof.badGround?.removeAll { abs($0.x - q.x) < 0.012 && abs($0.y - q.y) < 0.015 } }
        } else if hill {
            if near(prof.suspectHill ?? []) {          // failed in an earlier match too → bad for good
                if !near(prof.badHill ?? []) { prof.badHill = (prof.badHill ?? []) + [q] }
                prof.hill.removeAll { abs($0.x - q.x) < 0.012 && abs($0.y - q.y) < 0.015 }   // a scan "good" that keeps failing isn't good
            } else if !near(prof.suspectHill ?? []) {
                prof.suspectHill = (prof.suspectHill ?? []) + [q]
            }
        } else {
            if near(prof.suspectGround ?? []) {
                if !near(prof.badGround ?? []) { prof.badGround = (prof.badGround ?? []) + [q] }
                prof.ground.removeAll { abs($0.x - q.x) < 0.012 && abs($0.y - q.y) < 0.015 }
            } else if !near(prof.suspectGround ?? []) {
                prof.suspectGround = (prof.suspectGround ?? []) + [q]
            }
        }
        if prof.lane.count < enemyLane.count { prof.lane = enemyLane.map(unshifted) }
        activeProfile = prof
        store?.saveProfile(prof)
    }

    /// Placement candidates from a saved scan: placeable for this unit type, off the lane,
    /// not near units already placed, most lane in range first.
    private func profileSpots(_ prof: MapProfile, hill: Bool, range: Double, avoid: [NormPoint]) -> [NormPoint] {
        let aspect = Double(WindowManager.lockedSize.height / WindowManager.lockedSize.width)
        func d(_ a: NormPoint, _ b: NormPoint) -> Double { let dx = a.x - b.x, dy = (a.y - b.y) * aspect; return (dx * dx + dy * dy).squareRoot() }
        let lane = prof.lane.isEmpty ? enemyLane : prof.lane.map(shifted)
        let bad = (hill ? prof.badHill : prof.badGround)?.map(shifted) ?? []
        let pool = (hill ? prof.hill : prof.ground).map(shifted).filter { p in
            !avoid.contains { d($0, p) < 0.03 } && !lane.contains { d($0, p) < 0.018 } && !bad.contains { d($0, p) < 0.012 }
        }
        let scored = pool.map { p in (p, lane.filter { d($0, p) <= range }.count) }.filter { $0.1 > 0 }
        return scored.sorted { $0.1 > $1.1 }.map(\.0)
    }

    // MARK: Auto mode — steps

    /// One instruction from the Steps box (or built from Place order if Steps is empty).
    enum AutoStep: CustomStringConvertible {
        case place(slot: Int, count: Int)
        case upgrade(slot: Int?, levels: Int?)     // slot nil = all units; levels nil = to MAX
        case waitWave(Int)
        case wait(Double)
        case scan                                   // learn this map now (if it isn't known well yet)
        var description: String {
            switch self {
            case let .place(s, c): return "place \(s)" + (c > 1 ? " x\(c)" : "")
            case let .upgrade(s, l): return "upgrade \(s.map(String.init) ?? "all") " + (l.map { "+\($0)" } ?? "max")
            case let .waitWave(w): return "wait wave \(w)"
            case let .wait(t): return "wait \(Int(t))s"
            case .scan: return "scan"
            }
        }
    }

    /// Parses lines like:  place 6 · place 2 x4 · upgrade 6 max · upgrade 1 +3 · upgrade all max ·
    /// wait wave 10 · wait 30   (one per line, or separated by ';'). Unknown lines are reported.
    /// The Steps box can hold per-map sections:
    ///     place 6            ← default steps (every map without its own section)
    ///     …
    ///     [Storm Hideout]    ← only on Storm Hideout
    ///     place 3 x2
    ///     …
    /// Returns the section for this map (name match ignores case/spaces/typos), else the default.
    static func stepsText(for map: String, in text: String) -> (text: String, section: String?) {
        var sections: [(name: String, lines: [String])] = [("", [])]
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("["), line.hasSuffix("]") {
                sections.append((String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces), []))
            } else {
                sections[sections.count - 1].lines.append(String(raw))
            }
        }
        let m = OCR.norm(map)
        if !m.isEmpty, let hit = sections.dropFirst().first(where: { sec in
            let n = OCR.norm(sec.name)
            return !n.isEmpty && (m.contains(n) || n.contains(m) || Store.editDistance(m, n) <= 2)
        }) {
            return (hit.lines.joined(separator: "\n"), hit.name)
        }
        return (sections[0].lines.joined(separator: "\n"), nil)
    }

    static func parseSteps(_ text: String) -> (steps: [AutoStep], problems: [String]) {
        var steps: [AutoStep] = [], problems: [String] = []
        for raw in text.lowercased().split(whereSeparator: { $0 == "\n" || $0 == ";" }) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("[") { continue }   // "[Map]" = section header
            let w = line.replacingOccurrences(of: "×", with: "x").split(separator: " ").map(String.init)
            func num(_ s: String) -> Int? { Int(s.filter(\.isNumber)) }
            var first = w.first ?? ""
            if first.hasPrefix("scan") || first.hasPrefix("learn") { first = "scan" }      // "scano", "scan." …
            if first.hasPrefix("plac") { first = "place" }
            if first.hasPrefix("upg") { first = "upgrade" }
            switch first {
            case "place", "p":
                guard w.count >= 2, let slot = num(w[1]), (1...6).contains(slot) else { problems.append(line); continue }
                let count = w.count >= 3 ? (num(w[2]) ?? 1) : 1
                steps.append(.place(slot: slot, count: max(1, count)))
            case "upgrade", "up", "u":
                guard w.count >= 2 else { problems.append(line); continue }
                let slot: Int? = w[1] == "all" ? nil : num(w[1])
                if w[1] != "all" && !(1...6).contains(slot ?? 0) { problems.append(line); continue }
                let rest = w.dropFirst(2).joined()
                let levels: Int? = rest.isEmpty ? 1 : (rest.contains("max") ? nil : num(rest))
                steps.append(.upgrade(slot: slot, levels: levels))
            case "scan", "learn":
                steps.append(.scan)
            case "wait", "w":
                if w.count >= 3, w[1] == "wave", let n = num(w[2]) { steps.append(.waitWave(n)) }
                else if w.count >= 2, let n = num(w[1]) { steps.append(.wait(Double(n))) }
                else { problems.append(line) }
            default:
                problems.append(line)
            }
        }
        return (steps, problems)
    }

    // Per-match auto state
    private var autoPlaced: [(slot: Int, at: NormPoint)] = []
    private var autoCovered: [Int: Int] = [:]
    private var autoFull = Set<Int>()
    private var autoMaxed = Set<Int>()          // indexes into autoPlaced

    /// Plays a map with no recording, following the Steps box (or Place order + priority settings).
    private func autoPlay() async throws {
        inStage = true
        if !didSpawnReset {
            await teleportToSpawn()
            let cs = store?.settings ?? MacroSettings()
            if cs.cameraReset { await Camera.reset(input, settings: cs) }
        }
        didSpawnReset = false
        let s = store?.settings ?? MacroSettings()
        let n0 = Self.mapName(fromTitle: currentTitle)
        if n0.isEmpty || !Self.plausibleTitle(currentTitle, name: n0, known: store?.profiles.map(\.name) ?? []) {
            currentTitle = await waitForTitle()
        }
        // Map name: the title read several times (majority) and the matchmaking popup must agree on
        // a real map. Popup wins a tie — its text is big and clean.
        do {
            var votes: [String: Int] = [:]
            if let k = Store.knownMap(Self.mapName(fromTitle: currentTitle)) { votes[k, default: 0] += 1 }
            for _ in 0..<3 {
                try? await Task.sleep(nanoseconds: lag(500_000_000))
                guard let img = try? await ScreenCapture.captureRoblox() else { continue }
                let t = (try? OCR.read(img, region: Region.stageTitle).map(\.text).joined(separator: " ")) ?? ""
                if let k = Store.knownMap(Self.mapName(fromTitle: t)) { votes[k, default: 0] += 1 }
            }
            if !popupMapHint.isEmpty { votes[popupMapHint, default: 0] += 2 }
            if let best = votes.max(by: { $0.value < $1.value })?.key {
                if best != Store.knownMap(Self.mapName(fromTitle: currentTitle)) {
                    say("Map name: using \(best) (title read \"\(currentTitle)\", popup said \"\(popupMapHint)\")")
                }
                currentTitle = best + " Summer Hunt"
            } else if !popupMapHint.isEmpty {
                currentTitle = popupMapHint + " Summer Hunt"
            }
            say("Map: \(Self.mapName(fromTitle: currentTitle))" + (popupMapHint.isEmpty ? "" : " (popup: \(popupMapHint))"))
        }
        currentMap = (Self.mapName(fromTitle: currentTitle).isEmpty ? "unknown" : Self.mapName(fromTitle: currentTitle)) + " · auto"
        // The title already shows on the loading screen ("… 68250/68250 Loading…", whose tips can
        // even look like game messages). Wait until the stage is really running: wave counter up,
        // no "Loading" text.
        do {
            let end = Date().addingTimeInterval(45)
            var said = false
            while Date() < end, !Task.isCancelled {
                if let img = try? await ScreenCapture.captureRoblox() {
                    let loading = ((try? OCR.read(img, fast: true)) ?? []).contains { OCR.norm($0.text).contains("loading") }
                    if !loading, Self.readWave(img) != nil { break }
                }
                if !said { say("Waiting for the stage to finish loading…"); said = true }
                try? await Task.sleep(nanoseconds: lag(1_000_000_000))
            }
        }
        matchTries = []; matchPlanned = [:]; matchPlaceTime = [:]
        matchStartImage = try? await ScreenCapture.captureRoblox()
        if let img = matchStartImage {
            DebugLog.savePNG(img, name: "\(DebugLog.stamp())-start-\(Self.mapName(fromTitle: currentTitle)).png")
        }
        autoPlaced = []; autoCovered = [:]; autoFull = []; autoMaxed = []
        blockedGround = []; blockedHill = []

        // Build the step list.
        var steps: [AutoStep]
        let mapForSteps = activeProfile?.name ?? store?.canonicalName(Self.mapName(fromTitle: currentTitle)) ?? Self.mapName(fromTitle: currentTitle)
        let chosen = Self.stepsText(for: mapForSteps, in: s.autoSteps)
        if let sec = chosen.section { say("Using the [\(sec)] steps for this map") }
        let parsed = Self.parseSteps(chosen.text)
        if !parsed.steps.isEmpty {
            steps = parsed.steps
            for p in parsed.problems { say("⚠️ Didn't understand step \"\(p)\" — skipping it") }
        } else {
            // No steps written: Place order, with priority units getting their early levels.
            var order = s.autoPlaceOrder
            if order.isEmpty { order = [1, 2, 3, 4, 5, 6]; say("⚠️ Place order is empty — using 1 2 3 4 5 6") }
            steps = []
            for slot in order {
                steps.append(.place(slot: slot, count: 1))
                if s.prioritySlots.contains(slot), s.autoEarlyUpgrades > 0 {
                    steps.append(.upgrade(slot: slot, levels: s.autoEarlyUpgrades >= 15 ? nil : s.autoEarlyUpgrades))
                }
            }
        }
        say("Auto steps: " + steps.map(\.description).joined(separator: " → "))
        await loadProfileForMatch()
        teachingThisMatch = false
        let taughtSlots = Set((activeProfile?.taught ?? []).map(\.slot))
        let needTeach = s.teachHillsOnly ? !s.hillSlots.isEmpty && !s.hillSlots.allSatisfy(taughtSlots.contains)
                                         : taughtSlots.isEmpty
        if (s.teachMode && needTeach) || teachNextMatch {
            teachNextMatch = false
            let name = activeProfile?.name ?? store?.canonicalName(Self.mapName(fromTitle: currentTitle)) ?? Self.mapName(fromTitle: currentTitle)
            if !name.isEmpty {
                teachingThisMatch = true; teachName = name; teachSpots = []
                say("🎓 TEACH MODE — \(name) isn't taught yet. When \(s.teachHillsOnly ? "a hill unit" : "a unit") is due I'll ask you to place it; I do everything else.")
            }
        }
        defer { teachListener?.stop(); teachListener = nil }
        if let t = activeProfile?.taught, !t.isEmpty {
            say("Using your taught spots for \(activeProfile?.name ?? "this map") (\(t.count) units)")
        }
        if let l = activeProfile?.learned, !l.isEmpty {
            say("Learned layout for \(activeProfile?.name ?? "this map"): \(l.count) spots from earlier matches")
        }
        if let prof = activeProfile {
            say("Using saved scan for \(prof.name) (\(prof.ground.count) ground / \(prof.hill.count) hill spots)")
            enemyLane = prof.lane.map(shifted)
        } else {
            say("No saved scan for this map — figuring it out live")
            await learnLane(seconds: 10)
        }

        var learnedThisMatch = false
        var unplaced: [Int] = []
        func mapIsWeak() -> Bool {
            guard let p = activeProfile else { return true }
            return p.ground.count + p.hill.count < 15 || p.referenceImage == nil
        }
        for (stepIndex, step) in steps.enumerated() {
            try Task.checkCancellation()
            if try await checkResults() { return }
            try await handleCards()
            say("Step: \(step)")
            switch step {
            case let .place(slot, count):
                matchPlanned[slot, default: 0] += count
                for _ in 0..<count {
                    if autoFull.contains(slot) { break }
                    if !(try await placeSlot(slot)) {
                        if !autoFull.contains(slot) { unplaced.append(slot) }
                        break
                    }
                }
            case let .upgrade(slot, levels):
                phantomSlots = []
                // At most 3 minutes per upgrade step, so a slow upgrade (waiting on money) can't hold
                // up placing the rest of the team. Leftover levels are done after the last step.
                upgradeDeadline = Date().addingTimeInterval(180)
                try await upgradeStep(slot: slot, levels: levels)
                if let d = upgradeDeadline, Date() > d { say("Upgrade step took 3 min — moving on, finishing it after the last step") }
                upgradeDeadline = nil
                for sl in phantomSlots {
                    autoFull.remove(sl)
                    if try await placeSlot(sl) { try await upgradeStep(slot: sl, levels: levels) }
                    else if !autoFull.contains(sl) { unplaced.append(sl) }
                }
                phantomSlots = []
            case let .waitWave(w):
                _ = try await poll(timeout: 3600, what: "wave \(w)") { img -> Bool? in
                    let n = Self.readWave(img) ?? 0
                    return n >= w ? true : nil
                }
            case let .wait(t):
                try await sleepWatchingCards(t)
            case .scan where steps[(stepIndex + 1)...].contains(where: { if case .place = $0 { return true }; return false }):
                // A scan test-places for minutes (8 min on Strange Town) while the rest of the team
                // waits — that lost the match. It now runs after the last placement instead.
                say("Scan step: placing the rest of the team first — scanning after that if needed")
            case .scan:
                if s.learnWhilePlaying && mapIsWeak() && !learnedThisMatch {
                    learnedThisMatch = true
                    try await learnMapNow()
                } else {
                    say("Scan step: this map is already known — skipping")
                }
            }
        }

        // Units that couldn't be placed earlier: one more go now (more money, more map knowledge).
        for slot in unplaced where !autoFull.contains(slot) {
            if try await checkResults() { return }
            say("Retrying slot \(slot)")
            _ = try await placeSlot(slot)
        }
        // Still don't know this map well (fewer than 3 units placed)? Learn it now.
        if s.learnWhilePlaying, !learnedThisMatch, mapIsWeak() {
            learnedThisMatch = true
            try await learnMapNow()
        }

        // Steps done: keep spending money — priority units first, then everyone, until all MAX.
        say("Steps done — upgrading everything to MAX")
        try await upgradeStep(slot: nil, levels: nil)
        // Units still missing? Keep trying every minute until the match ends — an empty slot is
        // the most common reason for a loss.
        var missing = unplaced.filter { !autoFull.contains($0) }
        var tries = 0
        while !missing.isEmpty, tries < 20 {
            tries += 1
            if try await checkResults() { return }
            try? await sleepWatchingCards(60)
            if try await checkResults() { return }
            for slot in missing {
                say("Still missing slot \(slot) — trying again")
                if try await placeSlot(slot) { try await upgradeStep(slot: slot, levels: nil) }
            }
            missing = missing.filter { sl in !autoFull.contains(sl) && !autoPlaced.contains { $0.slot == sl } }
        }
        say("Auto: everything maxed — waiting for the match to end")
    }

    /// Upgrades every placed copy of a slot (or all units, priority order first).
    /// levels nil = until MAX (or the unit card's Max upgrade).
    /// Set while a Steps "upgrade" step runs: upgrades stop at this time.
    private var upgradeDeadline: Date?

    private func upgradeStep(slot: Int?, levels: Int?) async throws {
        let s = store?.settings ?? MacroSettings()
        let targets = autoPlaced.indices.filter { autoPlaced[$0].slot != 0 && (slot == nil || autoPlaced[$0].slot == slot) }
            .sorted { a, b in
                let pa = s.prioritySlots.firstIndex(of: autoPlaced[a].slot) ?? 99
                let pb = s.prioritySlots.firstIndex(of: autoPlaced[b].slot) ?? 99
                return (pa, a) < (pb, b)
            }
        if targets.isEmpty { say("Nothing placed for slot \(slot.map(String.init) ?? "any") yet — skipping upgrade"); return }
        for i in targets where !autoMaxed.contains(i) {
            var misses = 0
            var remaining = levels ?? 99
            while remaining > 0 {
                try Task.checkCancellation()
                if let d = upgradeDeadline, Date() > d { return }
                if try await checkResults() { return }
                try await handleCards()
                // One panel open, R pressed repeatedly (waits for money between levels).
                switch await upgradeUnit(slot: autoPlaced[i].slot, at: autoPlaced[i].at, times: remaining) {
                case .some(true):
                    autoLog.append(.upgrade(placementIndex: i, times: remaining))
                    remaining = 0                                    // upgrade() did all it could this round
                    if levels == nil { remaining = 99; misses += 1; if misses > 30 { remaining = 0 } }
                case .some(false):
                    autoMaxed.insert(i); remaining = 0
                case .none:
                    misses += 1
                    if misses >= 3 {
                        remaining = 0
                        let sl = autoPlaced[i].slot
                        let ours = autoPlaced.filter { $0.slot == sl }.count
                        if let n = await placedCount(slot: sl), !n.full, n.placed < ours {
                            // The counter says it isn't there: that "placement" was a false alarm.
                            say("Auto: unit #\(i + 1) (slot \(sl)) isn't actually on the map — will place it again")
                            learnSpot(autoPlaced[i].at, hill: s.hillSlots.contains(sl), good: false)
                            autoPlaced[i].slot = 0                 // 0 = gone (keeps other indices valid)
                            phantomSlots.append(sl)
                        } else {
                            say("Auto: can't select unit #\(i + 1) (slot \(sl)) — skipping it")
                        }
                    }
                }
            }
        }
    }

    /// Places one copy of a slot, persistently: every round it gathers candidates from ALL sources
    /// (saved scan, live overlay, spots beside where enemies walk, a grid over the map), skips
    /// spots already tried or known bad, and tries them until one sticks — for up to 4 minutes.
    /// Every real attempt teaches the map (good spots saved, clicked-and-failed spots remembered).
    /// Returns false if the slot is full or nothing worked in time (it gets retried later).
    private func placeSlot(_ slot: Int) async throws -> Bool {
        let started = Date()
        defer { matchPlaceTime[slot, default: 0] += Date().timeIntervalSince(started) }
        let s = store?.settings ?? MacroSettings()
        let range = s.autoRangePerSlot[slot] ?? 0.12
        var tried: [NormPoint] = []
        var plannerUsed: AutoPlanner?
        let knowsSlot = !((activeProfile?.taught ?? []) + (activeProfile?.learned ?? [])).filter { $0.slot == slot }.isEmpty
        let isHillSlot = s.hillSlots.contains(slot)
        let hillPlacedAlready = autoPlaced.contains { $0.slot != 0 && s.hillSlots.contains($0.slot) }
        let firstSearch = isHillSlot && !knowsSlot && !hillPlacedAlready
        let noHillsHere = isHillSlot && (activeProfile?.noHills ?? false) && !knowsSlot && !hillPlacedAlready
        if noHillsHere {
            say("Slot \(slot): this map had no reachable hills last time — skipping the hill search")
            return false
        }
        // A hill unit on a map it doesn't know yet can take minutes to find a hill. Don't hold the
        // rest of the team hostage: give it 90 s, carry on with the steps, keep retrying later.
        let deadline = Date().addingTimeInterval(firstSearch ? 90 : 240)
        var round = 0
        var widened = false
        var gridMode = false

        func near(_ list: [NormPoint], _ p: NormPoint, _ r: Double = 0.015) -> Bool {
            list.contains { abs($0.x - p.x) < r && abs($0.y - p.y) < r * 1.4 }
        }

        if teachingThisMatch, !s.teachHillsOnly || s.hillSlots.contains(slot) {
            if let price = await cost(of: slot) {
                _ = try await poll(timeout: 900, what: "\(price)¥ for slot \(slot)") { img -> Bool? in self.enoughYen(img, price) }
            }
            if let p = try await teachPlace(slot) {
                matchTries.append((slot, p, true))
                autoPlaced.append((slot, p))
                return true
            }
            if try await checkResults() { return false }
        }

        while Date() < deadline {
            round += 1
            try Task.checkCancellation()
            if try await checkResults() { return false }
            try await handleCards()
            if let price = await cost(of: slot) {
                _ = try await poll(timeout: 900, what: "\(price)¥ for slot \(slot)") { img -> Bool? in
                    self.enoughYen(img, price)
                }
            }
            // A taught spot for this copy that hasn't been tried yet? Go straight to it — no need for
            // the full overlay read (~2 s); placeOnce still checks the circle, limit and counter.
            let copyNo = autoPlaced.filter { $0.slot == slot }.count
            let ownTaught = (activeProfile?.taught ?? []).filter { $0.slot == slot }
            let freshTaught = (ownTaught.isEmpty ? (activeProfile?.learned ?? []).filter { $0.slot == slot } : ownTaught).map(\.at)
                .dropFirst(copyNo).contains { t in !near(tried, t, 0.02) && !near(blockedGround + blockedHill, t, 0.012) }
            slotIsFull = false        // (was left over from the previous slot when readOverlay was skipped)
            let planner = (round == 1 && freshTaught) ? nil : await readOverlay(slot: slot)
            if slotIsFull { autoFull.insert(slot); say("Slot \(slot) is at its placement limit"); return false }
            plannerUsed = planner ?? plannerUsed
            let hill = s.hillSlots.isEmpty ? (planner?.isHillOverlay ?? false) : s.hillSlots.contains(slot)
            let taken = autoPlaced.map(\.at)
            // Unplaceable ground comes in patches (a building, a cliff, the lane edge), so a failed
            // spot rules out the area around it — "dead zones" — not just the exact point.
            let savedBad = (hill ? activeProfile?.badHill : activeProfile?.badGround)?.map(shifted) ?? []
            let deadZones = hill ? blockedHill : blockedGround
            let bad = savedBad + deadZones

            // Gather from every source, best sources first. Your taught spots for this slot come
            // before everything (the n-th copy of a slot goes to the n-th spot you used for it).
            var picks: [NormPoint] = []
            // Your taught spots first, then the layout learned from earlier matches (where each copy
            // of this slot actually went down last time).
            let learnedHere = (activeProfile?.learned ?? []).filter { $0.slot == slot }.map(\.at)
            var taughtHere = (activeProfile?.taught ?? []).filter { $0.slot == slot }.map(\.at)
            if taughtHere.isEmpty { taughtHere = learnedHere }
            if !taughtHere.isEmpty {
                let already = autoPlaced.filter { $0.slot == slot }.count
                picks += Array(taughtHere.dropFirst(already)) + Array(taughtHere.prefix(already))
            }
            // Other slots' taught spots of the same kind are good backups.
            picks += (activeProfile?.taught ?? []).filter { $0.slot != slot && s.hillSlots.contains($0.slot) == hill }.map(\.at)
            let taughtAll = picks
            if hill {
                // Hills are areas: right around any spot a hill unit is known to fit (taught, worked
                // before, or our own hill unit this match), small circles first. Strict: each point
                // still has to turn the range circle blue before it's clicked.
                let anchors = (activeProfile?.taught ?? []).filter { s.hillSlots.contains($0.slot) }.map(\.at)
                    + (activeProfile?.hill ?? []).map(shifted)
                    + autoPlaced.filter { s.hillSlots.contains($0.slot) && $0.slot != 0 }.map(\.at)
                picks += ringsAround(anchors, radii: [0.022, 0.035, 0.05])
            }
            if hill {
                // Hills are big: the best bet is right around a hill unit that's already down.
                picks += ringsAround(autoPlaced.filter { s.hillSlots.contains($0.slot) && $0.slot != 0 }.map(\.at),
                                     radii: widened ? [0.04, 0.06, 0.085, 0.11] : [0.035, 0.05, 0.07])
            }
            if !hill {
                // Placeable ground also comes in patches: right beside units that already went down
                // is the safest next spot.
                picks += ringsAround(autoPlaced.filter { !s.hillSlots.contains($0.slot) && $0.slot != 0 }.map(\.at),
                                     radii: [0.04, 0.055])
            }
            if let prof = activeProfile { picks += profileSpots(prof, hill: hill, range: range, avoid: taken + tried) }
            if let planner {
                picks += planner.candidates(range: range, taken: taken, covered: autoCovered, hill: hill,
                                            maxLaneDistance: 7, avoid: tried, limit: 12).map(\.spot)
            }
            if !hill || widened { picks += probeSpots(avoid: tried + taken) }
            if gridMode { picks += denseGrid() }
            // Hill units: only spots that are actually green in the overlay (when it shows green).
            if hill, let planner, planner.greenCellCount >= 40 {
                if !gridMode {
                    // (Never filter out spots right beside our own hill units — those are proven.)
                    let ownHill = autoPlaced.filter { $0.slot != 0 && s.hillSlots.contains($0.slot) }.map(\.at)
                    picks = picks.filter { p in taughtAll.contains(where: { $0.x == p.x && $0.y == p.y })
                        || near(ownHill, p, 0.07) || planner.overlayCounts(at: p).green >= 4 }
                }
            }
            var unique: [NormPoint] = []
            // Failed/blocked spots are avoided with some margin: a spot 1 % away from one that
            // didn't work almost never works either.
            for p in picks where !near(unique, p, 0.012) && !near(tried, p, gridMode ? 0.012 : 0.02) && !near(taken, p, 0.025) {
                // Saved "bad" marks never veto your taught spots (only this match's own failures do).
                let isTaught = taughtAll.contains { abs($0.x - p.x) < 0.001 && abs($0.y - p.y) < 0.001 }
                if !isTaught && (near(savedBad, p, 0.03) || near(deadZones, p, gridMode ? 0.04 : 0.05)) { continue }
                if isTaught && near(hill ? blockedHill : blockedGround, p, 0.012) { continue }
                unique.append(p)
            }
            // Ground units: the safe spots are right beside the road/route enemies walk — not the
            // corners and outskirts. Order by distance to the route (spots ON the road go last).
            let suspects = ((hill ? activeProfile?.suspectHill : activeProfile?.suspectGround) ?? []).map(shifted)
            if hill {
                // Hill: keep the order, but spots that failed in an earlier match go last.
                let ok = unique.filter { p in !suspects.contains { abs($0.x - p.x) < 0.02 && abs($0.y - p.y) < 0.028 } }
                unique = ok + unique.filter { p in !ok.contains { $0.x == p.x && $0.y == p.y } }
            }
            if !hill || gridMode {
                let lanePts = laneReference(planner: planner)
                if !lanePts.isEmpty {
                    let proven = Set((activeProfile?.ground ?? []).map(shifted).map { "\(Int($0.x * 200)),\(Int($0.y * 200))" })
                    func key(_ p: NormPoint) -> Double {
                        let d = lanePts.map { lp -> Double in
                            let dx = lp.x - p.x, dy = (lp.y - p.y) * 0.63
                            return (dx * dx + dy * dy).squareRoot()
                        }.min() ?? 1
                        if taughtAll.contains(where: { abs($0.x - p.x) < 0.001 && abs($0.y - p.y) < 0.001 }) {
                            return -1 + Double(taughtAll.firstIndex(where: { abs($0.x - p.x) < 0.001 && abs($0.y - p.y) < 0.001 }) ?? 0) * 0.001
                        }
                        if d < 0.02 { return 5 + d }                      // on the road itself
                        if suspects.contains(where: { abs($0.x - p.x) < 0.02 && abs($0.y - p.y) < 0.028 }) { return 3 + d }
                        let bonus = proven.contains("\(Int(p.x * 200)),\(Int(p.y * 200))") ? 0.015 : 0
                        return d - bonus
                    }
                    unique = unique.map { ($0, key($0)) }.sorted { $0.1 < $1.1 }.map(\.0)
                }
            }
            // Spread the tries out: after the best spot, the next one tried is at least ~6 % away
            // from the ones before it (so one bad patch costs one click, not five). Taught/learned
            // spots keep their place at the front.
            do {
                var spread: [NormPoint] = [], later: [NormPoint] = []
                // Right beside one of our own units of the same kind is proven ground (hills come in
                // patches too) — those spots aren't spread out, they're tried first.
                let mine = autoPlaced.filter { $0.slot != 0 && s.hillSlots.contains($0.slot) == hill }.map(\.at)
                for p in unique {
                    let isTaught = taughtAll.contains { abs($0.x - p.x) < 0.001 && abs($0.y - p.y) < 0.001 }
                    let besideMine = near(mine, p, 0.06)
                    if isTaught || besideMine || !near(spread, p, 0.06) { spread.append(p) } else { later.append(p) }
                }
                if !mine.isEmpty {
                    // Order: taught/learned, then beside our units, then the spread-out rest.
                    let t = spread.filter { p in taughtAll.contains { abs($0.x - p.x) < 0.001 && abs($0.y - p.y) < 0.001 } }
                    let b = spread.filter { p in !t.contains { $0.x == p.x && $0.y == p.y } && near(mine, p, 0.06) }
                    let r = spread.filter { p in !t.contains { $0.x == p.x && $0.y == p.y } && !b.contains { $0.x == p.x && $0.y == p.y } }
                    spread = t + b + r
                }
                unique = spread + later
            }
            if unique.isEmpty {
                if !widened {
                    // Widen once: bigger rings around our units, spots beside the lane, the grid.
                    widened = true
                    say("Slot \(slot): no fresh spots — widening the search")
                    continue
                }
                if !gridMode {
                    // Sweep the whole map, nearest the route first. A wrong click costs ~1 s and
                    // is remembered, so on a new map this finds the hills by itself; next time the
                    // learned layout goes straight to them.
                    gridMode = true
                    say("Slot \(slot): trying a grid over the whole map, nearest the route first")
                    continue
                }
                say("Slot \(slot): nothing left to try right now — moving on, will retry later")
                return false
            }
            say("Slot \(slot) (\(hill ? "hill" : "ground")) round \(round): \(unique.count) candidate spots")

            var needMoney = false
            var failedHere: [NormPoint] = []
            var attemptNo = 0
            for target in unique.prefix(15) {
                try Task.checkCancellation()
                attemptNo += 1
                // Right next to a spot that just showed a red circle / didn't place? Almost always
                // the same blocker (a unit, the lane edge) — skip, it saves a hover each.
                if near(failedHere, target, 0.05) { continue }
                if Date() > deadline { break }
                let ci = cardInterrupts
                let isTaughtTarget = taughtAll.contains { abs($0.x - target.x) < 0.001 && abs($0.y - target.y) < 0.001 }
                // The pre-checks (overlay red, red range circle) misfire a lot. A failed click costs
                // ~1 s and the game says so, so the best few guesses are always actually clicked.
                let result = await placeOnce(slot: slot, at: target, trusted: isTaughtTarget,
                                             forceTry: true)
                if cardInterrupts != ci, case .failed = result { continue }   // cards interrupted it — try again later
                tried.append(target)
                switch result {
                case .placed:
                    matchTries.append((slot, target, true))
                    learnSpot(target, hill: hill, good: true)
                    saveLearned(slot: slot, copy: autoPlaced.filter { $0.slot == slot }.count, at: target)
                    autoPlaced.append((slot, target))
                    autoLog.append(.place(slot: slot, at: target))
                    if let pl = plannerUsed { for c in pl.pathCells(near: target, range: range) { autoCovered[c, default: 0] += 1 } }
                    return true
                case .limitReached:
                    autoFull.insert(slot)
                    return false
                case .cantAfford:
                    needMoney = true
                case .failed:
                    let wasTaught = taughtAll.contains { abs($0.x - target.x) < 0.001 && abs($0.y - target.y) < 0.001 }
                    if lastFailWasClick || lastFailWasCircle { matchTries.append((slot, target, false)) }
                    // Clicked and nothing placed, or the range circle turned red: remember it for
                    // future matches (suspect after once, never tried again after twice).
                    if (lastFailWasClick || lastFailWasCircle) && !wasTaught { learnSpot(target, hill: hill, good: false) }
                    // Either way, don't try it again this match (another player's unit, most likely).
                    if lastFailWasBlock || lastFailWasClick {
                        if hill { blockedHill.append(target) } else { blockedGround.append(target) }
                        if !wasTaught { failedHere.append(target) }
                    }
                    continue
                }
                break
            }
            if needMoney { try await sleepWatchingCards(3) }
        }
        say("⚠️ Couldn't place slot \(slot) in \(firstSearch ? "90 s (new map, hill search)" : "4 minutes") — carrying on, will retry it later")
        return false
    }

    /// Teach mode state for this match.
    private var teachingThisMatch = false
    private var teachName = ""
    private var teachSpots: [TaughtSpot] = []
    private var teachListener: TeachListener?

    /// Teach mode: instead of picking a spot, ask YOU to place this slot, watch where you click,
    /// confirm it went down (unit panel pops up), save it, and carry on with the steps.
    /// Returns nil if you didn't place it in 3 minutes (the macro then places it itself).
    private func teachPlace(_ slot: Int) async throws -> NormPoint? {
        if teachListener == nil {
            let l = TeachListener(); l.start()
            guard l.isListening else {
                say("⚠️ Teach mode can't watch your input (Accessibility / Input Monitoring) — placing automatically")
                teachingThisMatch = false; return nil
            }
            teachListener = l
        }
        _ = teachListener?.take(olderThan: 0)                       // forget older clicks
        let n = autoPlaced.filter { $0.slot == slot }.count + 1
        say("🎓 Your turn: place SLOT \(slot)\(n > 1 ? " (copy #\(n))" : "") where you want it — press \(slot), click the spot.")
        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline {
            try Task.checkCancellation()
            if try await checkResults() { return nil }
            try await handleCards()                                   // cards are still mine
            for c in teachListener?.take(olderThan: 0.7) ?? [] {
                guard c.slot == slot else { say("🎓 That was slot \(c.slot) — I'm waiting for slot \(slot)"); continue }
                guard let img = try? await ScreenCapture.captureRoblox(), Self.unitPanelOpen(img) else {
                    say(String(format: "🎓 Click at (%.3f, %.3f) didn't place — try another spot", c.at.x, c.at.y)); continue
                }
                await input.click(Region.unitPanelClose)              // close the panel it opened
                saveTaught(slot: slot, at: c.at)
                say(String(format: "🎓 Learned slot %d at (%.3f, %.3f) ✓", slot, c.at.x, c.at.y))
                return c.at
            }
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        say("🎓 No placement for slot \(slot) in 3 min — placing it myself")
        return nil
    }

    // MARK: Match debug record (summary in the log + a placements picture in logs/)
    private var matchTries: [(slot: Int, at: NormPoint, ok: Bool)] = []
    private var matchPlanned: [Int: Int] = [:]
    private var matchPlaceTime: [Int: Double] = [:]
    private var matchStartImage: CGImage?

    /// Log lines + picture describing how placement went this match.
    private func writeMatchReport(won: Bool) {
        guard !matchTries.isEmpty || !matchPlanned.isEmpty else { return }
        let slots = Set(matchPlanned.keys).union(matchTries.map(\.slot)).sorted()
        var parts: [String] = []
        for sl in slots {
            let ok = autoPlaced.filter { $0.slot == sl }.count
            let miss = matchTries.filter { $0.slot == sl && !$0.ok }.count
            let t = Int(matchPlaceTime[sl] ?? 0)
            parts.append("slot \(sl) \(ok)/\(matchPlanned[sl] ?? ok)" + (miss > 0 ? " (\(miss) misses)" : "") + " \(t)s")
        }
        let hillSlots = Set(store?.settings.hillSlots ?? [])
        let hillPlanned = slots.contains { hillSlots.contains($0) }
        let hillPlaced = autoPlaced.contains { $0.slot != 0 && hillSlots.contains($0.slot) }
        let hillMisses = matchTries.filter { hillSlots.contains($0.slot) && !$0.ok }.count
        let mapNameNow = activeProfile?.name ?? store?.canonicalName(Self.mapName(fromTitle: currentTitle)) ?? ""
        if hillPlanned, !mapNameNow.isEmpty, var prof = store?.profiles.first(where: { $0.name == mapNameNow }) {
            if !hillPlaced && hillMisses >= 40 && prof.noHills != true {
                prof.noHills = true; store?.saveProfile(prof)
                say("\(mapNameNow): no hill spot found after \(hillMisses) tries — hill units will skip the search here next time")
            } else if hillPlaced && prof.noHills == true {
                prof.noHills = nil; store?.saveProfile(prof)
            }
        }
        let totalMiss = matchTries.filter { !$0.ok }.count
        let totalTime = Int(matchPlaceTime.values.reduce(0, +))
        say("Match summary (\(won ? "won" : "lost")): " + parts.joined(separator: " · ")
            + " — \(totalMiss) misses, \(totalTime / 60)m\(totalTime % 60)s spent placing")
        // Picture: the map at the start of the match, ● = placed (colour per slot), ✕ = missed.
        guard let base = matchStartImage else { return }
        let W = base.width, H = base.height
        guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.draw(base, in: CGRect(x: 0, y: 0, width: W, height: H))
        let colors: [Int: CGColor] = [1: CGColor(red: 1, green: 0.2, blue: 0.2, alpha: 1), 2: CGColor(red: 1, green: 0.6, blue: 0, alpha: 1),
                                      3: CGColor(red: 1, green: 1, blue: 0, alpha: 1), 4: CGColor(red: 0.2, green: 1, blue: 0.3, alpha: 1),
                                      5: CGColor(red: 0.2, green: 0.6, blue: 1, alpha: 1), 6: CGColor(red: 0.8, green: 0.3, blue: 1, alpha: 1)]
        for t in matchTries {
            let x = t.at.x * Double(W), y = Double(H) - t.at.y * Double(H)
            let c = colors[t.slot] ?? CGColor(gray: 1, alpha: 1)
            if t.ok {
                ctx.setFillColor(c); ctx.fillEllipse(in: CGRect(x: x - 14, y: y - 14, width: 28, height: 28))
                ctx.setStrokeColor(CGColor(gray: 0, alpha: 1)); ctx.setLineWidth(3)
                ctx.strokeEllipse(in: CGRect(x: x - 14, y: y - 14, width: 28, height: 28))
            } else {
                ctx.setStrokeColor(c); ctx.setLineWidth(5)
                ctx.move(to: CGPoint(x: x - 10, y: y - 10)); ctx.addLine(to: CGPoint(x: x + 10, y: y + 10))
                ctx.move(to: CGPoint(x: x - 10, y: y + 10)); ctx.addLine(to: CGPoint(x: x + 10, y: y - 10))
                ctx.strokePath()
            }
        }
        if let out = ctx.makeImage() {
            let name = "\(DebugLog.stamp())-placements-\(Self.mapName(fromTitle: currentTitle)).png"
            DebugLog.savePNG(out, name: name)
            say("Placement picture saved: logs/\(name)  (● placed, ✕ missed — slot colours: 1 red, 2 orange, 3 yellow, 4 green, 5 blue, 6 purple)")
        }
    }

    /// Remembers where the n-th copy of a slot actually went down (automatic layout learning).
    private func saveLearned(slot: Int, copy: Int, at p: NormPoint) {
        let name = activeProfile?.name ?? store?.canonicalName(Self.mapName(fromTitle: currentTitle)) ?? Self.mapName(fromTitle: currentTitle)
        guard !name.isEmpty else { return }
        var prof = store?.profiles.first(where: { $0.name == name }) ?? activeProfile
            ?? MapProfile(name: name, ground: [], hill: [], lane: enemyLane, scannedAt: Date())
        var mine = (prof.learned ?? []).filter { $0.slot == slot }
        let others = (prof.learned ?? []).filter { $0.slot != slot }
        if copy < mine.count { mine[copy] = TaughtSpot(slot: slot, at: p) } else { mine.append(TaughtSpot(slot: slot, at: p)) }
        prof.learned = others + mine
        store?.saveProfile(prof)
        if activeProfile == nil || activeProfile?.name == name { activeProfile = prof }
    }

    /// Adds a taught spot to the map's file right away (so nothing is lost if the match is cut short).
    private func saveTaught(slot: Int, at p: NormPoint) {
        let q = p            // taught spots are stored exactly where you clicked (never shifted)
        teachSpots.append(TaughtSpot(slot: slot, at: q))
        var prof = store?.profiles.first(where: { $0.name == teachName }) ?? activeProfile
            ?? MapProfile(name: teachName, ground: [], hill: [], lane: enemyLane, scannedAt: Date())
        prof.taught = (prof.taught ?? []).filter { old in !teachSpots.contains { $0.slot == old.slot } } + teachSpots
        let isHill = store?.settings.hillSlots.contains(slot) ?? false
        func near(_ l: [NormPoint]) -> Bool { l.contains { abs($0.x - q.x) < 0.012 && abs($0.y - q.y) < 0.015 } }
        if isHill {
            if !near(prof.hill) { prof.hill.append(q) }
            prof.badHill?.removeAll { abs($0.x - q.x) < 0.02 && abs($0.y - q.y) < 0.03 }
        } else {
            if !near(prof.ground) { prof.ground.append(q) }
            prof.badGround?.removeAll { abs($0.x - q.x) < 0.02 && abs($0.y - q.y) < 0.03 }
        }
        store?.saveProfile(prof)
        activeProfile = prof
    }

    /// Every ~3.5 % over the playable map (not the HUD) — the last resort for ground units.
    private func denseGrid() -> [NormPoint] {
        // The whole map, minus only the CLICKABLE interface (buttons, hotbar, title). It used to stop
        // at the level-info column and the top band — on Snowy Town the hills are up there, so two
        // full sweeps (~95 misses each) found nothing.
        let buttons: [CGRect] = [
            CGRect(x: 0.00, y: 0.00, width: 0.20, height: 0.16),   // Roblox / menu / chat buttons
            CGRect(x: 0.80, y: 0.00, width: 0.20, height: 0.16),   // P · i · FX · heart
            CGRect(x: 0.25, y: 0.00, width: 0.50, height: 0.17),   // stage title + boss bar
            CGRect(x: 0.93, y: 0.45, width: 0.07, height: 0.15),   // F (unit list) button
            CGRect(x: 0.29, y: 0.82, width: 0.44, height: 0.18),   // yen + hotbar
            CGRect(x: 0.00, y: 0.84, width: 0.18, height: 0.16),   // charm + settings gear
            CGRect(x: 0.84, y: 0.80, width: 0.16, height: 0.20),   // minimap corner
        ]
        var out: [NormPoint] = []
        for y in stride(from: 0.12, through: 0.86, by: 0.035) {
            for x in stride(from: 0.03, through: 0.96, by: 0.03) {
                let p = NormPoint(x: x, y: y)
                if !buttons.contains(where: { $0.contains(CGPoint(x: p.x, y: p.y)) }) { out.append(p) }
            }
        }
        return out
    }

    /// Where the route is: the saved scan's lane, else where enemies were seen this match,
    /// else the red lane from the overlay colours. Thinned out to keep the sort quick.
    private func laneReference(planner: AutoPlanner?) -> [NormPoint] {
        var pts: [NormPoint] = []
        if let prof = activeProfile, prof.lane.count >= 25 { pts = prof.lane.map(shifted) }
        else if enemyLane.count >= 25 { pts = enemyLane }
        else if let planner {
            let w = AutoPlanner.cols, h = AutoPlanner.rows
            pts = (0..<(w * h)).filter { planner.path[$0] }
                .map { NormPoint(x: (Double($0 % w) + 0.5) / Double(w), y: (Double($0 / w) + 0.5) / Double(h)) }
        }
        let step = max(1, pts.count / 300)
        return stride(from: 0, to: pts.count, by: step).map { pts[$0] }
    }

    /// Points on rings around the given spots (8 directions per ring) — e.g. around our own hill
    /// units, since hills usually fit several units.
    private func ringsAround(_ centers: [NormPoint], radii: [Double]) -> [NormPoint] {
        let aspect = Double(WindowManager.lockedSize.width / WindowManager.lockedSize.height)
        var out: [NormPoint] = []
        for r in radii { for c in centers { for k in 0..<8 {
            let a = Double(k) / 8 * 2 * .pi
            let p = NormPoint(x: c.x + cos(a) * r, y: c.y + sin(a) * r * aspect)
            if p.x > 0.02, p.x < 0.79, p.y > 0.22, p.y < 0.85,
               !AutoPlanner.hud.contains(where: { $0.contains(CGPoint(x: p.x, y: p.y)) }) { out.append(p) }
        }}}
        return out
    }

    /// Candidate spots when the overlay can't be read: rings around where enemies were seen
    /// (just off the lane), else a grid over the middle of the map, centre first.
    private func probeSpots(avoid: [NormPoint]) -> [NormPoint] {
        func ok(_ p: NormPoint) -> Bool {
            p.x > 0.04 && p.x < 0.78 && p.y > 0.24 && p.y < 0.82
                && !AutoPlanner.hud.contains(where: { $0.contains(CGPoint(x: p.x, y: p.y)) })
                && !avoid.contains(where: { abs($0.x - p.x) < 0.025 && abs($0.y - p.y) < 0.035 })
        }
        var spots: [NormPoint] = []
        if enemyLane.count >= 10 {
            // Every ~8th sighting, offset sideways by 4–6 % of the window in 8 directions.
            for (n, e) in enemyLane.enumerated() where n % 8 == 0 {
                for k in 0..<8 {
                    let a = Double(k) / 8 * 2 * .pi
                    let r = n % 16 == 0 ? 0.045 : 0.06
                    let p = NormPoint(x: e.x + cos(a) * r, y: e.y + sin(a) * r * 1.6)
                    if ok(p) && !spots.contains(where: { abs($0.x - p.x) < 0.03 && abs($0.y - p.y) < 0.04 }) { spots.append(p) }
                }
            }
            // Away from every sighting (not standing on the lane itself).
            spots = spots.filter { p in !enemyLane.contains { abs($0.x - p.x) < 0.02 && abs($0.y - p.y) < 0.03 } }
        }
        if spots.isEmpty {
            for y in stride(from: 0.30, through: 0.78, by: 0.07) {
                for x in stride(from: 0.10, through: 0.74, by: 0.06) {
                    let p = NormPoint(x: x, y: y); if ok(p) { spots.append(p) }
                }
            }
        }
        return spots.sorted { abs($0.x - 0.42) + abs($0.y - 0.52) < abs($1.x - 0.42) + abs($1.y - 0.52) }
    }

    /// Screenshot WITHOUT a unit, then WHILE holding it (slot key), then cancel with Q.
    /// Comparing the two isolates the green/red placement overlay from the map's own colors.
    /// Saves a picture of the plan to the logs folder.
    /// Opposite corners of the window over HUD (bottom-left charm, top-right buttons).
    // Parked over the MAP, not over buttons: with the cursor on a HUD button (top-right P/i/FX)
    // the game hides the placement overlay, and that shot made every hill interior look "not green"
    // (Sand Village: only the edges of the hill squares were found, so picks landed off the hill).
    static let parkA = NormPoint(x: 0.05, y: 0.80)
    static let parkB = NormPoint(x: 0.74, y: 0.30)
    /// The park corner farthest from a spot, so the parked range circle doesn't cover it.
    /// rank 0 = farthest corner from the spot, 1 = second farthest.
    static func park(awayFrom p: NormPoint, rank: Int = 0) -> NormPoint {
        let opts = [parkA, parkB, NormPoint(x: 0.05, y: 0.30), NormPoint(x: 0.74, y: 0.80)]
        let sorted = opts.sorted { a, b in
            (a.x - p.x) * (a.x - p.x) + (a.y - p.y) * (a.y - p.y) > (b.x - p.x) * (b.x - p.x) + (b.y - p.y) * (b.y - p.y)
        }
        return sorted[min(rank, sorted.count - 1)]
    }

    private func readOverlay(slot: Int) async -> AutoPlanner? {
        if let price = await cost(of: slot) {      // can't hold a unit you can't afford
            _ = try? await poll(timeout: 600, what: "\(price)¥ for slot \(slot)") { img -> Bool? in
                self.enoughYen(img, price)
            }
        }
        await WindowManager.focusRoblox()
        // The held unit's range circle is drawn wherever the cursor is, and its red tint hides the
        // green hills. So: hold the unit with the cursor in one corner, then the opposite corner,
        // and combine — each part of the map is circle-free in at least one of the two.
        input.move(Self.parkA)
        try? await Task.sleep(nanoseconds: lag(250_000_000))
        guard var base1 = try? await ScreenCapture.captureRoblox() else { return nil }
        // A unit panel left open by the last placement covers the left of the map: close it first.
        for _ in 0..<2 where Self.readAfterClick(base1).panel {
            await input.click(Region.unitPanelClose)
            try? await Task.sleep(nanoseconds: lag(350_000_000))
            input.move(Self.parkA)
            if let b = try? await ScreenCapture.captureRoblox() { base1 = b }
        }
        // A "Cannot place more…" message from the PREVIOUS unit stays on screen for a moment —
        // it once made slots 5 and 2 look full right after slot 4 hit its limit. Let it fade first.
        for _ in 0..<4 where Self.placementLimitMessage(base1) {
            try? await Task.sleep(nanoseconds: lag(900_000_000))
            if let b = try? await ScreenCapture.captureRoblox() { base1 = b }
        }
        let lingering = Self.placementLimitMessage(base1)
        await input.key(String(slot))
        try? await Task.sleep(nanoseconds: lag(450_000_000))           // overlay fades in
        let held1 = try? await ScreenCapture.captureRoblox()
        slotIsFull = false
        if let h = held1, !lingering, Self.placementLimitMessage(h),
           !(Self.readSlotCounter(h, slot: slot).map { $0.placed < $0.limit } ?? false) {
            slotIsFull = true
            await input.key("q")
            return nil
        }
        if let h = held1, let c = Self.readSlotCounter(h, slot: slot) {
            say("Slot \(slot): \(c.placed)/\(c.limit) placed")
            if c.placed >= c.limit {
                slotIsFull = true
                await input.key("q")
                return nil
            }
        }
        input.move(Self.parkB)
        try? await Task.sleep(nanoseconds: lag(350_000_000))
        let held2 = try? await ScreenCapture.captureRoblox()
        await input.key("q")
        try? await Task.sleep(nanoseconds: lag(400_000_000))           // overlay fades out
        let base2 = try? await ScreenCapture.captureRoblox()
        let helds = [held1, held2].compactMap { $0 }
        // Health bars (enemies and summons) are bright green: blank out the area around every
        // health label ("2.4/2.4") seen in any of the shots so they can't pass for a hill.
        var masks: [CGRect] = []
        for img in [base1] + helds {
            for l in (try? OCR.read(img, fast: true)) ?? [] {
                let t = l.text.replacingOccurrences(of: " ", with: "")
                guard t.range(of: #"\d+(\.\d+)?[KMB]?/\d+(\.\d+)?[KMB]?"#, options: [.regularExpression, .caseInsensitive]) != nil else { continue }
                masks.append(CGRect(x: l.box.minX - 0.035, y: l.box.minY - 0.03, width: l.box.width + 0.07, height: l.box.height + 0.07))
            }
        }
        guard let held = helds.first,
              let planner = AutoPlanner(bases: [base1] + [base2].compactMap { $0 }, helds: helds, enemyLane: enemyLane, masks: masks) else { return nil }

        let range = store?.settings.autoRangePerSlot[slot] ?? 0.12
        let hs = store?.settings.hillSlots ?? []
        let hill = hs.isEmpty ? planner.isHillOverlay : hs.contains(slot)
        let picks = planner.candidates(range: range, taken: [], covered: [:], hill: hill, maxLaneDistance: 7).map(\.spot)
        if let dbg = planner.debugImage(over: held, picks: picks) {
            DebugLog.savePNG(dbg, name: "\(DebugLog.stamp())-plan-slot\(slot).png")
        }
        return planner.pathCellCount > 20 ? planner : nil
    }

    // MARK: - Upgrades via the F "Unit Overview"

    /// Unit names under the hotbar, read once per stage (slot → name).
    private var slotNames: [Int: String] = [:]

    private func name(ofSlot slot: Int) async -> String? {
        if let n = slotNames[slot] { return n }
        guard let img = try? await ScreenCapture.captureRoblox(),
              let lines = try? OCR.read(img, region: Region.slotName(slot)) else { return nil }
        let n = lines.map(\.text).joined(separator: " ")
        guard OCR.norm(n).count >= 3 else { return nil }
        slotNames[slot] = n
        return n
    }

    /// Opens F → Unit Overview, finds this slot's unit by name, waits for the money and clicks
    /// its "Upg: ####¥" button. Picks the cheapest copy if you have several of the same unit.
    /// Returns true = upgraded, false = maxed / nothing to upgrade, nil = couldn't find it.
    private func upgradeViaOverview(slot: Int) async -> Bool? {
        guard let unitName = await name(ofSlot: slot) else { return nil }
        let key = String(OCR.norm(unitName).prefix(6))          // OCR mangles the end of long names
        await WindowManager.focusRoblox()

        func readPanel() async -> [OCR.Line]? {
            guard let img = try? await ScreenCapture.captureRoblox(),
                  let lines = try? OCR.read(img, region: Region.unitOverview),
                  lines.contains(where: { OCR.norm($0.text).contains("unitoverview") }) else { return nil }
            return lines
        }
        var lines = await readPanel()
        if lines == nil {
            await input.key("f")
            try? await Task.sleep(nanoseconds: lag(700_000_000))
            lines = await readPanel()
        }
        guard let panel = lines else { say("⚠️ Unit Overview (F) didn't open"); return nil }
        let result = await clickUpgrade(in: panel, nameKey: key, unitName: unitName)
        await input.key("f")                                    // close it again
        try? await Task.sleep(nanoseconds: lag(300_000_000))
        return result
    }

    private func clickUpgrade(in panel: [OCR.Line], nameKey key: String, unitName: String) async -> Bool? {
        // Each entry: a name label, with its "Upg: 2200¥" button up and to the right.
        let names = panel.filter { OCR.norm($0.text).hasPrefix(key) }
        let buttons = panel.filter { OCR.norm($0.text).hasPrefix("upg") || OCR.norm($0.text) == "max" }
        var best: (line: OCR.Line, cost: Int?)?
        for n in names {
            guard let b = buttons
                .filter({ $0.box.midX > n.box.midX && $0.box.midX - n.box.midX < 0.16 && abs($0.box.midY - n.box.midY) < 0.1 })
                .min(by: { abs($0.box.midY - n.box.midY) < abs($1.box.midY - n.box.midY) }) else { continue }
            if OCR.norm(b.text).contains("max") { continue }
            let cost = Int(b.text.filter(\.isNumber))
            if best == nil || (cost ?? .max) < (best!.cost ?? .max) { best = (b, cost) }
        }
        guard let target = best else {
            return names.isEmpty ? nil : false                  // found the unit but every copy is maxed
        }
        if let cost = target.cost {
            _ = try? await poll(timeout: 600, what: "\(cost)¥ for upgrade") { img -> Bool? in
                self.enoughYen(img, cost)
            }
        }
        let before = try? await yen()
        await input.click(target.line.center)
        try? await Task.sleep(nanoseconds: lag(500_000_000))
        if let b = before, let a = try? await yen(), a < b {
            say("Upgraded \(unitName) via overview (−\(b - a)¥)")
            return true
        }
        return nil
    }

    /// Upgrade one placed unit: the F overview first (no clicking on the map), clicking the
    /// unit as a fallback (also used when you set a max level, since only the unit panel shows it).
    private func upgradeUnit(slot: Int, at p: NormPoint, times: Int = 1) async -> Bool? {
        // We know exactly where it was placed: click it once, keep the panel open, press R.
        let maxLevel = store?.settings.maxLevelPerSlot[slot]
        if let r = await upgrade(at: p, times: times, maxLevel: maxLevel) { return r }
        // Panel wouldn't open (unit hidden behind effects/enemies) → use the F list instead.
        return await upgradeViaOverview(slot: slot)
    }

    enum PlaceResult { case placed, failed, cantAfford, limitReached }

    /// How many of this slot are on the map right now (press the slot key, read "2/3", cancel).
    /// full = the game refused to let us hold it (limit message) or the counter is at the limit.
    private func placedCount(slot: Int) async -> (placed: Int, full: Bool)? {
        await WindowManager.focusRoblox()
        input.move(NormPoint(x: 0.5, y: 0.95))
        await input.key(String(slot))
        try? await Task.sleep(nanoseconds: lag(600_000_000))
        let img = try? await ScreenCapture.captureRoblox()
        await input.key("q")
        try? await Task.sleep(nanoseconds: lag(200_000_000))
        guard let img else { return nil }
        if Self.placementLimitMessage(img) { return (99, true) }
        if let c = Self.readSlotCounter(img, slot: slot) { return (c.placed, c.placed >= c.limit) }
        return nil
    }

    /// The game's "you can't place more of this" messages — the unit is full, not the spot bad.
    static func placementLimitMessage(_ img: CGImage) -> Bool {
        guard let lines = try? OCR.read(img, region: CGRect(x: 0.05, y: 0.40, width: 0.85, height: 0.45), fast: true) else { return false }
        return lines.contains { l in
            let t = OCR.norm(l.text)
            return t.contains("cannotplacemore") || t.contains("placemorethan") || t.contains("uniqueunits")
                || t.contains("maynotbeplaced") || t.contains("othersofitskind")
        }
    }

    enum CircleVerdict { case valid, invalid, unsure }

    /// Samples a ring of points around the cursor (inside the unit's range circle, away from the
    /// unit model itself) and measures how the colour shifted when the circle appeared there.
    /// Blue shift = valid spot, red shift = invalid.
    static func rangeCircleVerdict(parked: CGImage, hovering: CGImage, at p: NormPoint, strict: Bool = false) -> CircleVerdict {
        let aspect = Double(WindowManager.lockedSize.width / WindowManager.lockedSize.height)
        var dr = 0.0, db = 0.0, n = 0.0
        for radius in [0.05, 0.075, 0.10, 0.13] {
            for k in 0..<16 {
                let a = Double(k) / 16 * 2 * .pi
                let dx = cos(a) * radius
                if dx > 0.02 { continue }                        // the Place/Rotate/Cancel menu sits to the right
                let q = NormPoint(x: p.x + dx, y: p.y + sin(a) * radius * aspect)
                guard q.x > 0.01, q.x < 0.99, q.y > 0.21, q.y < 0.86,
                      !AutoPlanner.hud.contains(where: { $0.contains(CGPoint(x: q.x, y: q.y)) }),
                      let c0 = Matcher.averageColor(in: parked, at: q, radius: 6),
                      let c1 = Matcher.averageColor(in: hovering, at: q, radius: 6) else { continue }
                dr += c1.r - c0.r; db += c1.b - c0.b; n += 1
            }
        }
        guard n >= 8 else { return .unsure }
        dr /= n; db /= n
        if dr - db > 0.01 && dr > 0.006 { return .invalid }
        // Scanning demands a clear blue shift; live placement accepts a weaker one.
        if strict ? (db - dr > 0.025 && db > 0.012) : (db - dr > 0.01 && db > 0.003) { return .valid }
        return .unsure
    }

    /// Set by readOverlay when the slot's counter shows it's at its limit (e.g. "4/4").
    private var slotIsFull = false
    /// Slots whose "placed" unit turned out not to exist — placed again right away.
    private var phantomSlots: [Int] = []

    /// Reads "placed/limit" above a slot (only shown while holding that unit).
    /// Each slot's placement limit as first read this session ("0/4" → 4). A later reading with a
    /// different limit ("10/10" for a 4-limit unit) is a misread and is ignored.
    static var knownLimits: [Int: Int] = [:]

    static var limitVotes: [Int: [Int: Int]] = [:]

    static func readSlotCounter(_ img: CGImage, slot: Int) -> (placed: Int, limit: Int)? {
        guard let c = readSlotCounterRaw(img, slot: slot) else { return nil }
        if let known = knownLimits[slot] {
            return c.limit == known ? c : nil
        }
        // Not locked yet: count readings; lock once the same limit has been read twice.
        limitVotes[slot, default: [:]][c.limit, default: 0] += 1
        if (limitVotes[slot]?[c.limit] ?? 0) >= 2 { knownLimits[slot] = c.limit }
        return c
    }

    static func readSlotCounterRaw(_ img: CGImage, slot: Int) -> (placed: Int, limit: Int)? {
        guard let lines = try? OCR.read(img, region: Region.slotCounter(slot)) else { return nil }
        for l in lines {
            let t = l.text.replacingOccurrences(of: " ", with: "")
            if let r = t.range(of: #"(\d+)/(\d+)"#, options: .regularExpression) {
                let parts = t[r].split(separator: "/").compactMap { Int($0) }
                // "21/1" style misreads: placed can't exceed the limit, limits are small.
                if parts.count == 2, parts[1] > 0, parts[1] <= 10, parts[0] <= parts[1] { return (parts[0], parts[1]) }
            }
        }
        return nil
    }

    /// One verified placement attempt: hold the unit, hover the spot, click, then confirm
    /// the yen dropped by about the unit's cost. On failure, cancel with Q.
    /// Spots found blocked this match (red overlay / red circle) — usually our own units. Not tried
    /// again this match. Separate lists for ground and hill units.
    private var blockedGround: [NormPoint] = []
    private var blockedHill: [NormPoint] = []
    private var lastFailWasBlock = false

    /// True when the last .failed came from a real click that placed nothing (the spot itself is bad),
    /// not from a skip (red overlay / red circle) that might be a temporary blocker.
    private var lastFailWasClick = false
    /// The last .failed was a RED range circle on hover (spot not placeable for this unit).
    private var lastFailWasCircle = false
    /// Set when the match start already did teleport-to-spawn + camera, so it isn't done twice.
    private var didSpawnReset = false

    /// ONE placement attempt, verified by the game itself. Every step re-checks the screen so
    /// nothing is assumed:
    ///   1. Clean start — close a unit panel left open by the last placement/upgrade (otherwise
    ///      it looks like "the panel opened" = a fake success) and wait out leftover messages.
    ///   2. Hold the unit → read the slot counter ("1/3") and any limit / money message.
    ///   3. Hover the spot, click ONCE (no double clicks: a second click after a click that did
    ///      land placed a second unit).
    ///   4. Verify: press the slot key again and read the counter. Counter went up = placed.
    ///      Only if the counter can't be read: a panel that is NEW since step 1, or a limit message
    ///      that is NEW, counts. The game's "can't place" message = failed.
    /// `trusted` / `forceTry` are kept for callers; the circle colour no longer blocks a click.
    private func placeOnce(slot: Int, at target: NormPoint, requireBlue: Bool = false, trusted: Bool = false,
                           forceTry: Bool = false) async -> PlaceResult {
        lastFailWasClick = false
        lastFailWasBlock = false
        lastFailWasCircle = false
        if Task.isCancelled { return .failed }
        let interruptsAtStart = cardInterrupts
        func interrupted() -> Bool { cardInterrupts != interruptsAtStart }

        await WindowManager.focusRoblox()

        // 1) Clean start.
        input.move(Self.park(awayFrom: target))
        try? await Task.sleep(nanoseconds: lag(200_000_000))
        guard var base = try? await ScreenCapture.captureRoblox() else { return .failed }
        for _ in 0..<2 where Self.readAfterClick(base).panel {
            await input.click(Region.unitPanelClose)                       // red X of the unit panel
            try? await Task.sleep(nanoseconds: lag(350_000_000))
            input.move(Self.park(awayFrom: target))
            if let b = try? await ScreenCapture.captureRoblox() { base = b }
        }
        for _ in 0..<4 where Self.placementLimitMessage(base) || Self.placeFailedMessage(base) {
            try? await Task.sleep(nanoseconds: lag(800_000_000))           // old message still fading
            if let b = try? await ScreenCapture.captureRoblox() { base = b }
        }
        let before = Self.readAfterClick(base)                             // what was on screen already

        // 2) Hold the unit.
        await input.key(String(slot))
        try? await Task.sleep(nanoseconds: lag(400_000_000))
        guard let held = try? await ScreenCapture.captureRoblox() else { await input.key("q"); return .failed }
        let counterBefore = Self.readSlotCounter(held, slot: slot)
        if let c = counterBefore, c.placed >= c.limit { await input.key("q"); return .limitReached }
        let heldRead = Self.readAfterClick(held)
        if heldRead.limit && !before.limit && counterBefore == nil { await input.key("q"); return .limitReached }
        if heldRead.noYen && !before.noYen { await input.key("q"); return .cantAfford }
        if interrupted() { await input.key("q"); return .failed }

        // 3) Hover, then one click.
        input.move(target)
        try? await Task.sleep(nanoseconds: lag(300_000_000))
        if cardsPending != nil || interrupted() {
            await input.key("q")
            cardInterrupts += 1                                            // not the spot's fault
            await yieldToCards()
            return .failed
        }
        await input.click(target)
        try? await Task.sleep(nanoseconds: lag(650_000_000))
        let after = (try? await ScreenCapture.captureRoblox()).map(Self.readAfterClick) ?? AfterClick()
        if interrupted() { await input.key("q"); return .failed }
        if after.failed && !before.failed {
            say(String(format: "Slot %d: game says it can't go at (%.3f, %.3f) — remembering it", slot, target.x, target.y))
            await input.key("q"); try? await Task.sleep(nanoseconds: lag(200_000_000))
            lastFailWasClick = true
            return .failed
        }
        if after.noYen && !before.noYen {
            say("Slot \(slot): game says not enough yen")
            await input.key("q"); try? await Task.sleep(nanoseconds: lag(200_000_000))
            return .cantAfford
        }

        // 4) Verify with the counter (definitive when readable).
        await input.key("q")                                                // drop the unit if still held
        try? await Task.sleep(nanoseconds: lag(250_000_000))
        await input.key(String(slot))
        try? await Task.sleep(nanoseconds: lag(400_000_000))
        let check = try? await ScreenCapture.captureRoblox()
        await input.key("q")
        try? await Task.sleep(nanoseconds: lag(200_000_000))
        let counterAfter = check.flatMap { Self.readSlotCounter($0, slot: slot) }
        let checkLimit = check.map(Self.placementLimitMessage) ?? false

        if let b = counterBefore, let a = counterAfter {
            if a.placed > b.placed {
                say("Placed slot \(slot) ✓ (\(b.placed)/\(b.limit) → \(a.placed)/\(a.limit))")
                return .placed
            }
            say(String(format: "Slot %d: (%.3f, %.3f) didn't place (counter still %d/%d) — remembering it", slot, target.x, target.y, a.placed, a.limit))
            lastFailWasClick = true
            return .failed
        }
        // Counter unreadable on one side: fall back to signs that are NEW since the clean start.
        if checkLimit && !before.limit && (counterBefore.map { $0.placed < $0.limit } ?? true) {
            say("Placed slot \(slot) ✓ (slot is now at its limit)")
            return .placed
        }
        if let a = counterAfter, a.placed >= a.limit, counterBefore.map({ $0.placed < $0.limit }) ?? true {
            say("Placed slot \(slot) ✓ (\(a.placed)/\(a.limit))")
            return .placed
        }
        if after.panel && !before.panel {
            say("Placed slot \(slot) ✓ (unit panel opened)")
            return .placed
        }
        if after.limit && !before.limit {
            say("Placed slot \(slot) ✓ (game now says it's at its limit)")
            return .placed
        }
        say(String(format: "Slot %d: (%.3f, %.3f) didn't place — remembering it", slot, target.x, target.y))
        lastFailWasClick = true
        return .failed
    }

    /// "Not enough yen" type messages.
    /// The game's message when a spot is invalid ("Cannot place here", "Invalid placement",
    /// "Too close to…", "Must be placed on…"). Wording guessed broadly; the limit / yen messages
    /// are checked separately first.
    static func placeFailedMessage(_ img: CGImage) -> Bool {
        guard let lines = try? OCR.read(img, region: CGRect(x: 0.05, y: 0.40, width: 0.85, height: 0.45), fast: true) else { return false }
        return lines.contains { l in
            let t = OCR.norm(l.text)
            guard !t.contains("cannotplacemore"), !t.contains("placemorethan") else { return false }
            return t.contains("cannotplace") || t.contains("cantplace") || t.contains("invalidplacement")
                || t.contains("invalidposition") || t.contains("toocloseto") || t.contains("mustbeplaced")
                || t.contains("cannotbeplaced") || t.contains("unabletoplace") || t.contains("placementinvalid")
        }
    }

    static func notEnoughYenMessage(_ img: CGImage) -> Bool {
        guard let lines = try? OCR.read(img, region: CGRect(x: 0.05, y: 0.40, width: 0.85, height: 0.45), fast: true) else { return false }
        return lines.contains { l in
            let t = OCR.norm(l.text)
            return t.contains("notenough") || t.contains("cannotafford") || t.contains("insufficient") || t.contains("needmore")
        }
    }

    // MARK: - Map recognition

    /// 0) Read the stage title ("Magic Town  Summer Hunt") and match a recording's name/keywords.
    /// 1) Compare the minimap's path shape with each recording's saved minimap.
    /// 2) Fall back to the map name read off the lobby board.
    private func identifyMap() async throws -> MapRecording {
        let maps = store?.maps.filter { !$0.name.hasPrefix("_") } ?? []
        let img = try await ScreenCapture.captureRoblox()
        // 0) The stage title ("Magic Town  Summer Hunt") names the map directly.
        currentTitle = (try? OCR.read(img, region: Region.stageTitle).map(\.text).joined(separator: " ")) ?? ""
        let title = OCR.norm(currentTitle)
        let titleHits = maps.compactMap { m -> (MapRecording, Int)? in
            let best = ([m.name] + m.keywords).map(OCR.norm).filter { !$0.isEmpty && title.contains($0) }.map(\.count).max()
            return best.map { (m, $0) }
        }
        if let hit = titleHits.max(by: { $0.1 < $1.1 })?.0 {
            say("Map from title: \(hit.name)")
            return hit
        }
        if let mini = img.cropped(to: Region.minimap) {
            let scored = maps.compactMap { m -> (MapRecording, Double)? in
                guard let f = m.referenceImage, let ref = store?.reference(f) else { return nil }
                return (m, Matcher.similarity(mini, ref))
            }.sorted { $0.1 < $1.1 }
            if let best = scored.first {
                say(String(format: "Minimap: closest is %@ (%.3f)", best.0.name, best.1))
                if best.1 < 0.12 { return best.0 }      // TODO: tune once a few maps are recorded
            }
        }
        if let hit = maps.first(where: { m in m.keywords.contains { !$0.isEmpty && boardHint.contains(OCR.norm($0)) } }) {
            return hit
        }
        throw MacroError.unknownMap(boardHint)
    }

    // MARK: - Placement & upgrades

    /// Reads the "1200 ¥" under a hotbar slot (cached for the stage).
    private func cost(of slot: Int) async -> Int? {
        if let typed = store?.settings.unitCost[slot], typed > 0 { return typed }   // your number wins
        if let c = slotCosts[slot] { return c }
        guard let img = try? await ScreenCapture.captureRoblox(),
              let raw = Int((try? OCR.digits(img, region: Region.slotCost(slot))) ?? "") else { return nil }
        // Unit costs are round numbers (800, 1150, 2000…). If the "¥" got read as a digit
        // ("12004"), drop it. Anything still implausible is ignored rather than trusted.
        var c = raw
        if c % 10 != 0, (c / 10) % 50 == 0 { c /= 10 }
        // One digit misread ("1290" for 1200): use the nearest round hundred if it's close.
        if c % 50 != 0, (100...20000).contains(c) {
            let r = Int((Double(c) / 100).rounded(.down)) * 100
            if c - r <= 100 { c = r }
        }
        guard (100...20000).contains(c), c % 50 == 0 else {
            say("⚠️ Couldn't read slot \(slot)'s cost (read \(raw)) — not waiting on it")
            return nil
        }
        slotCosts[slot] = c
        return c
    }

    /// Waits until we can afford the unit, presses its slot key, clicks the spot,
    /// and confirms the yen dropped by its cost. Retries at small offsets
    /// (hill-only units can be picky about the exact pixel).
    private func placeVerified(slot: Int, at p: NormPoint) async throws -> NormPoint {
        let price = await cost(of: slot)
        if let price {
            say("Slot \(slot) costs \(price)¥ — waiting for money")
            _ = try await poll(timeout: 600, what: "\(price)¥ for slot \(slot)") { img -> Bool? in
                self.enoughYen(img, price)
            }
        }
        let offsets: [(Double, Double)] = [(0, 0), (0.01, 0), (-0.01, 0), (0, 0.01), (0, -0.01), (0.015, 0.015)]
        for (dx, dy) in offsets {
            let target = NormPoint(x: p.x + dx, y: p.y + dy)
            let before = try? await yen()
            await input.key(String(slot))
            try await Task.sleep(nanoseconds: lag(150_000_000))
            await input.click(target)
            try await Task.sleep(nanoseconds: lag(400_000_000))
            if try await placementSucceeded(yenBefore: before, price: price) {
                say("Placed slot \(slot)")
                return target
            }
            await input.key("q")            // Q = Cancel placement (per the in-game menu)
            try await Task.sleep(nanoseconds: lag(500_000_000))
        }
        throw MacroError.placementFailed(slot)
    }

    /// Success = yen dropped by (roughly) the unit's cost. Income can tick up in between,
    /// so 80% of the price counts.
    private func placementSucceeded(yenBefore: Int?, price: Int?) async throws -> Bool {
        guard let before = yenBefore, let after = try? await yen() else {
            say("⚠️ Couldn't read yen to confirm the placement")
            return false
        }
        if let price { return before - after >= Int(Double(price) * 0.8) }
        return after < before
    }

    /// Click the placed unit → the panel opens bottom-left showing "UPG [4]" and
    /// "Upgrade: 7000¥ [R]". Wait until affordable, press R, confirm the level went up.
    /// Returns true = can upgrade further, false = maxed, nil = couldn't open the unit panel.
    @discardableResult
    private func upgrade(at p: NormPoint, times: Int, maxLevel: Int?) async -> Bool? {
        let key = store?.settings.upgradeKey ?? "r"

        /// Reads (level, cost, isMax) from the open panel, or nil if the panel isn't open.
        func panel() async -> (level: Int, cost: Int?, isMax: Bool)? {
            guard let img = try? await ScreenCapture.captureRoblox(),
                  let lines = try? OCR.read(img, region: Region.unitPanel) else { return nil }
            let up = lines.first { OCR.norm($0.text).hasPrefix("upgrade") }
            let lvl = lines.first { OCR.norm($0.text).hasPrefix("upg") && !OCR.norm($0.text).hasPrefix("upgrade") }
            guard up != nil || lvl != nil else { return nil }
            let level = lvl.flatMap { Int($0.text.filter(\.isNumber)) } ?? 0
            // Maxed only when the upgrade button itself says MAX (not "max" anywhere on the panel).
            let isMax = lines.contains { l in
                let t = OCR.norm(l.text)
                return t == "max" || t == "maxed" || (t.hasPrefix("upgrade") && t.contains("max"))
            }
            return (level, up.flatMap { Int($0.text.filter(\.isNumber)) }, isMax)
        }

        // Select the unit (retry at small offsets in case an enemy was in the way).
        var info: (level: Int, cost: Int?, isMax: Bool)?
        for (dx, dy) in [(0.0, 0.0), (0.0, -0.01), (0.008, 0.0), (-0.008, 0.0)] {
            await input.click(NormPoint(x: p.x + dx, y: p.y + dy))
            try? await Task.sleep(nanoseconds: lag(400_000_000))
            if let i = await panel() { info = i; break }
        }
        guard var current = info else { say("⚠️ Couldn't open unit panel for upgrade"); return nil }
        var canContinue = true
        var stalls = 0

        for _ in 0..<times {
            if Task.isCancelled { break }
            if let d = upgradeDeadline, Date() > d { break }
            // Cards can pop up mid-upgrade: vote first, then reopen the unit's panel.
            if let img = try? await ScreenCapture.captureRoblox(), Self.cardScreenVote(img) != nil {
                cardVotedAt = .distantPast
                try? await handleCards(img)
                await input.click(p)
                try? await Task.sleep(nanoseconds: lag(400_000_000))
            }
            if current.isMax { say("Unit is maxed"); canContinue = false; break }
            if let maxLevel, current.level >= maxLevel {
                say("Reached the Max level \(maxLevel) set on this unit's card (set it to ∞ to keep upgrading)")
                canContinue = false; break
            }
            if let cost = current.cost {
                do {
                    let limit = upgradeDeadline.map { max(3, $0.timeIntervalSinceNow) } ?? 600
                    _ = try await poll(timeout: min(600, limit), what: "\(cost)¥ for upgrade") { img -> Bool? in
                        self.enoughYen(img, cost)
                    }
                } catch {
                    if (try? await checkResults()) == true { return nil }     // match over — stop upgrading
                }
            }
            await input.key(key)
            try? await Task.sleep(nanoseconds: lag(500_000_000))
            guard let after = await panel() else { break }
            if after.level > current.level || after.cost != current.cost {
                say("Upgraded to UPG \(after.level)")
                stalls = 0
            } else {
                // No change: almost always not enough yen yet (the counter may be unreadable).
                stalls += 1
                if stalls >= 6 {
                    say("⚠️ Pressing \(key.uppercased()) isn't upgrading this unit — moving on for now")
                    await input.click(Region.unitPanelClose)
                    return nil
                }
                try? await sleepWatchingCards(Double(min(20, 4 * stalls)))   // 4, 8, 12… s, picking cards meanwhile
            }
            current = after
        }
        await input.click(Region.unitPanelClose)                    // close the panel (red X)
        if current.isMax { canContinue = false }
        return canContinue
    }

    private func yen() async throws -> Int? {
        Self.readYen(try await ScreenCapture.captureRoblox())
    }

    private var yenUnreadableSince: Date?
    /// For money waits: true once we can afford it. If the counter can't be read for 15 s,
    /// stop waiting and just try (the placement/upgrade check will catch it if we were short).
    private func enoughYen(_ img: CGImage, _ price: Int) -> Bool? {
        if let y = Self.readYen(img) {
            yenUnreadableSince = nil
            return y >= price ? true : nil
        }
        if yenUnreadableSince == nil { yenUnreadableSince = Date() }
        if Date().timeIntervalSince(yenUnreadableSince!) > 15 {
            yenUnreadableSince = nil
            say("Can't read the yen counter — trying anyway")
            return true
        }
        return nil
    }

    /// Bottom-most line in the yen area that isn't an income pop-up ("+85").
    static func readYen(_ img: CGImage) -> Int? {
        guard let lines = try? OCR.read(img, region: Region.yenCounter) else { return nil }
        // Only lines that are basically a number ("21664¥"), not "+85" pop-ups and not banners
        // like "Wave Completed!" that slide over the counter.
        let numeric = lines.filter { l in
            let t = l.text.trimmingCharacters(in: .whitespaces)
            let digits = t.filter(\.isNumber).count
            let letters = t.filter(\.isLetter).count
            return !t.hasPrefix("+") && digits >= 1 && letters <= 1
        }
        // The yen counter is the BIGGEST number there (enemy labels drifting over it are tiny).
        return numeric.max { $0.box.height < $1.box.height }.flatMap { Int($0.text.filter(\.isNumber)) }
    }

    private func checkResults() async throws -> Bool {
        guard let img = try? await ScreenCapture.captureRoblox() else { return false }
        return endScreen(in: img) != nil
    }

    /// What the end-of-match flow is showing right now. The flow is:
    ///   VICTORY!!! / DEFEAT panel → "Next" → (item drop screens) → "Return to lobby" | "Replay"
    enum EndScreen { case result(next: NormPoint?), drops, lobbyButton(NormPoint) }

    private static let winWords  = ["victory", "youwon", "cleared", "stagecleared"]
    static func looksLikeNext(_ t: String) -> Bool {
        let n = OCR.norm(t)
        return n == "next" || n == "next" || n == "nex" || n == "next>" || (n.count <= 5 && n.hasPrefix("nex"))
    }
    private static let lossWords = ["defeat", "youlost", "gameover", "failed", "youdied"]

    /// The in-match Settings menu also has a "Return to Lobby" button (next to "Teleport back to
    /// Spawn" and "Exit the game and return back to the lobby"). That is NOT the results screen —
    /// clicking it once made the macro walk out of a match 20 s in.
    static func isSettingsMenu(_ t: [String]) -> Bool {
        t.contains { $0.contains("teleportbacktospawn") || $0.contains("exitthegame") || $0.contains("autoskip")
                     || $0.contains("useifstuck") || $0.contains("disableautoopen") }
    }

    private func endScreen(in img: CGImage) -> EndScreen? {
        guard let lines = try? OCR.read(img, fast: true) else { return nil }
        let t = lines.map { OCR.norm($0.text) }
        if Self.isSettingsMenu(t) { return nil }
        // "Return to lobby" (top centre, next to Replay) — the last step.
        if let back = lines.first(where: { OCR.norm($0.text).contains("returntolobby") }) {
            return .lobbyButton(back.center)
        }
        // The VICTORY!!! / DEFEAT panel, with its "Next" button.
        let isWin = t.contains { w in Self.winWords.contains { w.contains($0) } }
        // The stylised DEFEAT/VICTORY art is often unreadable; the panel's own lines aren't.
        let panelLines = t.filter { $0.contains("wavescompleted") || $0.contains("totaltime") || $0.contains("xpprogress") }.count
        var isWinCareful = false
        if !isWin, panelLines >= 2, !t.contains(where: { w in Self.lossWords.contains { w.contains($0) } }) {
            // The quick read missed the big stylised word: read that spot carefully, and check its
            // colour (VICTORY is gold, DEFEAT is red). A win was once logged as a loss here.
            let area = CGRect(x: 0.25, y: 0.26, width: 0.32, height: 0.11)
            let careful = ((try? OCR.read(img, region: area)) ?? []).map { OCR.norm($0.text) }
            if careful.contains(where: { w in Self.winWords.contains { w.contains($0) } }) { isWinCareful = true }
            else if !careful.contains(where: { w in Self.lossWords.contains { w.contains($0) } }),
                    let c = Matcher.averageColor(in: img, rect: CGRect(x: 0.34, y: 0.29, width: 0.13, height: 0.045)),
                    c.g > 0.45, c.r > 0.55, c.g > c.r * 0.6, c.b < c.g * 0.8 { isWinCareful = true }   // gold
        }
        if isWinCareful { lastResultWasVictory = true }
        let isLoss = !isWinCareful && (t.contains { w in Self.lossWords.contains { w.contains($0) } } || (!isWin && panelLines >= 2))
        if isWin || isWinCareful || isLoss {
            if isWin { lastResultWasVictory = true }
            sawResultPanel = true
            // "Next" is stylised — the quick reader often misses it. Read the panel accurately…
            var next = lines.first { Self.looksLikeNext($0.text) }?.center
            if next == nil, let acc = try? OCR.read(img, region: CGRect(x: 0.1, y: 0.25, width: 0.6, height: 0.6)) {
                next = acc.first { Self.looksLikeNext($0.text) }?.center
                // …and if it's still not readable, it sits below "Waves Completed" on the panel.
                if next == nil, let waves = acc.first(where: { OCR.norm($0.text).contains("wavescompleted") || OCR.norm($0.text).contains("totaltime") }) {
                    let offset = OCR.norm(waves.text).contains("totaltime") ? 0.215 : 0.165
                    next = NormPoint(x: waves.box.midX, y: min(0.85, waves.box.midY + offset))
                }
            }
            return .result(next: next)
        }
        // After the panel: item drop / reward screens until Return to lobby shows up.
        // Some of them have their own "Next" button.
        if sawResultPanel {
            if let next = lines.first(where: { Self.looksLikeNext($0.text) }) { return .result(next: next.center) }
            return .drops
        }
        return nil
    }

    // MARK: - Cards

    /// If "The weather shifts…" vote is up, read the 3 cards, click the best one, press Vote.
    /// Called before every action, during waits, and on every polled frame — so cards are
    /// handled whenever they appear, never replayed from a recording.
    private func handleCards(_ frame: CGImage? = nil) async throws {
        try checkWatchdog()
        if !handlingCards, cardsPending != nil { await yieldToCards(); return }
        if inStage, Date().timeIntervalSince(lastPopupCheck) > 6 { await clearPopups(frame) }
        guard inStage, Date().timeIntervalSince(cardVotedAt) > 15 else { return }
        var captured = frame
        if captured == nil { captured = try? await ScreenCapture.captureRoblox() }
        guard let img = captured, let voteButton = Self.cardScreenVote(img) else { return }

        // Read the cards from the wide area between the header and the Vote bar.
        // x stops at 0.785: the Level Modifiers panel starts just right of the third card.
        let lines = try OCR.read(img, region: CGRect(x: 0.18, y: 0.28, width: 0.605, height: 0.48))
        let cards = CardPicker.read(lines, image: img)
        guard cards.count >= 2, let pick = CardPicker.choose(cards, settings: store?.settings ?? MacroSettings()) else {
            say("Card screen up but couldn't read the cards — saving a screenshot")
            await DebugLog.snapshot("cards-unreadable")
            cardVotedAt = Date().addingTimeInterval(-10)        // look again in ~5 s
            return
        }
        let desc = cards.map { "[\($0.isBuff ? "+" : "-") \($0.title)\($0.redLines.isEmpty ? "" : " red: " + $0.redLines.joined(separator: ", "))]" }
            .joined(separator: " ")
        say("Cards: \(desc) → \(pick.title)")
        await input.click(pick.center)
        try await Task.sleep(nanoseconds: lag(300_000_000))
        await input.click(voteButton)
        cardVotedAt = Date()
    }

    /// The number on the line that says "Wave …" (ignores the "+47" pearls line under it).
    static func readWave(_ img: CGImage) -> Int? {
        guard let lines = try? OCR.read(img, region: Region.waveCounter, fast: true),
              let w = lines.first(where: { OCR.norm($0.text).hasPrefix("wave") }) else { return nil }
        return Int(w.text.filter(\.isNumber))
    }

    /// The card screen is up only when BOTH its header text and a "Vote" button are visible.
    /// Returns where the Vote button is. (One alone gave false alarms on banners and names.)
    static func cardScreenVote(_ img: CGImage) -> NormPoint? {
        guard let lines = try? OCR.read(img, region: CGRect(x: 0.15, y: 0.15, width: 0.70, height: 0.75), fast: true) else { return nil }
        let t = lines.map { OCR.norm($0.text) }
        let header = t.contains { $0.contains("weathershifts") || $0.contains("voteends") || $0.contains("shifts") }
        let vote = lines.first { OCR.norm($0.text) == "vote" }
        let cancel = lines.first { OCR.norm($0.text) == "cancel" }
        // The card screen is the only screen with a "Vote" button next to "Cancel"
        // (the header wording changes with the weather, so it's optional).
        if let vote, cancel != nil || header {
            if let cancel, abs(cancel.box.midY - vote.box.midY) > 0.06 && !header { return nil }   // must sit side by side
            return vote.center
        }
        // Header seen but the stylised "Vote" missed by the quick reader: read that area properly.
        if header, let acc = try? OCR.read(img, region: CGRect(x: 0.25, y: 0.70, width: 0.50, height: 0.20)),
           let v = acc.first(where: { OCR.norm($0.text) == "vote" }) {
            return v.center
        }
        return nil
    }

    /// A long wait, chopped into half-second slices so cards still get picked.
    private func sleepWatchingCards(_ seconds: Double) async throws {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            try await handleCards()
            if let img = try? await ScreenCapture.captureRoblox() { try matchEndedCheck(img) }
            try await keepAliveAndWatchDisconnect()
            try await Task.sleep(nanoseconds: lag(500_000_000))
        }
    }

    /// Moves place/upgrade actions for priority slots ahead of the rest, keeping walks first.
    /// Returns each action paired with its recorded placement index (for .place actions).
    private func prioritize(_ actions: [MacroAction], prioritySlots: [Int]) -> [(MacroAction, Int?)] {
        // Placement index -> slot, so we can tell which upgrades belong to priority units.
        var slotOf: [Int: Int] = [:]; var idx = 0
        var tagged: [(MacroAction, Int?)] = []
        for a in actions {
            if case let .place(s, _) = a { slotOf[idx] = s; tagged.append((a, idx)); idx += 1 }
            else { tagged.append((a, nil)) }
        }
        guard !prioritySlots.isEmpty else { return tagged }
        func rank(_ a: MacroAction) -> Int {
            switch a {
            case .walk:                         return 0
            case let .place(s, _):              return prioritySlots.contains(s) ? 1 : 2
            case let .upgrade(i, _):            return prioritySlots.contains(slotOf[i] ?? -1) ? 1 : 2
            default:                            return 2
            }
        }
        // Stable sort keeps the recorded order within each group, so a unit is always
        // placed before its own upgrades.
        return tagged.enumerated()
            .sorted { (rank($0.element.0), $0.offset) < (rank($1.element.0), $1.offset) }
            .map(\.element)
    }

    // MARK: - Helpers

    private func waitFor(template name: String, timeout: Double) async throws -> NormPoint {
        guard let t = store?.template(name) else {
            throw MacroError.timedOut("\(name).png missing from templates folder")
        }
        return try await poll(timeout: timeout, what: name) { img in Matcher.find(t, in: img)?.point }
    }

    private func waitForAny(templates names: [String], timeout: Double) async throws -> NormPoint {
        let ts = names.compactMap { store?.template($0) }
        guard !ts.isEmpty else { throw MacroError.timedOut("\(names.joined(separator: "/")).png missing") }
        return try await poll(timeout: timeout, what: names.joined(separator: " / ")) { img in
            ts.lazy.compactMap { Matcher.find($0, in: img)?.point }.first
        }
    }

    /// Capture every 0.5s until `check` returns non-nil or we time out.
    /// While in a stage, every frame is also checked for the card screen.
    private func poll<T>(timeout: Double, what: String, _ check: (CGImage) throws -> T?) async throws -> T {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try Task.checkCancellation()
            try checkWatchdog()
            if let img = try? await ScreenCapture.captureRoblox() {
                scanEnemies(img)
                try await handleCards(img)
                if let v = try check(img) { return v }
                try matchEndedCheck(img)
                try await keepAliveAndWatchDisconnect()
            }
            try await Task.sleep(nanoseconds: lag(500_000_000))
        }
        throw MacroError.timedOut(what)
    }

    /// "+14402" on the results panel (next to "+55 XP") = Summer Pearls earned that match.
    static func pearlsEarned(_ img: CGImage) -> Int? {
        guard let lines = try? OCR.read(img, region: CGRect(x: 0.28, y: 0.58, width: 0.30, height: 0.10)) else { return nil }
        var best: Int?
        for l in lines {
            // "+55 ХP +14402" → take each "+number" that isn't the XP one
            let parts = l.text.replacingOccurrences(of: ",", with: "").split(separator: "+")
            for part in parts {
                let p = part.trimmingCharacters(in: .whitespaces)
                let digits = p.prefix { $0.isNumber }
                guard let n = Int(digits), n > 0 else { continue }
                let rest = p.dropFirst(digits.count).lowercased()
                if rest.contains("xp") || rest.contains("хр") || rest.contains("хp") || rest.contains("x p") { continue }
                best = max(best ?? 0, n)
            }
        }
        return best
    }

    /// Reward screens: any item marked "Secret" → count it, screenshot it, ping Discord (once per match).
    /// Ignores the level-modifier panel ("Secret Portal Rate Boost", "Secret Drop Rate").
    private func checkForSecret(_ img: CGImage) {
        guard !secretFoundThisMatch, let lines = try? OCR.read(img, fast: true) else { return }
        let hit = lines.first { l in
            let t = OCR.norm(l.text)
            guard t.contains("secret"), l.box.midX < 0.78 else { return false }
            return !["rate", "boost", "droprate", "chance", "portalrate", "luck"].contains { t.contains($0) }
        }
        guard let hit else { return }
        secretFoundThisMatch = true
        sessionSecrets += 1
        let map = Self.mapName(fromTitle: currentTitle)
        say("✦✦ SECRET item on the reward screen (\"\(hit.text)\") — screenshot saved")
        DebugLog.savePNG(img, name: "\(DebugLog.stamp())-SECRET-\(map).png")
        notify("✦ **Secret item!** on \(map.isEmpty ? "a map" : map) — \"\(hit.text)\" (secrets this session: \(sessionSecrets))", image: img)
    }

    /// Roblox kicks you after 20 minutes without input ("disconnected for being idle", error 278).
    /// Long waits (everything maxed, waiting for the match to end) send a harmless key every
    /// 4 minutes, and every ~15 s check for the Disconnected dialog so Reconnect gets clicked.
    private var lastKeepAlive = Date()
    private var lastDisconnectCheck = Date.distantPast
    private func keepAliveAndWatchDisconnect() async throws {
        if Date().timeIntervalSince(lastKeepAlive) > 240 {
            lastKeepAlive = Date()
            await input.key("q")          // cancels a held unit if any; otherwise does nothing
        }
        if state != .idle, Date().timeIntervalSince(lastMatchEnded) > 45 * 60,
           Date().timeIntervalSince(lastStuckPing) > 45 * 60 {
            lastStuckPing = Date()
            let shot = try? await ScreenCapture.captureRoblox()
            notify("⚠️ AA Macro: no match has finished in 45+ minutes (state: \(state.rawValue)). It may be stuck — here's the screen.", image: shot)
        }
        if Date().timeIntervalSince(lastDisconnectCheck) > 15 {
            lastDisconnectCheck = Date()
            if await handleDisconnect() { throw MacroError.timedOut("disconnected — reconnecting") }
        }
    }

    /// Every wait in a stage also watches for the VICTORY/DEFEAT panel. Without this, a wait for
    /// yen (the counter is still readable on the results screen, but never grows) sat there for
    /// 10 minutes at a time. Throws so the waiting routine gives up at once.
    private var lastEndCheck = Date.distantPast
    private func matchEndedCheck(_ img: CGImage) throws {
        guard inStage, state != .results, Date().timeIntervalSince(lastEndCheck) > 4 else { return }
        lastEndCheck = Date()
        if endScreen(in: img) != nil {
            say("Match is over — stopping what I was doing")
            throw MacroError.timedOut("match ended")
        }
    }
}
