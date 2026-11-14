import Foundation
import CoreGraphics

// Dungeon mode, step 1: WATCH. Nothing in this file (or the other Dungeon files) sends any
// input — it only records what you do in a dungeon run so the choices can be learned.
//
// Saved in ~/Desktop/AAMacro/dungeon/
//   runs/<date-time>/run.json      everything seen in one watched run
//   runs/<date-time>/*.jpg         the screen just before each menu click
//   knowledge.json                 what all watched runs add up to (rebuilt after every run)

/// Which dungeon screen is showing. Worked out from the words on screen — the word lists in
/// DungeonVocab are first guesses and get corrected from the first watched runs.
enum DungeonScreen: String, Codable {
    /// The tile map: three tiles to pick from, next row above them.
    case path
    case shop
    /// Take-or-decline relic offer.
    case relic
    case match
    /// VICTORY / DEFEAT panel.
    case results
    case other
}

/// A piece of text on screen and where its middle is (window fractions).
struct DungeonText: Codable, Hashable {
    var text: String
    var x: Double
    var y: Double
}

/// One menu click outside a match: what was on offer, and what you clicked.
struct DungeonDecision: Codable {
    /// Seconds since the watch began.
    var t: Double
    var screen: DungeonScreen
    /// Matches won so far in this run, plus one.
    var floor: Int
    /// Known dungeon words found on screen (tiles, curses, relics), by their proper names.
    var options: [DungeonText]
    /// The options your click is credited with (same column as the click — to be calibrated).
    var picked: [String]
    var click: NormPoint
    /// The text under (or right next to) the click, as read.
    var clickedText: String
    /// Every line on screen, so the reading can be re-done later without the picture.
    var allText: [DungeonText]
    /// File name of the screenshot taken just before the click.
    var shot: String?
}

/// One thing you did in a match.
struct DungeonStep: Codable {
    enum Kind: String, Codable { case place, upgrade }
    var t: Double
    var kind: Kind
    var slot: Int
    var at: NormPoint
    /// Which unit of this match (0 = the first one placed).
    var unit: Int
    /// Upgrade presses (1 for a placement).
    var times: Int
    var wave: Int?
    var yen: Int?
    /// False = the unit panel wasn't seen after the click (kept anyway, but less certain).
    var confirmed: Bool
}

/// One match of a watched run: the walk from spawn (if any), then placements and upgrades.
struct DungeonMatchLog: Codable {
    var index: Int
    var floor: Int
    var map: String
    /// The stage title exactly as read.
    var title: String
    var startT: Double
    var endT: Double? = nil
    var outcome: MatchOutcome = .unknown
    /// Right-click walk from spawn, before the first placement (some spawns are far from the lane).
    var walk: [NormPoint] = []
    var walkGaps: [Double] = []
    /// Picture of the view where the walk ended, for lining up later.
    var walkEndShot: String? = nil
    /// You moved with W/A/S/D before placing. That can't be replayed — right-click walks can.
    var usedMoveKeys = false
    var steps: [DungeonStep] = []
}

struct DungeonRun: Codable {
    var id: String
    var startedAt: Date
    var decisions: [DungeonDecision] = []
    var matches: [DungeonMatchLog] = []
}

/// How often an option was on screen, and how often you took it.
struct DungeonOptionStat: Codable {
    var offered = 0
    var picked = 0
    /// 0…1, pulled toward 0.5 until there is enough evidence.
    var score: Double { (Double(picked) + 1) / (Double(offered) + 2) }
}

/// What all watched runs add up to.
struct DungeonKnowledge: Codable {
    var runs = 0
    var decisions = 0
    var matchesWon = 0
    var matchesLost = 0
    /// Per option name ("Hoard", "Rare Chest", "Glacial Axe"…).
    var options: [String: DungeonOptionStat] = [:]
    /// "A>B" → times you took A while B was also on offer.
    var beats: [String: Int] = [:]
    /// Per map: the walk + placements + upgrades of your most recent WIN on it.
    var plans: [String: PortalPlan] = [:]
    /// Maps where you walked with W/A/S/D (no replayable walk saved).
    var keyWalkMaps: [String] = []
}

/// Every dungeon word the macro knows by name. Sources: the game wiki's Dungeon page.
/// Anything not listed here is still saved as raw text in each decision (allText).
enum DungeonVocab {
    enum Kind: String { case tile, curse, relic }
    struct Entry { let name: String; let kind: Kind; let words: [String] }

    private static func entry(_ name: String, _ kind: Kind) -> Entry {
        Entry(name: name, kind: kind, words: words(of: name))
    }

    static func words(of s: String) -> [String] {
        s.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
    }

    static let tiles = ["Hoard", "Shop", "Curse", "Rare Chest", "Chest", "Relic", "Open"]
    static let curses = ["Vampirism", "Wind", "Burst", "Shielding", "Regen", "Armor", "Money", "Frenzy",
                         "Flight", "Chaos", "Eruption", "Health", "Shopping", "Explosion"]
    static let relics = ["Mask of Riches", "Golden Mushroom", "Golden Branch", "Genie Lamp", "Golden Fishhook",
                         "Fish Hook", "Archmage's Hat", "Magic Tome", "Mage Coat", "Aures Maul", "Solar Cleaver",
                         "Elf Bow", "Reaper Scythe", "Celestial Blade", "Ninja Belt", "Glacial Axe",
                         "Philosopher's Stone", "Shimmering Moon Fragment"]

    /// Longest names first, so "Rare Chest" is found before "Chest".
    static let entries: [Entry] = (tiles.map { entry($0, .tile) } + curses.map { entry($0, .curse) }
                                   + relics.map { entry($0, .relic) })
        .sorted { $0.words.count > $1.words.count }

    static func kind(of name: String) -> Kind? { entries.first { $0.name == name }?.kind }

    /// Known names found in these lines (whole words only), each at its line's position.
    static func hits(in lines: [OCR.Line]) -> [DungeonText] {
        var out: [DungeonText] = []
        for line in lines {
            var w = words(of: line.text)
            for e in entries where !e.words.isEmpty {
                var i = 0
                while i + e.words.count <= w.count {
                    if Array(w[i..<(i + e.words.count)]) == e.words {
                        out.append(DungeonText(text: e.name, x: Double(line.box.midX), y: Double(line.box.midY)))
                        w.replaceSubrange(i..<(i + e.words.count), with: ["-"])     // used up
                    }
                    i += 1
                }
            }
        }
        return out
    }

    static let winWords = ["victory", "youwon", "stagecleared"]
    static let lossWords = ["defeat", "youlost", "gameover"]

    static func outcome(_ lines: [OCR.Line]) -> MatchOutcome {
        let t = lines.map { OCR.norm($0.text) }
        if t.contains(where: { l in winWords.contains { l.contains($0) } }) { return .victory }
        if t.contains(where: { l in lossWords.contains { l.contains($0) } }) { return .defeat }
        return .unknown
    }

    /// Which screen these lines look like. `wave` = the wave counter, if it could be read.
    /// CALIBRATE: the shop / relic / path tests are guesses until real screens have been logged.
    static func screen(lines: [OCR.Line], wave: Int?) -> DungeonScreen {
        if outcome(lines) != .unknown { return .results }
        if wave != nil { return .match }
        let all = lines.map { OCR.norm($0.text) }
        func has(_ s: String) -> Bool { all.contains { $0.contains(s) } }
        let found = hits(in: lines)
        if found.contains(where: { kind(of: $0.text) == .relic }) && (has("decline") || has("take") || has("relic")) { return .relic }
        if has("shop") && (has("buy") || has("purchase") || has("leave")) { return .shop }
        if found.filter({ kind(of: $0.text) == .tile }).count >= 2 { return .path }
        return .other
    }

    /// The options a click is credited with: the ones in the same column as the click.
    /// CALIBRATE: 0.11 of the window width is a guess at half a tile's width.
    static func attribute(click p: NormPoint, options: [DungeonText]) -> [String] {
        var names: [String] = []
        for o in options where abs(o.x - p.x) < 0.11 && !names.contains(o.text) { names.append(o.text) }
        return names
    }
}
