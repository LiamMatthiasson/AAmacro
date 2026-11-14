import Foundation
import CoreGraphics
import AppKit

/// Dungeon mode, step 1: watch a run you play yourself and write down what you did.
/// LISTEN-ONLY: nothing here clicks, types or moves the camera.
extension MacroEngine {

    /// ~/Desktop/AAMacro/dungeon (next to the logs folder).
    static var dungeonDir: URL {
        let d = DebugLog.dir.deletingLastPathComponent().appendingPathComponent("dungeon")
        try? FileManager.default.createDirectory(at: d.appendingPathComponent("runs"), withIntermediateDirectories: true)
        return d
    }

    /// "Watch my dungeon" button: press before you start the dungeon, press again (or F6) after it ends.
    func toggleDungeonWatch() {
        if dungeonWatching { dungeonTask?.cancel(); return }          // the task saves on its way out
        guard state == .idle else { say("🏰 Stop the macro first — watching is for runs you play yourself"); return }
        guard Permissions.screenRecording else { say("⚠️ Screen Recording permission missing — can't watch"); return }
        let l = TeachListener(); l.start()
        guard l.isListening else { say("⚠️ Can't watch your input (Accessibility / Input Monitoring)"); return }
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
        let id = f.string(from: Date())
        let folder = Self.dungeonDir.appendingPathComponent("runs").appendingPathComponent(id)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let upKey = (store?.settings.upgradeKey ?? "r").lowercased()
        dungeonWatching = true
        dungeonStatus = "watching…"
        say("🏰 Watching your dungeon run. Play normally. If a spawn is far from the lane, walk with RIGHT-clicks (those can be replayed; W/A/S/D can't). Upgrade by clicking a unit and pressing \(upKey.uppercased()). Press Stop & save (or F6) when the run ends.")
        dungeonTask = Task { [weak self] in
            guard let self else { l.stop(); return }
            await self.watchDungeon(listener: l, id: id, folder: folder, upKey: upKey)
            self.dungeonWatching = false
            self.dungeonTask = nil
        }
    }

    /// The watch loop. Twice a second: keep the newest frames, work out which screen is up,
    /// and write down any clicks and keys since the last look.
    private func watchDungeon(listener l: TeachListener, id: String, folder: URL, upKey: String) async {
        let began = Date()
        var run = DungeonRun(id: id, startedAt: began)
        // The last few frames, so a click can be matched with the screen from just BEFORE it.
        var frames: [(img: CGImage, at: Date)] = []
        var screen = DungeonScreen.other
        var lastClassify = Date.distantPast
        var menuStreak = 0
        var won = 0
        var shots = 0
        var match: DungeonMatchLog?
        var units: [(slot: Int, at: NormPoint)] = []
        var selected: Int?
        var lastRight = Date.distantPast
        var lastRightAt: Date?
        var walkEnd: CGImage?

        func rel(_ d: Date) -> Double { (d.timeIntervalSince(began) * 10).rounded() / 10 }

        func saveShot(_ img: CGImage, _ label: String) -> String {
            let name = String(format: "%04d-%@.jpg", Int(rel(Date())), label)
            let rep = NSBitmapImageRep(cgImage: img)
            try? rep.representation(using: .jpeg, properties: [.compressionFactor: 0.6])?
                .write(to: folder.appendingPathComponent(name))
            return name
        }

        func frameBefore(_ t: Date) -> CGImage? {
            (frames.last { $0.at < t } ?? frames.first)?.img
        }

        func closeMatch(_ outcome: MatchOutcome) {
            guard var m = match else { return }
            m.outcome = outcome
            m.endT = rel(Date())
            run.matches.append(m)
            if outcome == .victory { won += 1 }
            let places = m.steps.filter { $0.kind == .place }.count
            let ups = m.steps.reduce(0) { $0 + ($1.kind == .upgrade ? $1.times : 0) }
            say("🏰 Match \(m.index) (\(m.map)) ended: \(outcome.rawValue) — \(m.walk.count) walk clicks, \(places) placements, \(ups) upgrades")
            match = nil; units = []; selected = nil; lastRightAt = nil; walkEnd = nil
            Self.saveDungeonRun(run, in: folder)
        }

        while !Task.isCancelled {
            let now = Date()
            // In menus a click low on the screen is a menu click, not a hotbar unit pick.
            l.hotbarClicksSelect = (match != nil)
            if let img = try? await ScreenCapture.captureRoblox() {
                frames.append((img, Date()))
                if frames.count > 3 { frames.removeFirst() }
            }

            // Which screen is this? (a fast read every 1.5 s)
            if now.timeIntervalSince(lastClassify) > 1.5, let img = frames.last?.img {
                lastClassify = now
                let lines = (try? OCR.read(img, fast: true)) ?? []
                let seen = DungeonVocab.screen(lines: lines, wave: Self.readWave(img))
                switch seen {
                case .results:
                    menuStreak = 0
                    if match != nil { closeMatch(DungeonVocab.outcome(lines)) }
                case .match:
                    menuStreak = 0
                    if match == nil {
                        let title = ((try? OCR.read(img, region: Region.stageTitle)) ?? []).map(\.text).joined(separator: " ")
                        let raw = Self.mapName(fromTitle: title)
                        let name = raw.isEmpty ? "unknown" : (store?.canonicalName(raw) ?? raw)
                        match = DungeonMatchLog(index: run.matches.count + 1, floor: won + 1, map: name,
                                                title: title, startT: rel(now))
                        _ = l.take(olderThan: 0)                       // clicks from the menus aren't placements
                        say("🏰 Match \(run.matches.count + 1) started: \(name) (floor \(won + 1))")
                    }
                case .path, .shop, .relic:
                    menuStreak += 1
                    // Back on a menu twice in a row with a match still open: its end screen was missed.
                    if match != nil, menuStreak >= 2 { closeMatch(.unknown) }
                case .other:
                    break
                }
                if seen != screen {
                    screen = seen
                    dungeonStatus = "watching · \(seen.rawValue) · floor \(won + 1) · \(run.decisions.count) choices, \(run.matches.count) matches"
                }
            }

            // The view where a right-click walk ended: a still frame after the last walk click.
            if match != nil, units.isEmpty, lastRightAt != nil, now.timeIntervalSince(lastRight) > 1.5,
               let img = frames.last?.img { walkEnd = img }

            // Placements (a slot key or hotbar click, then a click on the map).
            let ready = l.take(olderThan: 0.6)
            if match != nil {
                for c in ready {
                    var confirmed = false, refused = false
                    for _ in 0..<3 where !confirmed && !refused {
                        if let img = try? await ScreenCapture.captureRoblox() {
                            let r = Self.readAfterClick(img)
                            confirmed = r.panel
                            refused = r.failed || r.limit || r.noYen
                        }
                        if !confirmed && !refused { try? await Task.sleep(nanoseconds: 400_000_000) }
                    }
                    if refused {
                        say(String(format: "🏰 Slot %d click at (%.3f, %.3f) was refused by the game — not saved", c.slot, c.at.x, c.at.y))
                        continue
                    }
                    if units.isEmpty, let w = walkEnd, var m = match, !m.walk.isEmpty {
                        m.walkEndShot = saveShot(w, "walk-end-\(m.index)")
                        match = m
                    }
                    let pre = frameBefore(c.time)
                    units.append((c.slot, c.at))
                    selected = units.count - 1
                    let step = DungeonStep(t: rel(c.time), kind: .place, slot: c.slot, at: c.at, unit: units.count - 1,
                                           times: 1, wave: pre.flatMap { Self.readWave($0) },
                                           yen: pre.flatMap { Self.readYen($0) }, confirmed: confirmed)
                    match?.steps.append(step)
                    say(String(format: "🏰 #%d: slot %d at (%.3f, %.3f)%@", units.count, c.slot, c.at.x, c.at.y,
                               confirmed ? " ✓" : " (no panel seen — kept)"))
                }
            }

            // Everything else, in the order it happened.
            while l.cursor < l.events.count {
                let (ev, t) = l.events[l.cursor]
                l.cursor += 1
                if var m = match {
                    switch ev {
                    case .right(let p):
                        guard units.isEmpty else { break }             // after placing: not part of the walk
                        if let prev = lastRightAt { m.walkGaps.append(t.timeIntervalSince(prev)) }
                        m.walk.append(p)
                        lastRightAt = t; lastRight = t
                    case .left(let p):
                        // Clicking near a unit you placed = selecting it for upgrades.
                        var best: Int?
                        var bestD = 0.045
                        for (i, u) in units.enumerated() {
                            let d = hypot(u.at.x - p.x, u.at.y - p.y)
                            if d < bestD { bestD = d; best = i }
                        }
                        if let best { selected = best }
                    case .key(let k):
                        if k == upKey, let u = selected, u < units.count {
                            if let last = m.steps.last, last.kind == .upgrade, last.unit == u {
                                m.steps[m.steps.count - 1].times += 1
                            } else {
                                let img = frames.last?.img
                                m.steps.append(DungeonStep(t: rel(t), kind: .upgrade, slot: units[u].slot, at: units[u].at,
                                                           unit: u, times: 1, wave: img.flatMap { Self.readWave($0) },
                                                           yen: nil, confirmed: true))
                            }
                        } else if units.isEmpty, ["w", "a", "s", "d"].contains(k) {
                            m.usedMoveKeys = true
                        }
                    case .slotKey:
                        break
                    }
                    match = m
                } else if case .left(let p) = ev, let img = frameBefore(t) {
                    // A menu click: what was on offer, and what did you take?
                    let lines = (try? OCR.read(img)) ?? []
                    let options = DungeonVocab.hits(in: lines)
                    func dist(_ line: OCR.Line) -> Double { hypot(Double(line.box.midX) - p.x, Double(line.box.midY) - p.y) }
                    var under = lines.first { $0.box.insetBy(dx: -0.015, dy: -0.015).contains(CGPoint(x: p.x, y: p.y)) }
                    if under == nil, let near = lines.min(by: { dist($0) < dist($1) }), dist(near) < 0.08 { under = near }
                    shots += 1
                    let kind = DungeonVocab.screen(lines: lines, wave: nil)
                    let d = DungeonDecision(
                        t: rel(t), screen: kind, floor: won + 1, options: options,
                        picked: DungeonVocab.attribute(click: p, options: options),
                        click: p, clickedText: under?.text ?? "",
                        allText: lines.prefix(120).map { DungeonText(text: $0.text, x: Double($0.box.midX), y: Double($0.box.midY)) },
                        shot: shots <= 600 ? saveShot(img, "click-\(kind.rawValue)") : nil)
                    run.decisions.append(d)
                    if !d.picked.isEmpty {
                        var offered: [String] = []
                        for o in options where !offered.contains(o.text) { offered.append(o.text) }
                        say("🏰 Choice: [\(offered.joined(separator: ", "))] → \(d.picked.joined(separator: " + "))")
                    }
                    Self.saveDungeonRun(run, in: folder)
                }
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        // Stopped: save the run and add it to what's known.
        l.stop()
        if match != nil { closeMatch(.unknown) }
        Self.saveDungeonRun(run, in: folder)
        let k = Self.rebuildDungeonKnowledge()
        let wins = run.matches.filter { $0.outcome == .victory }.count
        say("🏰 Saved this run: \(run.decisions.count) menu clicks, \(run.matches.count) matches (\(wins) won) → dungeon/runs/\(id)")
        say("🏰 Known so far: \(k.runs) runs, \(k.decisions) readable choices, plans for \(k.plans.count) maps")
        if !k.keyWalkMaps.isEmpty {
            say("🏰 Walked with W/A/S/D on: \(k.keyWalkMaps.joined(separator: ", ")) — use right-click walks there next time so they can be replayed")
        }
        dungeonWatching = false
        refreshDungeonStatus()
    }

    static func saveDungeonRun(_ run: DungeonRun, in folder: URL) {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]; enc.dateEncodingStrategy = .iso8601
        try? enc.encode(run).write(to: folder.appendingPathComponent("run.json"), options: .atomic)
    }

    /// Reads every saved run and writes knowledge.json from scratch (so a deleted run is forgotten).
    @discardableResult
    static func rebuildDungeonKnowledge() -> DungeonKnowledge {
        let fm = FileManager.default
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let folders = (try? fm.contentsOfDirectory(at: dungeonDir.appendingPathComponent("runs"), includingPropertiesForKeys: nil)) ?? []
        let runs = folders.compactMap { f -> DungeonRun? in
            guard let data = try? Data(contentsOf: f.appendingPathComponent("run.json")) else { return nil }
            return try? dec.decode(DungeonRun.self, from: data)
        }
        let k = DungeonLearner.build(from: runs)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(k).write(to: dungeonDir.appendingPathComponent("knowledge.json"), options: .atomic)
        return k
    }

    /// One line for the dock: what has been learned so far.
    func refreshDungeonStatus() {
        guard !dungeonWatching else { return }
        guard let data = try? Data(contentsOf: Self.dungeonDir.appendingPathComponent("knowledge.json")),
              let k = try? JSONDecoder().decode(DungeonKnowledge.self, from: data), k.runs > 0 else {
            dungeonStatus = "no runs watched yet"
            return
        }
        dungeonStatus = "\(k.runs) runs watched · \(k.decisions) choices · \(k.plans.count) map plans"
    }
}
