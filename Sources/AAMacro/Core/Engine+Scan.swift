import Foundation
import CoreGraphics

/// Map scans: test-placing a grid of spots, learning the lane, reading the stage title / map name.
extension MacroEngine {
    func scanEnemies(_ img: CGImage) {
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

    func addEnemySightings(_ lines: [OCR.Line]) {
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
    func learnLane(seconds: Double) async {
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

    func runScan(name typed: String) async throws {
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
    func learnMapNow() async throws {
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
        profile.ground += ground; profile.hill += hill
        if profile.lane.count < enemyLane.count { profile.lane = enemyLane }
        if profile.referenceImage == nil, let img = try? await ScreenCapture.captureRoblox() {
            profile.referenceImage = store?.saveReference(img, name: "scan-\(name)")
        }
        activeProfile = profile
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

    func runTestScan(name typed: String) async throws {
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
    func waitForTitle() async -> String {
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

    func probeGrid(slot: Int, label: String, hill: Bool) async throws -> [NormPoint] {
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

    /// Test-places the unit at p and sells it again.
    /// true = placed (spot is good), false = didn't place (spot is bad), nil = can't keep testing.
    func testPlaceAndSell(slot: Int, at p: NormPoint) async -> Bool? {
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
    func saveScanPicture(_ p: MapProfile, over img: CGImage) {
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
}
