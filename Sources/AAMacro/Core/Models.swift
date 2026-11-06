import Foundation
import CoreGraphics

/// A point stored as a fraction of the Roblox window (0...1 on each axis).
/// This survives Retina scaling and small window moves; it does NOT survive
/// a change in window aspect ratio, which is why WindowManager locks the size.
struct NormPoint: Codable, Hashable {
    var x: Double
    var y: Double
}

/// One step of a recorded map run. The engine replays these in order,
/// verifying each one instead of blindly clicking.
enum MacroAction: Codable, Hashable, Identifiable {
    /// Hold a movement key (w/a/s/d) for N seconds — used to walk to the enemy-spawn arrows.
    case walk(key: String, seconds: Double)
    /// Press hotbar slot (1–6), then click the spot to place it.
    case place(slot: Int, at: NormPoint)
    /// Click an already-placed unit (by its placement index) and upgrade it `times` times.
    case upgrade(placementIndex: Int, times: Int)
    /// Fixed delay.
    case wait(seconds: Double)
    /// Block until the wave counter (read with OCR) reaches this wave.
    case waitForWave(Int)

    var id: String { "\(self)" }

    var label: String {
        switch self {
        case let .walk(k, s):            return "Walk \(k.uppercased()) for \(String(format: "%.2f", s))s"
        case let .place(slot, p):        return "Place slot \(slot) at (\(String(format: "%.3f", p.x)), \(String(format: "%.3f", p.y)))"
        case let .upgrade(i, n):         return "Upgrade unit #\(i + 1) ×\(n)"
        case let .wait(s):               return "Wait \(String(format: "%.1f", s))s"
        case let .waitForWave(w):        return "Wait for wave \(w)"
        }
    }
}

/// Everything needed to replay one stage: how to recognize it + what to do.
struct MapRecording: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    /// Words that identify this stage when OCR'd on the loading/matchmaking screen.
    var keywords: [String]
    /// File name of a reference screenshot (in AppSupport/references) used as fallback recognition.
    var referenceImage: String?
    var actions: [MacroAction]
}

/// What a Scan learned about one map: where ground and hill units can stand (checked with the
/// range circle at each point), and where enemies walk. All points are window fractions taken
/// from the spawn point with the standard camera, so they line up in every later run.
struct MapProfile: Codable, Identifiable {
    var id: String { name }
    var name: String
    var ground: [NormPoint]
    var hill: [NormPoint]
    var lane: [NormPoint]
    var scannedAt: Date
    /// Spots confirmed NOT placeable (by a real attempt) — never tried again.
    var badGround: [NormPoint]? = nil
    var badHill: [NormPoint]? = nil
    /// Spots that failed once (maybe another player's unit was there). A second failure in a later
    /// match makes them bad for good.
    var suspectGround: [NormPoint]? = nil
    var suspectHill: [NormPoint]? = nil
    /// Reference screenshot of the view at scan time (file in references/), for the camera check.
    var referenceImage: String? = nil
}

/// User-tunable settings shown on the Settings tab.
struct MacroSettings: Codable {
    /// Key that upgrades the selected unit. TODO: confirm the real AA keybind from a screenshot.
    var upgradeKey: String = "r"
    /// Slots whose units get upgraded before anything else is placed/upgraded (e.g. [2, 4]).
    var prioritySlots: [Int] = []
    /// Max upgrade level per slot (1-indexed slot -> level). Missing = upgrade until it fails.
    var maxLevelPerSlot: [Int: Int] = [:]
    /// Delay between input events. Roblox drops inputs that arrive too fast.
    var inputDelayMs: Int = 60
    /// Walk from spawn to the summer event area in the lobby (recorded once, like a map).
    var lobbyWalk: [MacroAction] = []
    /// Loop forever vs. stop after N runs (0 = forever).
    var maxRuns: Int = 0
    /// Card names, best first. Matched loosely against OCR text (case/punctuation ignored).
    var cardPriority: [String] = []
    /// Cards to never pick if anything else is offered.
    var cardAvoid: [String] = []
    /// Green buffs containing these words drop below the acceptable debuffs.
    var cardBuffExclude: [String] = ["yen"]
    /// The only red (bad) effects worth accepting on a debuff card. A debuff card is OK
    /// only if *every* red line on it matches one of these.
    var cardOkDebuffs: [String] = ["enemy health", "enemy speed"]

    // MARK: Auto mode (no recording needed)
    /// Play maps that have no recording with auto-placement.
    var autoWhenNoRecording: Bool = true
    /// Use auto-placement even on maps that have a recording.
    var preferAuto: Bool = false
    /// Which slot to place next, in order (a slot can repeat). Shared by every map.
    var autoPlaceOrder: [Int] = [1, 2, 3, 4, 5, 6, 1, 2]
    /// Upgrades given to a priority-slot unit right after placing it, before placing the next unit.
    var autoEarlyUpgrades: Int = 2
    /// Unit range as a fraction of window width (rough; fine-tune per unit). Missing = 0.12.
    var autoRangePerSlot: [Int: Double] = [:]
    /// Save a winning auto layout as that map's recording.
    var autoSaveWins: Bool = true
    /// Hotbar slots holding hill-only units (they can be placed farther from the lane).
    var hillSlots: [Int] = []
    /// Optional step list ("place 6", "upgrade 6 max", "place 2 x4", "upgrade all max", "wait wave 10").
    /// When filled in, it replaces Place order + the early-upgrade setting.
    var autoSteps: String = ""
    /// On a map with no scan: once the team is placed, scan it mid-match and save it for next time.
    var learnWhilePlaying: Bool = true
    /// Placement cost per slot, typed in on the Unit cards (overrides reading it off the hotbar).
    var unitCost: [Int: Int] = [:]
    /// Units the game won't let you sell — never used to test-place spots during a scan.
    var unsellableSlots: [Int] = [6]

    // MARK: Camera
    /// At the start of every stage (and before recording): zoom fully out + tilt top-down.
    var cameraReset: Bool = true
    /// Which way to drag for top-down. Flip this if the camera ends up looking at the sky.
    var cameraTiltDown: Bool = true

    // MARK: Reliability
    /// Extra pause after each typed character (Roblox drops keys when it lags).
    var typeDelayMs: Int = 120
    /// After submitting the code, how long to wait for the match to load before retrying.
    var matchTimeoutSec: Int = 120
    /// Stretches every wait in the macro (1.0 = normal, 2.0 = twice as patient). Raise when Roblox lags.
    var lagFactor: Double = 1.0
    /// If one run (lobby → results) takes longer than this, assume it's stuck and start over.
    var stuckMinutes: Int = 45
    /// Stop the macro after this many losses in a row (0 = never stop).
    var stopAfterLosses: Int = 0   // off until the results screen's "win" wording is confirmed
}

/// Tolerant loading: every field falls back to its default if it's missing or unreadable.
/// This is what keeps your saved settings when an update adds new settings.
extension MacroSettings {
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func get<T: Decodable>(_ key: CodingKeys, _ value: inout T) {
            if let v = try? c.decodeIfPresent(T.self, forKey: key) { value = v }
        }
        get(.upgradeKey, &upgradeKey)
        get(.prioritySlots, &prioritySlots)
        get(.maxLevelPerSlot, &maxLevelPerSlot)
        get(.inputDelayMs, &inputDelayMs)
        get(.lobbyWalk, &lobbyWalk)
        get(.maxRuns, &maxRuns)
        get(.cardPriority, &cardPriority)
        get(.cardAvoid, &cardAvoid)
        get(.cardBuffExclude, &cardBuffExclude)
        get(.cardOkDebuffs, &cardOkDebuffs)
        get(.autoWhenNoRecording, &autoWhenNoRecording)
        get(.preferAuto, &preferAuto)
        get(.autoPlaceOrder, &autoPlaceOrder)
        get(.autoEarlyUpgrades, &autoEarlyUpgrades)
        get(.autoRangePerSlot, &autoRangePerSlot)
        get(.autoSaveWins, &autoSaveWins)
        get(.hillSlots, &hillSlots)
        get(.autoSteps, &autoSteps)
        get(.learnWhilePlaying, &learnWhilePlaying)
        get(.unitCost, &unitCost)
        get(.unsellableSlots, &unsellableSlots)
        get(.cameraReset, &cameraReset)
        get(.cameraTiltDown, &cameraTiltDown)
        get(.typeDelayMs, &typeDelayMs)
        get(.matchTimeoutSec, &matchTimeoutSec)
        get(.lagFactor, &lagFactor)
        get(.stuckMinutes, &stuckMinutes)
        get(.stopAfterLosses, &stopAfterLosses)
    }
}
