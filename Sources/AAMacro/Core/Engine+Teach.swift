import Foundation
import CoreGraphics

/// Teach mode: you place a unit, the macro saves where it went.
extension MacroEngine {

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

    func stopTeachNow() {
        teachNextMatch = false
        if let t = manualTeachTask {
            t.cancel(); manualTeachTask = nil
            say("🎓 Teaching stopped — \(teachSpots.count) spot(s) saved for \(teachName)")
        } else {
            say("🎓 Teach now cancelled (spots already learned stay saved)")
        }
        teachNowActive = false
    }

    func startManualTeach(name: String) {
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
            self.teachName = mapName; self.teachSpots = []
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

    /// Teach mode: instead of picking a spot, ask YOU to place this slot, watch where you click,
    /// confirm it went down (unit panel pops up), save it, and carry on with the steps.
    /// Returns nil if you didn't place it in 3 minutes (the macro then places it itself).
    func teachPlace(_ slot: Int) async throws -> NormPoint? {
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
    func saveTaught(slot: Int, at p: NormPoint) {
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
}
