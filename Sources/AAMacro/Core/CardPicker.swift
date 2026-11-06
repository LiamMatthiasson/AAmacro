import Foundation
import CoreGraphics

/// Picks a weather card when "The weather shifts…" vote appears mid-stage.
/// Cards are never recorded: every time, the macro reads the 3 cards and decides.
///
/// How a card is read (from the real screen):
///   • 3 fixed columns. Each card has a title ("Low Tide"), effect lines, and "Flooded Card".
///   • Card background is tinted green (buff) or red (debuff).
///   • Each effect line has its own color: green = good for you, red = bad, white = neutral
///     (e.g. "+100% SummerPearls").
///
/// Ranking (best → worst):
///   1. Green buff cards — except ones mentioning yen
///   2. Red debuff cards whose red lines are ALL "Enemy Health" / "Enemy Speed"
///   3. Yen buff cards
///   4. Any other debuff (only if nothing else is offered)
/// Within a tier: your Settings priority list, then more SummerPearls %.
enum CardPicker {
    struct Card {
        let title: String
        let text: String
        let redLines: [String]
        let isBuff: Bool
        let center: NormPoint
        /// "+100% SummerPearls" → 100 (tie-breaker: more pearls is better).
        var pearlBonus: Int {
            guard let r = text.range(of: "%\\s*Summer", options: [.regularExpression, .caseInsensitive]) else { return 0 }
            let digits = text[..<r.lowerBound].reversed().prefix { $0.isNumber }
            return Int(String(digits.reversed())) ?? 0
        }
    }

    /// Finds the cards wherever they are: groups the text into columns by horizontal position
    /// (cards are side by side), then reads each column's title, effect lines and colours.
    static func read(_ lines: [OCR.Line], image: CGImage) -> [Card] {
        // Not card text: the header ("The weather shifts…", "Vote ends in 10"), buttons, and
        // health labels ("2.4/2.4") of enemies walking behind the cards.
        let junk = ["weathershifts", "theweather", "shifts", "voteends", "vote", "cancel"]
        let useful = lines.filter { l in
            let n = OCR.norm(l.text)
            return !l.text.allSatisfy(\.isNumber) && n.count >= 2
                && !junk.contains(where: { n == $0 || ($0.count > 5 && n.contains($0)) })
                && l.text.range(of: #"\d/\d"#, options: .regularExpression) == nil
        }
            .sorted { $0.box.midX < $1.box.midX }
        var columns: [[OCR.Line]] = []
        // First choice: the three known card positions. Text far from all of them (the Level
        // Modifiers panel on the right, stray name tags) is ignored.
        let known = Region.cardColumnsX
        var byKnown = Array(repeating: [OCR.Line](), count: known.count)
        for l in useful {
            let d = known.map { abs($0 - l.box.midX) }
            if let m = d.min(), m < 0.085, let k = d.firstIndex(of: m) { byKnown[k].append(l) }
        }
        if byKnown.filter({ $0.count >= 2 }).count >= 2 {
            columns = byKnown.filter { !$0.isEmpty }
        } else {
        for l in useful {
            if let last = columns.last, let ref = last.last, l.box.midX - ref.box.midX < 0.07 {
                columns[columns.count - 1].append(l)
            } else {
                columns.append([l])
            }
        }
        }
        // Real cards carry the most text; stray name tags make small columns. Keep the top 3.
        // A card is title + effect line(s) + "… Card" footer: 3+ lines. Player name tags
        // ("Senseimushroom" over "Abyssal Jelly") are only 1–2 lines.
        var top = Array(columns.filter { $0.count >= 3 }.sorted { $0.count > $1.count }.prefix(3))
        if top.count < 2 { top = Array(columns.filter { $0.count >= 2 }.sorted { $0.count > $1.count }.prefix(3)) }
        let cardColumns = top
            .sorted { ($0.first?.box.midX ?? 0) < ($1.first?.box.midX ?? 0) }
        return cardColumns.compactMap { col in
            let rows = col.sorted { $0.box.minY < $1.box.minY }
            // A real card has a title plus at least one effect line.
            guard rows.count >= 2 else { return nil }
            let cx = rows.map(\.box.midX).reduce(0, +) / Double(rows.count)
            let body = rows.filter { !OCR.norm($0.text).hasSuffix("card") }       // "Flooded Card"-style footers
            // Title = the biggest text near the top of the card. Name tags floating over a card
            // are small, so they don't win.
            let topHalf = body.prefix(max(1, (body.count + 1) / 2))
            guard let titleLine = topHalf.max(by: { $0.box.height < $1.box.height }) ?? body.first else { return nil }
            let red = body.filter { $0.text != titleLine.text }.filter { line in
                guard let c = Matcher.averageColor(in: image, rect: line.box) else { return false }
                return c.r > c.g + 0.08 && c.r > c.b + 0.05
            }.map(\.text)
            // Card background tint just below its text: greenish = buff, reddish = debuff.
            let bottom = min(0.80, (rows.last?.box.maxY ?? 0.6) + 0.02)
            let bg = Matcher.averageColor(in: image, rect: CGRect(x: cx - 0.05, y: bottom, width: 0.10, height: 0.06))
            let isBuff = bg.map { $0.g > $0.r } ?? false
            let midY = (rows.first!.box.minY + rows.last!.box.maxY) / 2
            return Card(title: titleLine.text, text: body.map(\.text).joined(separator: " "),
                        redLines: red, isBuff: isBuff, center: NormPoint(x: cx, y: midY))
        }
    }

    static func choose(_ cards: [Card], settings s: MacroSettings) -> Card? {
        func has(_ text: String, _ words: [String]) -> Bool {
            let t = OCR.norm(text)
            return words.contains { !OCR.norm($0).isEmpty && t.contains(OCR.norm($0)) }
        }
        func tier(_ c: Card) -> Int {
            if has(c.text, s.cardAvoid) { return 9 }
            if c.isBuff { return has(c.text, s.cardBuffExclude) ? 2 : 0 }
            let allRedOK = !c.redLines.isEmpty && c.redLines.allSatisfy { has($0, s.cardOkDebuffs) }
            return allRedOK ? 1 : 3
        }
        func rank(_ c: Card) -> Int {
            s.cardPriority.firstIndex { !OCR.norm($0).isEmpty && OCR.norm(c.text).contains(OCR.norm($0)) } ?? 999
        }
        return cards.min { a, b in
            (tier(a), rank(a), -a.pearlBonus) < (tier(b), rank(b), -b.pearlBonus)
        }
    }
}
