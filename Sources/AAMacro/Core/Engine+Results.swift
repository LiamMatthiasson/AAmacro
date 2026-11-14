import Foundation
import CoreGraphics

/// End of match: reading VICTORY / DEFEAT, pearls and secrets, clicking back to the lobby, the per-match report.
extension MacroEngine {

    /// Wait for the results screen and go back to the lobby.
    /// Waits for the match to end, then clicks through it: Next → any item drops → Return to lobby.
    /// Every click is followed by a fresh look at the screen, so extra drop screens or lag
    /// just mean a few more clicks.
    func doResults() async throws {
        say("Waiting for the match to end")
        _ = try await poll(timeout: 3600, what: "end of match") { [self] img in endScreen(in: img) }
        let outcome = lastOutcome
        switch outcome {
        case .victory: say("Result: VICTORY")
        case .defeat:  say("Result: DEFEAT")
        case .unknown: say("Result: panel seen but couldn't read VICTORY or DEFEAT — counted as unknown (screenshot saved)")
        }
        writeMatchReport(outcome: outcome)
        lastMatchEnded = Date()
        secretFoundThisMatch = false; rewardSeen = []; savedRewardShot = false
        var pearls = 0
        if let img = try? await ScreenCapture.captureRoblox(), let p = Self.pearlsEarned(img) {
            pearls = p
            sessionPearls += p
            say("Summer Pearls this match: +\(p) — session total \(sessionPearls)")
        }
        // Per-map record + how far it got, so weak maps stand out (give them their own [Map] steps).
        if let img = try? await ScreenCapture.captureRoblox(), let lines = try? OCR.read(img, fast: true) {
            let wave = lines.first { OCR.norm($0.text).contains("wavescompleted") }
                .flatMap { l in l.text.split(separator: ":").last.flatMap { Int($0.filter(\.isNumber)) } }
                .flatMap { $0 > 0 ? $0 : nil }
            let name = activeProfile?.name ?? store?.canonicalName(Self.mapName(fromTitle: currentTitle)) ?? ""
            if !name.isEmpty, outcome != .unknown, var prof = store?.profiles.first(where: { $0.name == name }) {
                if outcome == .victory { prof.wins = (prof.wins ?? 0) + 1 } else { prof.losses = (prof.losses ?? 0) + 1 }
                store?.saveProfile(prof)
                if activeProfile?.name == name { activeProfile = prof }
                say("\(name): \(outcome == .victory ? "won" : "lost")\(wave.map { " at wave \($0)" } ?? "") — record \(prof.wins ?? 0)W / \(prof.losses ?? 0)L")
            } else if let wave {
                say("Waves completed: \(wave)")
            }
        }
        recordLifetime(outcome: outcome, pearls: pearls)
        await DebugLog.snapshot(outcome.rawValue)

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
        // A portal or unit drop can also land a moment AFTER the teleport, as a lobby popup.
        if leftStage {
            for _ in 0..<3 {
                if let img = try? await ScreenCapture.captureRoblox() { checkForSecret(img) }
                try? await Task.sleep(nanoseconds: lag(1_200_000_000))
            }
        }
        if !rewardSeen.isEmpty, !secretFoundThisMatch {
            say("Reward screens: \(rewardSeen.sorted().joined(separator: " · "))")
        }

        sawResultPanel = false
        if teachNowActive, !teachNextMatch, manualTeachTask == nil { teachNowActive = false }
        if !leftStage { say("⚠️ Didn't see the lobby after the results — recovering") }

        inStage = false
        recoverAttempts = 0
        runsCompleted += 1
        switch outcome {
        case .victory: wins += 1; lossStreak = 0
        case .defeat:  losses += 1; lossStreak += 1
        case .unknown: unknowns += 1; lossStreak += 1      // treated as a loss for the safety stop only
        }
        runDeadline = nil
        if let limit = store?.settings.stopAfterLosses, limit > 0, lossStreak >= limit {
            say("⚠️ Lost \(lossStreak) in a row — stopping so it doesn't keep failing. Check the logs.")
            await DebugLog.snapshot("loss-streak")
            stop(); return
        }
        lastOutcome = .unknown
        say("Run \(runsCompleted) done")
        if let max = store?.settings.maxRuns, max > 0, runsCompleted >= max { stop(); return }
        state = leftStage ? .lobby : .recovering
    }

    /// Log lines + picture describing how placement went this match.
    func writeMatchReport(outcome: MatchOutcome) {
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
        say("Match summary (\(outcome.rawValue)): " + parts.joined(separator: " · ")
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

    func checkResults() async throws -> Bool {
        guard let img = try? await ScreenCapture.captureRoblox() else { return false }
        return endScreen(in: img) != nil
    }

    /// What the end-of-match flow is showing right now. The flow is:
    ///   VICTORY!!! / DEFEAT panel → "Next" → (item drop screens) → "Return to lobby" | "Replay"
    enum EndScreen { case result(next: NormPoint?), drops, lobbyButton(NormPoint) }

    static let winWords  = ["victory", "youwon", "cleared", "stagecleared"]
    static func looksLikeNext(_ t: String) -> Bool {
        let n = OCR.norm(t)
        return n == "next" || n == "next" || n == "nex" || n == "next>" || (n.count <= 5 && n.hasPrefix("nex"))
    }
    static let lossWords = ["defeat", "youlost", "gameover", "failed", "youdied"]

    /// The in-match Settings menu also has a "Return to Lobby" button (next to "Teleport back to
    /// Spawn" and "Exit the game and return back to the lobby"). That is NOT the results screen —
    /// clicking it once made the macro walk out of a match 20 s in.
    static func isSettingsMenu(_ t: [String]) -> Bool {
        t.contains { $0.contains("teleportbacktospawn") || $0.contains("exitthegame") || $0.contains("autoskip")
                     || $0.contains("useifstuck") || $0.contains("disableautoopen") }
    }

    func endScreen(in img: CGImage) -> EndScreen? {
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
        var carefulLoss = false
        if !isWin, panelLines >= 2, !t.contains(where: { w in Self.lossWords.contains { w.contains($0) } }) {
            // The quick read missed the big stylised word: read that spot carefully, and check its
            // colour (VICTORY is gold, DEFEAT is red). A win was once logged as a loss here.
            let area = CGRect(x: 0.25, y: 0.26, width: 0.32, height: 0.11)
            let careful = ((try? OCR.read(img, region: area)) ?? []).map { OCR.norm($0.text) }
            if careful.contains(where: { w in Self.winWords.contains { w.contains($0) } }) { isWinCareful = true }
            else if careful.contains(where: { w in Self.lossWords.contains { w.contains($0) } }) { carefulLoss = true }
            else if let c = Matcher.averageColor(in: img, rect: CGRect(x: 0.34, y: 0.29, width: 0.13, height: 0.045)) {
                if c.g > 0.45, c.r > 0.55, c.g > c.r * 0.6, c.b < c.g * 0.8 { isWinCareful = true }      // gold
                else if c.r > 0.45, c.g < c.r * 0.6, c.b < c.r * 0.6 { carefulLoss = true }              // red
            }
        }
        let lossSeen = t.contains { w in Self.lossWords.contains { w.contains($0) } } || carefulLoss
        let isLoss = !isWinCareful && (lossSeen || (!isWin && panelLines >= 2))
        if isWin || isWinCareful || isLoss {
            // Three answers, not two: a panel with neither word readable is "unknown", not a loss.
            if isWin || isWinCareful { lastOutcome = .victory }
            else if lossSeen { lastOutcome = .defeat }
            else { lastOutcome = .unknown }
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

    /// Words that mark a line on a reward screen as an item drop worth writing down.
    static let dropWords = ["secret", "mythic", "legendary", "portal", "obtained", "yougot", "youreceived"]

    /// True for text that is describing a *chance* of something ("Secret Drop Rate: +125.0%",
    /// "Secret Portal Rate Boost") rather than an item you actually got. Those live on the
    /// level-modifier panel and are on screen all match.
    static func isRateText(_ raw: String) -> Bool {
        if raw.contains("%") { return true }
        let t = OCR.norm(raw)
        return ["rate", "boost", "chance", "luck", "odds", "bonus"].contains { t.contains($0) }
    }

    /// Reward screens: write down every drop-shaped line, and if any item is marked "Secret",
    /// count it, screenshot it and ping Discord (once per match).
    ///
    /// Read at full accuracy, not `fast`: a real secret portal went by unnoticed on the fast
    /// reader, which garbles the small stylised rarity text under an item's name.
    func checkForSecret(_ img: CGImage) {
        guard let lines = try? OCR.read(img) else { return }
        // Everything right of 0.84 is the level-modifier panel, never a drop.
        for l in lines where l.box.midX < 0.84 {
            let t = OCR.norm(l.text)
            guard Self.dropWords.contains(where: { t.contains($0) }), !Self.isRateText(l.text) else { continue }
            let clean = l.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard clean.count >= 3, rewardSeen.insert(clean).inserted else { continue }
            DebugLog.append(String(format: "   reward screen: \"%@\" at (%.3f, %.3f)", clean, l.box.midX, l.box.midY))
            if !savedRewardShot {
                savedRewardShot = true
                DebugLog.savePNG(img, name: "\(DebugLog.stamp())-reward-\(Self.mapName(fromTitle: currentTitle)).png")
            }
        }
        guard !secretFoundThisMatch else { return }
        let hit = lines.first { l in
            let t = OCR.norm(l.text)
            guard t.contains("secret"), l.box.midX < 0.84 else { return false }
            return !Self.isRateText(l.text)
        }
        guard let hit else { return }
        secretFoundThisMatch = true
        sessionSecrets += 1
        store?.updateStats { $0.secrets += 1 }
        let map = Self.mapName(fromTitle: currentTitle)
        // Whatever else is on the screen names the item ("Explosion Mage\'s Portal").
        let nearby = lines.filter { abs($0.box.midY - hit.box.midY) < 0.10 && $0.box.midX < 0.84 }
            .sorted { $0.box.midY < $1.box.midY }
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 3 }
        let what = nearby.isEmpty ? hit.text : nearby.joined(separator: " · ")
        say("✦✦ SECRET on the reward screen (\"\(what)\") — screenshot saved")
        DebugLog.savePNG(img, name: "\(DebugLog.stamp())-SECRET-\(map).png")
        notify("✦ **Secret drop!** on \(map.isEmpty ? "a map" : map) — \(what) (secrets this session: \(sessionSecrets))", image: img)
    }

    func matchEndedCheck(_ img: CGImage) throws {
        guard inStage, state != .results, Date().timeIntervalSince(lastEndCheck) > 4 else { return }
        lastEndCheck = Date()
        if endScreen(in: img) != nil {
            say("Match is over — stopping what I was doing")
            throw MacroError.timedOut("match ended")
        }
    }
}
