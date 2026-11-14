import Foundation
import CoreGraphics

/// Pure screen readers: given a frame, what does the game show? No clicking, no state.
extension MacroEngine {
    static func readAfterClick(_ img: CGImage) -> AfterClick {
        var r = AfterClick()
        guard let lines = try? OCR.read(img, region: CGRect(x: 0, y: 0.28, width: 0.92, height: 0.64)) else { return r }
        let panelWords = ["upgrade", "upg", "targeting", "target", "first", "strongest", "weakest", "last",
                          "damage", "range", "spa", "totaldamage"]
        var hits = 0
        for l in lines {
            let t = OCR.norm(l.text)
            if l.box.midX < 0.48 {
                if t.hasPrefix("sell") { r.panel = true }
                if panelWords.contains(where: { t.hasPrefix($0) }) { hits += 1 }
            }
            if t.contains("cannotplacemore") || t.contains("placemorethan") || t.contains("uniqueunits")
                || t.contains("maynotbeplaced") || t.contains("othersofitskind") { r.limit = true }
            else if t.contains("cannotplace") || t.contains("cantplace") || t.contains("invalidplacement")
                || t.contains("invalidposition") || t.contains("toocloseto") || t.contains("mustbeplaced")
                || t.contains("cannotbeplaced") || t.contains("unabletoplace") || t.contains("placementinvalid") { r.failed = true }
            if t.contains("notenough") || t.contains("cannotafford") || t.contains("insufficient") || t.contains("needmore") { r.noYen = true }
        }
        if hits >= 2 { r.panel = true }
        return r
    }

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


    /// Reads "placed/limit" above a slot (only shown while holding that unit).
    /// Each slot's placement limit as first read this session ("0/4" → 4). A later reading with a
    /// different limit ("10/10" for a 4-limit unit) is a misread and is ignored.
    static var knownLimits: [Int: Int] = [:]

    static var limitVotes: [Int: [Int: Int]] = [:]

    static func readSlotCounter(_ img: CGImage, slot: Int) -> (placed: Int, limit: Int)? {
        guard let c = readSlotCounterRaw(img, slot: slot) else { return nil }
        if let known = knownLimits[slot] {
            return c.limit == known ? c : nil
        }
        // Not locked yet: count readings; lock once the same limit has been read twice.
        limitVotes[slot, default: [:]][c.limit, default: 0] += 1
        if (limitVotes[slot]?[c.limit] ?? 0) >= 2 { knownLimits[slot] = c.limit }
        return c
    }

    static func readSlotCounterRaw(_ img: CGImage, slot: Int) -> (placed: Int, limit: Int)? {
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

    /// "Not enough yen" type messages.
    /// The game's message when a spot is invalid ("Cannot place here", "Invalid placement",
    /// "Too close to…", "Must be placed on…"). Wording guessed broadly; the limit / yen messages
    /// are checked separately first.
    static func placeFailedMessage(_ img: CGImage) -> Bool {
        guard let lines = try? OCR.read(img, region: CGRect(x: 0.05, y: 0.40, width: 0.85, height: 0.45), fast: true) else { return false }
        return lines.contains { l in
            let t = OCR.norm(l.text)
            guard !t.contains("cannotplacemore"), !t.contains("placemorethan") else { return false }
            return t.contains("cannotplace") || t.contains("cantplace") || t.contains("invalidplacement")
                || t.contains("invalidposition") || t.contains("toocloseto") || t.contains("mustbeplaced")
                || t.contains("cannotbeplaced") || t.contains("unabletoplace") || t.contains("placementinvalid")
        }
    }

    static func notEnoughYenMessage(_ img: CGImage) -> Bool {
        guard let lines = try? OCR.read(img, region: CGRect(x: 0.05, y: 0.40, width: 0.85, height: 0.45), fast: true) else { return false }
        return lines.contains { l in
            let t = OCR.norm(l.text)
            return t.contains("notenough") || t.contains("cannotafford") || t.contains("insufficient") || t.contains("needmore")
        }
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
}
