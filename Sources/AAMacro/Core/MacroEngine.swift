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
        runsCompleted = 0
        inStage = false; recoverAttempts = 0
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
        say("Starting. Press F6 any time to stop.")
        stayAwake(true)
        startCardWatcher()
        startedAt = Date(); wins = 0; losses = 0; lossStreak = 0; runDeadline = nil
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
        stayAwake(false)
        stopCardWatcher()
        task?.cancel(); task = nil
        scanTask?.cancel(); scanTask = nil; scanning = false
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
                case .walkToEvent:  try await doWalkToEvent()
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
        guard let button = candidates.first(where: { Self.dismissWords.contains(OCR.norm($0.text)) }) else { return false }
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
        let find: NormPoint
        do {
            find = try await poll(timeout: 20, what: "Find Match button") { img in
                try OCR.find("find match", in: img, region: Region.centerPopup)?.center
            }
        } catch {
            say("⚠️ Couldn't see Find Match — saving a screenshot")
            _ = await DebugLog.snapshot("no-find-match")
            throw error
        }
        await input.click(find)
        say("Clicked Find Match — reading the code")

        for attempt in 1...4 {
            // 1) Read the code — and only accept it once the popup has STOPPED moving
            //    (it animates in; positions read mid-animation make the click miss).
            var lastSubmit: CGPoint?
            var snapped = false
            let start = Date()
            let (code, codeLine, submit) = try await poll(timeout: 25, what: "matchmaking code") { img -> (String, OCR.Line, OCR.Line)? in
                let lines = try OCR.read(img, region: Region.centerPopup)
                if !snapped, Date().timeIntervalSince(start) > 8 {
                    snapped = true
                    self.say("Still no code after 8s — the popup reads: " + lines.prefix(10).map(\.text).joined(separator: " | "))
                    Task { _ = await DebugLog.snapshot("no-code") }
                }
                guard let prompt = lines.first(where: { let n = OCR.norm($0.text)
                          return n.contains("enterthistext") || n.contains("enterthis") || n.contains("pleaseenter") || n.contains("thistextin") }),
                      let submit = lines.first(where: { OCR.norm($0.text).hasPrefix("submit") }) else { return nil }
                guard let codeLine = lines
                        .filter({ $0.box.minY > prompt.box.maxY && $0.box.maxY < submit.box.minY })
                        .sorted(by: { $0.box.minY < $1.box.minY }).first else { return nil }
                let code = codeLine.text.filter { $0.isLetter || $0.isNumber }
                guard (4...10).contains(code.count) else { return nil }
                let here = CGPoint(x: submit.box.midX, y: submit.box.midY)
                defer { lastSubmit = here }
                guard let prev = lastSubmit, abs(prev.x - here.x) < 0.008, abs(prev.y - here.y) < 0.008 else { return nil }
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
                if typing > 1 {
                    // Retry: move the cursor to the end with → (no extra clicks — those can land
                    // outside the box and drop focus), then delete everything.
                    for _ in 0..<16 { await input.key("right", holdMs: 20) }
                    for _ in 0..<20 { await input.key("backspace", holdMs: 25) }
                    try await Task.sleep(nanoseconds: lag(150_000_000))
                }
                await input.type(code.lowercased(), extraDelayMs: s.typeDelayMs)
                try await Task.sleep(nanoseconds: lag(500_000_000))            // let Roblox draw the text
                let inBox = await readInputBox(below: codeLine, above: submit)
                if Self.codesMatch(inBox, code) { entered = true; break }
                say("Box shows \"\(inBox.isEmpty ? "?" : inBox)\" — retyping (\(typing)/3)")
            }
            guard entered else { say("⚠️ Couldn't get the code into the box"); continue }

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
                    if case .lobbyButton? = endScreen(in: rimg), r > 0 { break }     // rewards done
                    if !(await clearPopups(rimg)) { await input.click(NormPoint(x: 0.5, y: 0.6)) }
                    say("Clicking through rewards…")
                    try? await Task.sleep(nanoseconds: lag(1_200_000_000))
                }
            case .result(nil)?, .drops?, nil:
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
        if let lines = try? OCR.read(img, fast: true) {
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
        if let r = t.range(of: "summer hunt", options: .caseInsensitive) { t = String(t[..<r.lowerBound]) }
        // Stray symbols the reader adds in front ("•Planet Greenie", "Ouou •Planet…") and non-Latin junk.
        if let dot = t.lastIndex(where: { "•*·".contains($0) }) { t = String(t[t.index(after: dot)...]) }
        t = String(t.unicodeScalars.filter { $0.isASCII }.map(Character.init))
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
                if m.score < m.unshifted - 0.05 { mapShift = (m.dx, m.dy) }
                say(String(format: "View looks different from the %@ scan (difference %.2f — weather/units) — using the scan anyway, checking each spot", prof.name, m.score))
                activeProfile = prof
                return
            }
            mapShift = (m.dx, m.dy)
            say(String(format: "Camera check vs %@ scan: shift (%+.3f, %+.3f), difference %.2f", prof.name, m.dx, m.dy, m.score))
        } else {
            say("Using the \(prof.name) scan (no reference view saved — rescan to enable the camera check)")
        }
        activeProfile = prof
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
            if near(prof.suspectHill ?? []) && !near(prof.hill) {          // failed in an earlier match too
                if !near(prof.badHill ?? []) { prof.badHill = (prof.badHill ?? []) + [q] }
            } else if !near(prof.suspectHill ?? []) {
                prof.suspectHill = (prof.suspectHill ?? []) + [q]
            }
        } else {
            if near(prof.suspectGround ?? []) && !near(prof.ground) {
                if !near(prof.badGround ?? []) { prof.badGround = (prof.badGround ?? []) + [q] }
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
    static func parseSteps(_ text: String) -> (steps: [AutoStep], problems: [String]) {
        var steps: [AutoStep] = [], problems: [String] = []
        for raw in text.lowercased().split(whereSeparator: { $0 == "\n" || $0 == ";" }) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
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
        currentMap = (Self.mapName(fromTitle: currentTitle).isEmpty ? "unknown" : Self.mapName(fromTitle: currentTitle)) + " · auto"
        autoPlaced = []; autoCovered = [:]; autoFull = []; autoMaxed = []
        blockedGround = []; blockedHill = []

        // Build the step list.
        var steps: [AutoStep]
        let parsed = Self.parseSteps(s.autoSteps)
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
        if s.teachMode, (activeProfile?.taught ?? []).isEmpty {
            let name = activeProfile?.name ?? store?.canonicalName(Self.mapName(fromTitle: currentTitle)) ?? Self.mapName(fromTitle: currentTitle)
            if !name.isEmpty {
                teachingThisMatch = true; teachName = name; teachSpots = []
                say("🎓 TEACH MODE — \(name) isn't taught yet. When a unit is due I'll ask you to place it; I do everything else (upgrades, cards).")
            }
        }
        defer { teachListener?.stop(); teachListener = nil }
        if let t = activeProfile?.taught, !t.isEmpty {
            say("Using your taught spots for \(activeProfile?.name ?? "this map") (\(t.count) units)")
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
        for step in steps {
            try Task.checkCancellation()
            if try await checkResults() { return }
            try await handleCards()
            say("Step: \(step)")
            switch step {
            case let .place(slot, count):
                for _ in 0..<count {
                    if autoFull.contains(slot) { break }
                    if !(try await placeSlot(slot)) {
                        if !autoFull.contains(slot) { unplaced.append(slot) }
                        break
                    }
                }
            case let .upgrade(slot, levels):
                phantomSlots = []
                try await upgradeStep(slot: slot, levels: levels)
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
        say("Auto: everything maxed — waiting for the match to end")
    }

    /// Upgrades every placed copy of a slot (or all units, priority order first).
    /// levels nil = until MAX (or the unit card's Max upgrade).
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
        let s = store?.settings ?? MacroSettings()
        let range = s.autoRangePerSlot[slot] ?? 0.12
        var tried: [NormPoint] = []
        var plannerUsed: AutoPlanner?
        let deadline = Date().addingTimeInterval(240)
        var round = 0
        var widened = false

        func near(_ list: [NormPoint], _ p: NormPoint, _ r: Double = 0.015) -> Bool {
            list.contains { abs($0.x - p.x) < r && abs($0.y - p.y) < r * 1.4 }
        }

        if teachingThisMatch {
            if let price = await cost(of: slot) {
                _ = try await poll(timeout: 900, what: "\(price)¥ for slot \(slot)") { img -> Bool? in self.enoughYen(img, price) }
            }
            if let p = try await teachPlace(slot) {
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
            let planner = await readOverlay(slot: slot)
            if slotIsFull { autoFull.insert(slot); say("Slot \(slot) is at its placement limit"); return false }
            plannerUsed = planner ?? plannerUsed
            let hill = s.hillSlots.isEmpty ? (planner?.isHillOverlay ?? false) : s.hillSlots.contains(slot)
            let taken = autoPlaced.map(\.at)
            let bad = ((hill ? activeProfile?.badHill : activeProfile?.badGround)?.map(shifted) ?? [])
                + (hill ? blockedHill : blockedGround)

            // Gather from every source, best sources first. Your taught spots for this slot come
            // before everything (the n-th copy of a slot goes to the n-th spot you used for it).
            var picks: [NormPoint] = []
            let taughtHere = (activeProfile?.taught ?? []).filter { $0.slot == slot }.map { shifted($0.at) }
            if !taughtHere.isEmpty {
                let already = autoPlaced.filter { $0.slot == slot }.count
                picks += Array(taughtHere.dropFirst(already)) + Array(taughtHere.prefix(already))
            }
            // Other slots' taught spots of the same kind are good backups.
            picks += (activeProfile?.taught ?? []).filter { $0.slot != slot && s.hillSlots.contains($0.slot) == hill }.map { shifted($0.at) }
            let taughtAll = picks
            if hill {
                // Hills are big: the best bet is right around a hill unit that's already down.
                picks += ringsAround(autoPlaced.filter { s.hillSlots.contains($0.slot) && $0.slot != 0 }.map(\.at),
                                     radii: widened ? [0.04, 0.06, 0.085, 0.11] : [0.035, 0.05, 0.07])
            }
            if !hill, (activeProfile?.ground.count ?? 0) < 15 {
                // No good scan yet: the ground right beside units that already went down this
                // match is proven placeable — far fewer wasted clicks than untested spots.
                picks += ringsAround(autoPlaced.filter { !s.hillSlots.contains($0.slot) && $0.slot != 0 }.map(\.at),
                                     radii: [0.04, 0.055])
            }
            if let prof = activeProfile { picks += profileSpots(prof, hill: hill, range: range, avoid: taken + tried) }
            if let planner {
                picks += planner.candidates(range: range, taken: taken, covered: autoCovered, hill: hill,
                                            maxLaneDistance: 7, avoid: tried, limit: 12).map(\.spot)
            }
            if !hill || widened { picks += probeSpots(avoid: tried + taken) }
            // Hill units: only spots that are actually green in the overlay (when it shows green).
            if hill, let planner, planner.greenCellCount >= 40 {
                picks = picks.filter { p in taughtAll.contains(where: { $0.x == p.x && $0.y == p.y }) || planner.overlayCounts(at: p).green >= 4 }
            }
            var unique: [NormPoint] = []
            // Failed/blocked spots are avoided with some margin: a spot 1 % away from one that
            // didn't work almost never works either.
            for p in picks where !near(unique, p, 0.012) && !near(tried, p, 0.02) && !near(bad, p, 0.022) && !near(taken, p, 0.025) {
                unique.append(p)
            }
            // Ground units: the safe spots are right beside the road/route enemies walk — not the
            // corners and outskirts. Order by distance to the route (spots ON the road go last).
            if !hill {
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
                        let bonus = proven.contains("\(Int(p.x * 200)),\(Int(p.y * 200))") ? 0.015 : 0
                        return d - bonus
                    }
                    unique = unique.map { ($0, key($0)) }.sorted { $0.1 < $1.1 }.map(\.0)
                }
            }
            if unique.isEmpty {
                if !widened {
                    // Widen once: bigger rings around our units, spots beside the lane, the grid.
                    widened = true
                    say("Slot \(slot): no fresh spots — widening the search")
                    continue
                }
                say("Slot \(slot): nothing left to try right now — moving on, will retry later")
                return false
            }
            say("Slot \(slot) (\(hill ? "hill" : "ground")) round \(round): \(unique.count) candidate spots")

            var needMoney = false
            for target in unique.prefix(15) {
                try Task.checkCancellation()
                if Date() > deadline { break }
                let ci = cardInterrupts
                let result = await placeOnce(slot: slot, at: target)
                if cardInterrupts != ci, case .failed = result { continue }   // cards interrupted it — try again later
                tried.append(target)
                switch result {
                case .placed:
                    learnSpot(target, hill: hill, good: true)
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
                    if lastFailWasClick { learnSpot(target, hill: hill, good: false) }
                    // Either way, don't try it again this match (another player's unit, most likely).
                    if lastFailWasBlock || lastFailWasClick {
                        if hill { blockedHill.append(target) } else { blockedGround.append(target) }
                    }
                    continue
                }
                break
            }
            if needMoney { try await sleepWatchingCards(3) }
        }
        say("⚠️ Couldn't place slot \(slot) in 4 minutes — will retry it later")
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

    /// Adds a taught spot to the map's file right away (so nothing is lost if the match is cut short).
    private func saveTaught(slot: Int, at p: NormPoint) {
        let q = unshifted(p)
        teachSpots.append(TaughtSpot(slot: slot, at: q))
        var prof = store?.profiles.first(where: { $0.name == teachName }) ?? activeProfile
            ?? MapProfile(name: teachName, ground: [], hill: [], lane: enemyLane, scannedAt: Date())
        prof.taught = teachSpots
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
    static let parkA = NormPoint(x: 0.03, y: 0.96)
    static let parkB = NormPoint(x: 0.97, y: 0.13)
    /// The park corner farthest from a spot, so the parked range circle doesn't cover it.
    static func park(awayFrom p: NormPoint) -> NormPoint {
        let opts = [parkA, parkB, NormPoint(x: 0.03, y: 0.13), NormPoint(x: 0.97, y: 0.96)]
        return opts.max { a, b in
            (a.x - p.x) * (a.x - p.x) + (a.y - p.y) * (a.y - p.y) < (b.x - p.x) * (b.x - p.x) + (b.y - p.y) * (b.y - p.y)
        } ?? parkA
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
        guard let base1 = try? await ScreenCapture.captureRoblox() else { return nil }
        await input.key(String(slot))
        try? await Task.sleep(nanoseconds: lag(450_000_000))           // overlay fades in
        let held1 = try? await ScreenCapture.captureRoblox()
        slotIsFull = false
        if let h = held1, Self.placementLimitMessage(h) {
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
        guard let held = helds.first,
              let planner = AutoPlanner(bases: [base1] + [base2].compactMap { $0 }, helds: helds, enemyLane: enemyLane) else { return nil }

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
    static func readSlotCounter(_ img: CGImage, slot: Int) -> (placed: Int, limit: Int)? {
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
    /// Set when the match start already did teleport-to-spawn + camera, so it isn't done twice.
    private var didSpawnReset = false

    private func placeOnce(slot: Int, at target: NormPoint, requireBlue: Bool = false) async -> PlaceResult {
        lastFailWasClick = false
        lastFailWasBlock = false
        if Task.isCancelled { return .failed }
        let hillUnit = store?.settings.hillSlots.contains(slot) ?? false

        await WindowManager.focusRoblox()
        // 1) Reference shot with nothing held (cursor parked far from the target).
        input.move(Self.park(awayFrom: target))
        try? await Task.sleep(nanoseconds: lag(150_000_000))
        let base = try? await ScreenCapture.captureRoblox()
        // 2) Hold the unit: the overlay shows where it can't go (lane, other players' units = red).
        await input.key(String(slot))
        try? await Task.sleep(nanoseconds: lag(350_000_000))
        let parked = try? await ScreenCapture.captureRoblox()
        if let p = parked {
            if Self.placementLimitMessage(p) { await input.key("q"); return .limitReached }
            if Self.notEnoughYenMessage(p) { await input.key("q"); return .cantAfford }
        }
        let counterBefore = parked.flatMap { Self.readSlotCounter($0, slot: slot) }
        if let c = counterBefore, c.placed >= c.limit { await input.key("q"); return .limitReached }

        // 3) Is the target itself red in the overlay (someone's unit / the lane)? Skip without clicking.
        if let base, let parked, let ov = AutoPlanner(bases: [base], helds: [parked]) {
            let c = ov.overlayCounts(at: target)
            let blocked = hillUnit ? (c.green < 3 && c.red >= 4) : c.red >= 5
            if blocked {
                say(String(format: "Slot %d: spot (%.3f, %.3f) is red in the overlay (taken / lane) — skipping", slot, target.x, target.y))
                lastFailWasBlock = true
                await input.key("q")
                try? await Task.sleep(nanoseconds: lag(150_000_000))
                return .failed
            }
        }

        // 4) Hover: the range circle turns BLUE on a valid spot, RED on an invalid one.
        var circleWasBlue = false
        input.move(target)
        try? await Task.sleep(nanoseconds: lag(300_000_000))
        let hovering = try? await ScreenCapture.captureRoblox()
        if let h = hovering, Self.cardScreenVote(h) != nil {
            say("Cards appeared while placing — cancelling, picking a card, then retrying")
            await input.key("q")
            try? await Task.sleep(nanoseconds: lag(200_000_000))
            cardVotedAt = .distantPast
            try? await handleCards(h)
            return .failed
        }
        if let parked, let hovering {
            switch Self.rangeCircleVerdict(parked: parked, hovering: hovering, at: target) {
            case .invalid:
                say(String(format: "Slot %d: range circle is RED at (%.3f, %.3f) — not placing there", slot, target.x, target.y))
                lastFailWasBlock = true
                await input.key("q")
                try? await Task.sleep(nanoseconds: lag(200_000_000))
                return .failed
            case .valid:
                circleWasBlue = true
            case .unsure:
                if requireBlue {
                    await input.key("q")
                    try? await Task.sleep(nanoseconds: lag(150_000_000))
                    return .failed
                }
            }
        }

        // 5) Click — up to 3 times on the same spot (Roblox sometimes drops a click) — and read
        //    what the game says after each.
        var afterClick: CGImage?
        let clicks = circleWasBlue ? 2 : 1          // a drop-click is only worth retrying on a confirmed-good spot
        for clickTry in 1...clicks {
            if clickTry > 1 {
                say("Slot \(slot): placement didn't register — clicking the same spot again")
                input.move(target)
                try? await Task.sleep(nanoseconds: lag(200_000_000))
            }
            await input.click(target)
            try? await Task.sleep(nanoseconds: lag(600_000_000))
            afterClick = try? await ScreenCapture.captureRoblox()
            guard let img = afterClick else { continue }
            if Self.unitPanelOpen(img) || Self.placementLimitMessage(img) || Self.notEnoughYenMessage(img) { break }
            // Still holding the unit (no panel)? Make sure we still are before clicking again.
            if clickTry < clicks {
                await input.key(String(slot))      // re-select in case the click dropped it
                try? await Task.sleep(nanoseconds: lag(250_000_000))
                let re = try? await ScreenCapture.captureRoblox()
                if let re, Self.placementLimitMessage(re) {
                    // Holding was refused: the slot is now full → our click DID place it.
                    await input.key("q"); try? await Task.sleep(nanoseconds: lag(200_000_000))
                    say("Placed slot \(slot) ✓ (slot is now at its limit)")
                    return .placed
                }
                if let c = re.flatMap({ Self.readSlotCounter($0, slot: slot) }) {
                    if let cb = counterBefore, c.placed > cb.placed { break }      // it did go down after all
                    if c.placed >= c.limit {
                        await input.key("q"); try? await Task.sleep(nanoseconds: lag(200_000_000))
                        say("Placed slot \(slot) ✓ (\(c.placed)/\(c.limit))")
                        return .placed
                    }
                }
            }
        }
        if let img = afterClick {
            if Self.placementLimitMessage(img) {
                // The slot wasn't full before this click (checked above), so the limit now means
                // our unit went down.
                say("Placed slot \(slot) ✓ (game now says it's at its limit)")
                await input.key("q"); try? await Task.sleep(nanoseconds: lag(200_000_000))
                return .placed
            }
            if Self.notEnoughYenMessage(img) {
                say("Slot \(slot): game says not enough yen")
                await input.key("q"); try? await Task.sleep(nanoseconds: lag(200_000_000))
                return .cantAfford
            }
        }

        // 6) Did it go down? The unit's panel pops up (with Sell) right after a placement.
        if let img = afterClick, Self.unitPanelOpen(img) {
            say("Placed slot \(slot) ✓ (unit panel opened)")
            return .placed
        }
        // …or the slot counter went up (1/3 → 2/3). Exact — no yen reading needed.
        await input.key(String(slot))
        try? await Task.sleep(nanoseconds: lag(350_000_000))
        let check = try? await ScreenCapture.captureRoblox()
        await input.key("q")
        try? await Task.sleep(nanoseconds: lag(150_000_000))
        if let img = check, Self.placementLimitMessage(img) {
            say("Placed slot \(slot) ✓ (slot is now at its limit)")
            return .placed
        }
        if let img = check, let ca = Self.readSlotCounter(img, slot: slot), ca.placed >= ca.limit,
           counterBefore.map({ $0.placed < $0.limit }) ?? true {
            say("Placed slot \(slot) ✓ (\(ca.placed)/\(ca.limit))")
            return .placed
        }
        if let cb = counterBefore, let img = check, let ca = Self.readSlotCounter(img, slot: slot) {
            if ca.placed > cb.placed {
                say("Placed slot \(slot) ✓ (\(cb.placed)/\(cb.limit) → \(ca.placed)/\(ca.limit))")
                return .placed
            }
            lastFailWasClick = true
            return .failed
        }
        // Counter not readable: look once more (slower), compared with the count from before.
        if let n = await placedCount(slot: slot) {
            if n.full || (counterBefore.map { n.placed > $0.placed } ?? false) {
                say("Placed slot \(slot) ✓ (counter now \(n.placed))")
                return .placed
            }
        }
        _ = base
        lastFailWasClick = true
        return .failed
    }

    /// "Not enough yen" type messages.
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
                    _ = try await poll(timeout: 600, what: "\(cost)¥ for upgrade") { img -> Bool? in
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

    private func endScreen(in img: CGImage) -> EndScreen? {
        guard let lines = try? OCR.read(img, fast: true) else { return nil }
        let t = lines.map { OCR.norm($0.text) }
        // "Return to lobby" (top centre, next to Replay) — the last step.
        if let back = lines.first(where: { OCR.norm($0.text).contains("returntolobby") }) {
            return .lobbyButton(back.center)
        }
        // The VICTORY!!! / DEFEAT panel, with its "Next" button.
        let isWin = t.contains { w in Self.winWords.contains { w.contains($0) } }
        // The stylised DEFEAT/VICTORY art is often unreadable; the panel's own lines aren't.
        let panelLines = t.filter { $0.contains("wavescompleted") || $0.contains("totaltime") || $0.contains("xpprogress") }.count
        let isLoss = t.contains { w in Self.lossWords.contains { w.contains($0) } } || (!isWin && panelLines >= 2)
        if isWin || isLoss {
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
            }
            try await Task.sleep(nanoseconds: lag(500_000_000))
        }
        throw MacroError.timedOut(what)
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
