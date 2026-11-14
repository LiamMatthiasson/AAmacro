import Foundation
import CoreGraphics

/// Auto placement: the Steps list, choosing spots for each slot (taught → learned → scan → live search) and what each match teaches the map.
extension MacroEngine {

    /// Loads this map's scan and lines it up with the current view (camera check).
    func loadProfileForMatch() async {
        activeProfile = nil
        guard let prof = store?.profile(forTitle: currentTitle) else { return }
        if let file = prof.referenceImage, let ref = store?.reference(file),
           let cur = try? await ScreenCapture.captureRoblox(),
           let m = Matcher.viewShift(reference: ref, current: cur) {
            if m.score > 0.25 {
                // Weather, other players' units and effects change the picture a lot even when the
                // camera is the same — throwing the scan away made every repeat map start from zero.
                // Use it anyway; every spot is still checked before and after clicking.
                say(String(format: "View looks different from the %@ scan (difference %.2f — weather/units) — using the scan anyway, checking each spot", prof.name, m.score))
                activeProfile = prof
                return
            }
            if abs(m.dx) > 0.025 || abs(m.dy) > 0.035 {
                // The camera reset gives the same view every time; a shift this big is the
                // matcher being fooled by weather/units. (A +9 % "shift" moved every spot off target.)
                say(String(format: "Camera check vs %@ scan: ignoring a shift of (%+.3f, %+.3f) — too big to be real", prof.name, m.dx, m.dy))
            } else {
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
    func cleanTaughtFromBad() {
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

    /// Every real placement teaches the map: good spots are added, clicked-and-failed spots are
    /// remembered as bad. Creates the map's entry if it has none yet.
    func learnSpot(_ p: NormPoint, hill: Bool, good: Bool) {
        let name = activeProfile?.name ?? store?.canonicalName(Self.mapName(fromTitle: currentTitle)) ?? Self.mapName(fromTitle: currentTitle)
        guard !name.isEmpty else { return }
        var prof = activeProfile ?? store?.profiles.first(where: { $0.name == name })
            ?? MapProfile(name: name, ground: [], hill: [], lane: enemyLane, scannedAt: Date())
        let q = p
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
        if prof.lane.count < enemyLane.count { prof.lane = enemyLane }
        activeProfile = prof
        store?.saveProfile(prof)
    }

    /// Placement candidates from a saved scan: placeable for this unit type, off the lane,
    /// not near units already placed, most lane in range first.
    func profileSpots(_ prof: MapProfile, hill: Bool, range: Double, avoid: [NormPoint]) -> [NormPoint] {
        let aspect = Double(WindowManager.lockedSize.height / WindowManager.lockedSize.width)
        func d(_ a: NormPoint, _ b: NormPoint) -> Double { let dx = a.x - b.x, dy = (a.y - b.y) * aspect; return (dx * dx + dy * dy).squareRoot() }
        let lane = prof.lane.isEmpty ? enemyLane : prof.lane
        let bad = (hill ? prof.badHill : prof.badGround) ?? []
        let pool = (hill ? prof.hill : prof.ground).filter { p in
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

    /// Plays a map with no recording, following the Steps box (or Place order + priority settings).
    func autoPlay() async throws {
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
            enemyLane = prof.lane
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
                // At most 3 minutes per upgrade step, so a slow upgrade (waiting on money) can't hold
                // up placing the rest of the team. Leftover levels are done after the last step.
                upgradeDeadline = Date().addingTimeInterval(180)
                let phantoms = try await upgradeStep(slot: slot, levels: levels)
                if let d = upgradeDeadline, Date() > d { say("Upgrade step took 3 min — moving on, finishing it after the last step") }
                upgradeDeadline = nil
                for sl in phantoms {
                    autoFull.remove(sl)
                    if try await placeSlot(sl) { try await upgradeStep(slot: sl, levels: levels) }
                    else if !autoFull.contains(sl) { unplaced.append(sl) }
                }
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

    /// Returns the slots whose "placed" unit turned out not to exist (so they get placed again).
    @discardableResult
    func upgradeStep(slot: Int?, levels: Int?) async throws -> [Int] {
        var phantomSlots: [Int] = []
        let s = store?.settings ?? MacroSettings()
        let targets = autoPlaced.indices.filter { autoPlaced[$0].slot != 0 && (slot == nil || autoPlaced[$0].slot == slot) }
            .sorted { a, b in
                let pa = s.prioritySlots.firstIndex(of: autoPlaced[a].slot) ?? 99
                let pb = s.prioritySlots.firstIndex(of: autoPlaced[b].slot) ?? 99
                return (pa, a) < (pb, b)
            }
        if targets.isEmpty { say("Nothing placed for slot \(slot.map(String.init) ?? "any") yet — skipping upgrade"); return [] }
        for i in targets where !autoMaxed.contains(i) {
            var misses = 0
            var remaining = levels ?? 99
            while remaining > 0 {
                try Task.checkCancellation()
                if let d = upgradeDeadline, Date() > d { return phantomSlots }
                if try await checkResults() { return phantomSlots }
                try await handleCards()
                // One panel open, R pressed repeatedly (waits for money between levels).
                switch await upgradeUnit(slot: autoPlaced[i].slot, at: autoPlaced[i].at, times: remaining) {
                case .some(true):
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
        return phantomSlots
    }

    /// Places one copy of a slot, persistently: every round it gathers candidates from ALL sources
    /// (saved scan, live overlay, spots beside where enemies walk, a grid over the map), skips
    /// spots already tried or known bad, and tries them until one sticks — for up to 4 minutes.
    /// Every real attempt teaches the map (good spots saved, clicked-and-failed spots remembered).
    /// Returns false if the slot is full or nothing worked in time (it gets retried later).
    func placeSlot(_ slot: Int) async throws -> Bool {
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
                // Waiting for money counts against this slot's time: if it runs out, the slot is
                // retried later instead of the whole step list stopping here.
                let what = "\(price)¥ for slot \(slot)"
                do {
                    _ = try await poll(timeout: max(5, deadline.timeIntervalSinceNow), what: what) { img -> Bool? in
                        self.enoughYen(img, price)
                    }
                } catch MacroError.timedOut(let w) where w == what {
                    say("Slot \(slot): still can't afford it — moving on, will retry later")
                    return false
                }
            }
            // A taught spot for this copy that hasn't been tried yet? Go straight to it — no need for
            // the full overlay read (~2 s); placeOnce still checks the circle, limit and counter.
            let copyNo = autoPlaced.filter { $0.slot == slot }.count
            let ownTaught = (activeProfile?.taught ?? []).filter { $0.slot == slot }
            let freshTaught = (ownTaught.isEmpty ? (activeProfile?.learned ?? []).filter { $0.slot == slot } : ownTaught).map(\.at)
                .dropFirst(copyNo).contains { t in !near(tried, t, 0.02) && !near(blockedGround + blockedHill, t, 0.012) }
            var overlay = OverlayRead()
            if !(round == 1 && freshTaught) { overlay = await readOverlay(slot: slot) }
            if overlay.full { autoFull.insert(slot); say("Slot \(slot) is at its placement limit"); return false }
            let planner = overlay.planner
            plannerUsed = planner ?? plannerUsed
            let hill = s.hillSlots.isEmpty ? (planner?.isHillOverlay ?? false) : s.hillSlots.contains(slot)
            let taken = autoPlaced.map(\.at)
            // Unplaceable ground comes in patches (a building, a cliff, the lane edge), so a failed
            // spot rules out the area around it — "dead zones" — not just the exact point.
            let savedBad = (hill ? activeProfile?.badHill : activeProfile?.badGround) ?? []
            let deadZones = hill ? blockedHill : blockedGround

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
                    + (activeProfile?.hill ?? [])
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
            let suspects = ((hill ? activeProfile?.suspectHill : activeProfile?.suspectGround) ?? [])
            if hill {
                // Hill: keep the order, but spots that failed in an earlier match go last.
                let ok = unique.filter { p in !suspects.contains { abs($0.x - p.x) < 0.02 && abs($0.y - p.y) < 0.028 } }
                unique = ok + unique.filter { p in !ok.contains { $0.x == p.x && $0.y == p.y } }
            }
            if !hill || gridMode {
                let lanePts = laneReference(planner: planner)
                if !lanePts.isEmpty {
                    let proven = Set((activeProfile?.ground ?? []).map { "\(Int($0.x * 200)),\(Int($0.y * 200))" })
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
                    if let pl = plannerUsed { for c in pl.pathCells(near: target, range: range) { autoCovered[c, default: 0] += 1 } }
                    return true
                case .limitReached:
                    autoFull.insert(slot)
                    return false
                case .cantAfford:
                    needMoney = true
                case .failed(let reason):
                    guard reason == .clicked else { continue }        // interrupted / no capture: says nothing about the spot
                    let wasTaught = taughtAll.contains { abs($0.x - target.x) < 0.001 && abs($0.y - target.y) < 0.001 }
                    matchTries.append((slot, target, false))
                    // Clicked and nothing placed: remember it for future matches (suspect after
                    // once, never tried again after twice) — unless it's one of your taught spots.
                    if !wasTaught { learnSpot(target, hill: hill, good: false) }
                    // Either way, don't try it again this match (another player's unit, most likely).
                    if hill { blockedHill.append(target) } else { blockedGround.append(target) }
                    if !wasTaught { failedHere.append(target) }
                    continue
                }
                break
            }
            if needMoney { try await sleepWatchingCards(3) }
        }
        say("⚠️ Couldn't place slot \(slot) in \(firstSearch ? "90 s (new map, hill search)" : "4 minutes") — carrying on, will retry it later")
        return false
    }

    /// Remembers where the n-th copy of a slot actually went down (automatic layout learning).
    func saveLearned(slot: Int, copy: Int, at p: NormPoint) {
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

    /// Every ~3.5 % over the playable map (not the HUD) — the last resort for ground units.
    func denseGrid() -> [NormPoint] {
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
    func laneReference(planner: AutoPlanner?) -> [NormPoint] {
        var pts: [NormPoint] = []
        if let prof = activeProfile, prof.lane.count >= 25 { pts = prof.lane }
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
    func ringsAround(_ centers: [NormPoint], radii: [Double]) -> [NormPoint] {
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
    func probeSpots(avoid: [NormPoint]) -> [NormPoint] {
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
}
