import Foundation
import CoreGraphics

/// Lobby → summer pad → matchmaking code → vote. Also the popup / disconnect handling that runs between states.
extension MacroEngine {

    /// Clicks a dismiss button if a popup is blocking the screen (level up, rewards, daily login,
    /// trade/party invites…). Never touches the matchmaking / code / vote / card screens.
    @discardableResult
    func clearPopups(_ frame: CGImage? = nil) async -> Bool {
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
    func choosePrivateServer(_ frame: CGImage? = nil) async -> Bool {
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
    func handleDisconnect() async -> Bool {
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
    func doLobby() async throws {
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
    func doWalkToEvent() async throws {
        say("Walking to summer event")
        try await Task.sleep(nanoseconds: lag(3_000_000_000))          // teleport + load
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
    func doMatchmaking() async throws {
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
    func readInputBox(below codeLine: OCR.Line, above submit: OCR.Line) async -> String {
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
    func closeMatchmakingPopups() async {
        guard let img = try? await ScreenCapture.captureRoblox(),
              let lines = try? OCR.read(img, region: Region.centerPopup) else { return }
        if let cancel = lines.first(where: { OCR.norm($0.text) == "cancel" }) {
            say("Closing matchmaking popup")
            await input.click(cancel.center)
        }
    }

    /// After submitting: wait for the stage to actually load (vote box, wave counter or stage title).
    /// If nothing loads within the match timeout, back out and retry the whole loop.
    func doVote() async throws {
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
}
