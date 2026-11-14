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
    /// The live log lives in its own object so a new line only redraws the log view,
    /// not every panel that watches the engine.
    let journal = MacroJournal()
    var log: [String] { journal.lines.map(\.text) }
    @Published var runsCompleted = 0
    @Published var currentMap = ""
    @Published var wins = 0
    @Published var losses = 0
    /// Matches whose result panel was seen but neither VICTORY nor DEFEAT could be read.
    /// Counted on their own instead of being called losses.
    @Published var unknowns = 0
    /// Summer Pearls earned this session (sum of the results panel's "+N") and secrets seen.
    @Published var sessionPearls = 0
    @Published var sessionSecrets = 0
    /// When the last match ended (for the "no match finished in 45 min" Discord ping).
    var lastMatchEnded = Date()
    var lastStuckPing = Date.distantPast
    var secretFoundThisMatch = false
    /// Drop-shaped lines read off this match's reward screens, and whether a picture of one has
    /// been saved. Kept so a drop the "Secret" check misses can still be explained afterwards.
    var rewardSeen = Set<String>()
    var savedRewardShot = false

    /// Set once the "no webhook" note has been logged, so it is said once per session.
    var warnedNoWebhook = false

    func notify(_ text: String, image: CGImage? = nil) {
        let hook = (store?.settings.discordWebhook ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !hook.isEmpty else {
            if !warnedNoWebhook {
                warnedNoWebhook = true
                say("Discord alerts are off — paste a webhook URL into Settings → Discord to get them")
            }
            return
        }
        Discord.send(text, image: image, webhook: hook) { why in
            guard let why else { return }
            Task { @MainActor [weak self] in self?.say("⚠️ Discord: \(why)") }
        }
    }

    /// Settings → Test: send a test message and say in the log whether it actually arrived.
    func testDiscord() {
        let hook = (store?.settings.discordWebhook ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !hook.isEmpty else { say("⚠️ Discord: no webhook URL in Settings"); return }
        say("Discord: sending a test message…")
        Discord.send("💖 AA Macro test message — Discord alerts are working!", webhook: hook) { why in
            Task { @MainActor [weak self] in
                self?.say(why.map { "⚠️ Discord test failed: \($0)" } ?? "Discord test message sent ✓")
            }
        }
    }
    @Published var startedAt: Date?
    weak var store: Store?

    var task: Task<Void, Never>?

    // MARK: Cards interrupt everything
    /// Set by the watcher when the card screen appears; the next click/key anywhere votes first.
    var cardsPending: CGImage?
    var handlingCards = false
    /// Bumped every time a card vote interrupts something, so that routine can tell its last
    /// attempt was disturbed (and not blame the spot).
    var cardInterrupts = 0
    var cardWatcher: Task<Void, Never>?

    /// True when the game's own "Auto-skip card votes" setting is on: the card screen never
    /// needs reading, which saves one text read every second for the whole match.
    var cardsAutoSkipped: Bool { store?.settings.cardsAutoSkipped ?? false }

    func startCardWatcher() {
        InputController.beforeAction = { [weak self] in await self?.yieldToCards() }
        guard cardWatcher == nil else { return }
        cardWatcher = Task { [weak self] in
            while !Task.isCancelled {
                if let self, self.inStage, !self.cardsAutoSkipped, !self.handlingCards, self.cardsPending == nil,
                   let img = try? await ScreenCapture.captureRoblox(), Self.cardScreenVote(img) != nil {
                    self.cardsPending = img
                }
                try? await Task.sleep(nanoseconds: 800_000_000)
            }
        }
    }
    func stopCardWatcher() { cardWatcher?.cancel(); cardWatcher = nil; cardsPending = nil }

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
    var awakeToken: NSObjectProtocol?
    func stayAwake(_ on: Bool) {
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
    var inStage = false
    /// Consecutive recoveries without a completed run; used to escalate.
    var recoverAttempts = 0
    /// Buttons that end a match. A loss and a win may show different screens —
    /// drop a template for each into the templates folder; any of them counts.
    var input: InputController {
        let s = store?.settings ?? MacroSettings()
        return InputController(delayMs: Int(Double(s.inputDelayMs) * max(1, s.lagFactor)))
    }

    /// Every wait goes through here, so the Lag setting slows the whole macro down evenly.
    func lag(_ ns: UInt64) -> UInt64 {
        UInt64(Double(ns) * max(0.5, store?.settings.lagFactor ?? 1))
    }

    // MARK: - Watchdog
    /// When the current run must have finished by. Past it, the run is treated as stuck.
    var runDeadline: Date?
    var lossStreak = 0

    func checkWatchdog() throws {
        guard let d = runDeadline, Date() > d else { return }
        runDeadline = nil
        inStage = false
        throw MacroError.timedOut("whole run (over \(store?.settings.stuckMinutes ?? 45) min — looked stuck, starting over)")
    }

    /// The map name read off the matchmaking popup (big, clean text) — a second opinion for the
    /// stage title, which is often misread.
    var popupMapHint = ""
    /// Placement cost per hotbar slot, read from the hotbar once per stage.
    var slotCosts: [Int: Int] = [:]
    /// Set after voting on a weather card so the same vote screen isn't handled twice.
    var cardVotedAt = Date.distantPast
    /// Raw stage title of the current match (e.g. "Magic Town Summer Hunt").
    var currentTitle = ""
    /// How the current match ended, set by endScreen when it sees the result panel.
    var lastOutcome: MatchOutcome = .unknown
    /// Where enemies have been seen this match (their "3.8/3.8" health labels sit on the lane).
    var enemyLane: [NormPoint] = []
    var lastEnemyScan = Date.distantPast

    /// Records enemy positions from their health labels. Cheap, throttled to ~1/s.
    var enemyScanRunning = false

    /// Set once the VICTORY/DEFEAT panel was seen, so the screens after it count as end-of-match.
    var sawResultPanel = false

    // MARK: - Control

    func start() {
        guard task == nil else { return }
        if (store?.settings.mode ?? .summerHunt) == .portal {
            say("🗺️ Portal mode isn't automatic yet — use Teach portal / Test plan in a portal match. Switch the mode back to Summer Hunt to farm.")
            return
        }
        if (store?.settings.mode ?? .summerHunt) == .dungeon {
            say("🏰 Dungeon mode can't play on its own yet — press \"Watch my dungeon\" in the Record box and play a run so it can learn. Switch the mode back to Summer Hunt to farm.")
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
        startedAt = Date(); wins = 0; losses = 0; unknowns = 0; lossStreak = 0; runDeadline = nil
        sessionPearls = 0; sessionSecrets = 0; lastMatchEnded = Date(); lastStuckPing = .distantPast
        lastStatsTick = Date()
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
        if let st = startedAt, wins + losses + unknowns > 0 {
            let h = max(Date().timeIntervalSince(st) / 3600, 0.01)
            notify("⏹ AA Macro stopped — \(wins)W / \(losses)L" + (unknowns > 0 ? " / \(unknowns)?" : "")
                   + ", \(sessionPearls) Summer Pearls (\(Int(Double(sessionPearls) / h))/h)"
                   + (sessionSecrets > 0 ? ", ✦ \(sessionSecrets) secret(s)" : "") + String(format: " in %.1f h", h))
        }
        bankRunningTime()
        stayAwake(false)
        stopCardWatcher()
        task?.cancel(); task = nil
        dungeonTask?.cancel()                 // a dungeon watch saves its run on the way out
        scanTask?.cancel(); scanTask = nil; scanning = false
        if manualTeachTask == nil { teachNowActive = false; teachNextMatch = false }
        startedAt = nil
        state = .idle
        say("Stopped.")
    }

    func say(_ s: String) {
        let t = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        journal.add("[\(t)] \(s)")
        DebugLog.append("[\(t)] [\(state.rawValue)] \(s)")
    }

    // MARK: - Lifetime stats (kept across sessions in stats.json)

    /// When running time was last added to the lifetime total.
    var lastStatsTick = Date()

    /// Adds the time since the last tick to the lifetime "hours run" total.
    func bankRunningTime() {
        guard startedAt != nil else { return }
        let now = Date()
        store?.updateStats { $0.seconds += now.timeIntervalSince(lastStatsTick) }
        lastStatsTick = now
    }

    /// Records one finished match in the lifetime totals.
    func recordLifetime(outcome: MatchOutcome, pearls: Int) {
        store?.updateStats { s in
            s.runs += 1
            switch outcome {
            case .victory: s.wins += 1
            case .defeat:  s.losses += 1
            case .unknown: s.unknown += 1
            }
            s.pearls += pearls
        }
        bankRunningTime()
    }

    // MARK: - Main loop

    func runLoop() async {
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
                    case .portal, .dungeon: stop(); return   // never reached: start() blocks these modes
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
    static let dismissWords = ["close", "ok", "okay", "nothanks", "later", "maybelater", "skip",
                               "continue", "claim", "collect", "decline", "gotit", "dismiss"]
    var lastPopupCheck = Date.distantPast

    // MARK: - States that stay here (the rest are in Engine+Lobby / Engine+Results / Engine+AutoPlay)

    /// Play the stage: every map goes through auto placement (taught spots, learned layout,
    /// saved scan, live search — in that order). The old "replay a recording" path is gone: it
    /// had none of the placement fixes and was never what farmed overnight.
    func doPlayStage() async throws {
        currentMap = (currentTitle.isEmpty ? "unknown" : currentTitle) + " · auto"
        try await autoPlay()
        state = .results
    }

    /// Something went wrong. Figure out where we are from the screen and resume from there,
    /// instead of blindly assuming we're in the lobby.
    func doRecover() async throws {
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

    // MARK: - State of the tools (scan / walk / teach), used by the Engine+… files

    @Published var scanning = false
    /// Portal walks (Engine+Portal).
    @Published var walkRecording = false
    var walkListener: TeachListener?
    var walkName = ""

    /// Teach portal (Engine+Portal).
    @Published var planTeaching = false
    var planTask: Task<Void, Never>?
    var planListener: TeachListener?

    /// Dungeon watch (Engine+Dungeon): listen-only, never sends input.
    @Published var dungeonWatching = false
    @Published var dungeonStatus = ""
    var dungeonTask: Task<Void, Never>?

    /// Teach now (Engine+Teach).
    @Published var teachNowActive = false
    var manualTeachTask: Task<Void, Never>?
    /// Set by "Teach now" while the macro runs: the next match is taught too.
    var teachNextMatch = false
    @Published var scanProgress = ""
    var scanTask: Task<Void, Never>?

    /// Filled by probeGrid: spots a real test-place rejected.
    var scanBad: [NormPoint] = []
    var lastScanHitLimit = false

    // MARK: - Per-match state (Engine+AutoPlay / Engine+Placement)

    /// The scan in use this match (updated as we learn).
    var activeProfile: MapProfile?

    // Per-match auto state
    var autoPlaced: [(slot: Int, at: NormPoint)] = []
    var autoCovered: [Int: Int] = [:]
    var autoFull = Set<Int>()
    var autoMaxed = Set<Int>()          // indexes into autoPlaced

    /// Set while a Steps "upgrade" step runs: upgrades stop at this time.
    var upgradeDeadline: Date?

    /// Teach mode state for this match.
    var teachingThisMatch = false
    var teachName = ""
    var teachSpots: [TaughtSpot] = []
    var teachListener: TeachListener?

    /// Match debug record (summary in the log + a placements picture in logs/).
    var matchTries: [(slot: Int, at: NormPoint, ok: Bool)] = []
    var matchPlanned: [Int: Int] = [:]
    var matchPlaceTime: [Int: Double] = [:]
    var matchStartImage: CGImage?

    /// Unit names under the hotbar, read once per stage (slot → name).
    var slotNames: [Int: String] = [:]

    /// Spots that didn't work this match (a real click placed nothing) — usually another player's
    /// unit or a bad patch. Not tried again this match. Separate lists for ground and hill units.
    var blockedGround: [NormPoint] = []
    var blockedHill: [NormPoint] = []
    /// Set when the match start already did teleport-to-spawn + camera, so it isn't done twice.
    var didSpawnReset = false

    var yenUnreadableSince: Date?

    // MARK: - Cards

    /// If "The weather shifts…" vote is up, read the 3 cards, click the best one, press Vote.
    /// Called before every action, during waits, and on every polled frame — so cards are
    /// handled whenever they appear, never replayed from a recording.
    func handleCards(_ frame: CGImage? = nil) async throws {
        try checkWatchdog()
        if !handlingCards, cardsPending != nil { await yieldToCards(); return }
        if inStage, Date().timeIntervalSince(lastPopupCheck) > 6 { await clearPopups(frame) }
        guard inStage, !cardsAutoSkipped, Date().timeIntervalSince(cardVotedAt) > 15 else { return }
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

    /// A long wait, chopped into half-second slices so cards still get picked.
    func sleepWatchingCards(_ seconds: Double) async throws {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            try await handleCards()
            if let img = try? await ScreenCapture.captureRoblox() { try matchEndedCheck(img) }
            try await keepAliveAndWatchDisconnect()
            try await Task.sleep(nanoseconds: lag(500_000_000))
        }
    }

    /// Capture every 0.5s until `check` returns non-nil or we time out.
    /// While in a stage, every frame is also checked for the card screen.
    func poll<T>(timeout: Double, what: String, _ check: (CGImage) throws -> T?) async throws -> T {
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

    /// Roblox kicks you after 20 minutes without input ("disconnected for being idle", error 278).
    /// Long waits (everything maxed, waiting for the match to end) send a harmless key every
    /// 4 minutes, and every ~15 s check for the Disconnected dialog so Reconnect gets clicked.
    var lastKeepAlive = Date()
    var lastDisconnectCheck = Date.distantPast
    func keepAliveAndWatchDisconnect() async throws {
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
    var lastEndCheck = Date.distantPast

    // MARK: - Small types shared by the extensions

    /// The unit panel that pops up right after a placement. Unsellable units (e.g. slot 6) have
    /// no Sell button, so look for any of the panel's own words.
    /// Everything worth knowing right after a placement click, from ONE text read (it used to be
    /// five separate reads, ~1 s per failed try).
    struct AfterClick { var panel = false, limit = false, noYen = false, failed = false }

    /// What holding a unit shows: the placement overlay (if readable) and whether the slot is
    /// already at its placement limit.
    struct OverlayRead { var planner: AutoPlanner? = nil; var full = false }
}
