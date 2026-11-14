import Foundation
import CoreGraphics

/// Portal mode groundwork: right-click walks and strictly taught plans.
extension MacroEngine {

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
    func waitUntilStill(timeout: Double) async {
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
}
