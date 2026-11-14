import Foundation
import CoreGraphics

/// One placement attempt, the overlay read, upgrades, unit costs and yen.
extension MacroEngine {

    // MARK: - Spawn

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

    func readOverlay(slot: Int) async -> OverlayRead {
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
        guard var base1 = try? await ScreenCapture.captureRoblox() else { return OverlayRead() }
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
        if let h = held1, !lingering, Self.placementLimitMessage(h),
           !(Self.readSlotCounter(h, slot: slot).map { $0.placed < $0.limit } ?? false) {
            await input.key("q")
            return OverlayRead(full: true)
        }
        if let h = held1, let c = Self.readSlotCounter(h, slot: slot) {
            say("Slot \(slot): \(c.placed)/\(c.limit) placed")
            if c.placed >= c.limit {
                await input.key("q")
                return OverlayRead(full: true)
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
              let planner = AutoPlanner(bases: [base1] + [base2].compactMap { $0 }, helds: helds, enemyLane: enemyLane, masks: masks) else { return OverlayRead() }

        let range = store?.settings.autoRangePerSlot[slot] ?? 0.12
        let hs = store?.settings.hillSlots ?? []
        let hill = hs.isEmpty ? planner.isHillOverlay : hs.contains(slot)
        let picks = planner.candidates(range: range, taken: [], covered: [:], hill: hill, maxLaneDistance: 7).map(\.spot)
        if let dbg = planner.debugImage(over: held, picks: picks) {
            DebugLog.savePNG(dbg, name: "\(DebugLog.stamp())-plan-slot\(slot).png")
        }
        return OverlayRead(planner: planner.pathCellCount > 20 ? planner : nil)
    }

    func name(ofSlot slot: Int) async -> String? {
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
    func upgradeViaOverview(slot: Int) async -> Bool? {
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

    func clickUpgrade(in panel: [OCR.Line], nameKey key: String, unitName: String) async -> Bool? {
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
    func upgradeUnit(slot: Int, at p: NormPoint, times: Int = 1) async -> Bool? {
        // We know exactly where it was placed: click it once, keep the panel open, press R.
        let maxLevel = store?.settings.maxLevelPerSlot[slot]
        if let r = await upgrade(at: p, times: times, maxLevel: maxLevel) { return r }
        // Panel wouldn't open (unit hidden behind effects/enemies) → use the F list instead.
        return await upgradeViaOverview(slot: slot)
    }

    /// Why a placement attempt failed. `clicked` = a real click landed and nothing was placed
    /// (the spot itself is bad); the others don't say anything about the spot.
    enum FailReason { case clicked, interrupted, other }
    enum PlaceResult { case placed, failed(FailReason), cantAfford, limitReached }

    /// How many of this slot are on the map right now (press the slot key, read "2/3", cancel).
    /// full = the game refused to let us hold it (limit message) or the counter is at the limit.
    func placedCount(slot: Int) async -> (placed: Int, full: Bool)? {
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
    func placeOnce(slot: Int, at target: NormPoint, requireBlue: Bool = false, trusted: Bool = false,
                           forceTry: Bool = false) async -> PlaceResult {
        if Task.isCancelled { return .failed(.other) }
        let interruptsAtStart = cardInterrupts
        func interrupted() -> Bool { cardInterrupts != interruptsAtStart }

        await WindowManager.focusRoblox()

        // 1) Clean start.
        input.move(Self.park(awayFrom: target))
        try? await Task.sleep(nanoseconds: lag(200_000_000))
        guard var base = try? await ScreenCapture.captureRoblox() else { return .failed(.other) }
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
        guard let held = try? await ScreenCapture.captureRoblox() else { await input.key("q"); return .failed(.other) }
        let counterBefore = Self.readSlotCounter(held, slot: slot)
        if let c = counterBefore, c.placed >= c.limit { await input.key("q"); return .limitReached }
        let heldRead = Self.readAfterClick(held)
        if heldRead.limit && !before.limit && counterBefore == nil { await input.key("q"); return .limitReached }
        if heldRead.noYen && !before.noYen { await input.key("q"); return .cantAfford }
        if interrupted() { await input.key("q"); return .failed(.interrupted) }

        // 3) Hover, then one click.
        input.move(target)
        try? await Task.sleep(nanoseconds: lag(300_000_000))
        if cardsPending != nil || interrupted() {
            await input.key("q")
            cardInterrupts += 1                                            // not the spot's fault
            await yieldToCards()
            return .failed(.interrupted)
        }
        await input.click(target)
        try? await Task.sleep(nanoseconds: lag(650_000_000))
        let after = (try? await ScreenCapture.captureRoblox()).map(Self.readAfterClick) ?? AfterClick()
        if interrupted() { await input.key("q"); return .failed(.interrupted) }
        if after.failed && !before.failed {
            say(String(format: "Slot %d: game says it can't go at (%.3f, %.3f) — remembering it", slot, target.x, target.y))
            await input.key("q"); try? await Task.sleep(nanoseconds: lag(200_000_000))
            return .failed(.clicked)
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
            return .failed(.clicked)
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
        return .failed(.clicked)
    }

    // MARK: - Placement & upgrades

    /// Reads the "1200 ¥" under a hotbar slot (cached for the stage).
    func cost(of slot: Int) async -> Int? {
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

    /// Click the placed unit → the panel opens bottom-left showing "UPG [4]" and
    /// "Upgrade: 7000¥ [R]". Wait until affordable, press R, confirm the level went up.
    /// Returns true = can upgrade further, false = maxed, nil = couldn't open the unit panel.
    @discardableResult
    func upgrade(at p: NormPoint, times: Int, maxLevel: Int?) async -> Bool? {
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

    func yen() async throws -> Int? {
        Self.readYen(try await ScreenCapture.captureRoblox())
    }
    /// For money waits: true once we can afford it. If the counter can't be read for 15 s,
    /// stop waiting and just try (the placement/upgrade check will catch it if we were short).
    func enoughYen(_ img: CGImage, _ price: Int) -> Bool? {
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
}
