import Foundation
import AppKit

/// Saves/loads recordings, settings and template images in
/// ~/Library/Application Support/AAMacro/
///   settings.json
///   maps/<name>.json
///   templates/<name>.png     ← cropped buttons (Play, Return to Lobby, ...)
///   references/<name>.png    ← full screenshots used to recognize a map
@MainActor
final class Store: ObservableObject {
    @Published var maps: [MapRecording] = []
    @Published var settings = MacroSettings() { didSet { saveSettings() } }

    let root: URL
    var mapsDir: URL { root.appendingPathComponent("maps") }
    var profilesDir: URL { root.appendingPathComponent("scans") }
    @Published var profiles: [MapProfile] = []
    var templatesDir: URL { root.appendingPathComponent("templates") }
    var referencesDir: URL { root.appendingPathComponent("references") }

    init() {
        root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AAMacro")
        for dir in [root, mapsDir, templatesDir, referencesDir, profilesDir] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        load()
    }

    func saveProfile(_ p: MapProfile) {
        let enc = JSONEncoder(); enc.outputFormatting = .prettyPrinted
        if let data = try? enc.encode(p) {
            try? data.write(to: profilesDir.appendingPathComponent("\(p.name).json"), options: .atomic)
        }
        profiles.removeAll { $0.name == p.name }
        profiles.append(p)
    }

    /// The scan whose map name appears in the stage title (longest name wins).
    func deleteProfile(_ name: String) {
        try? FileManager.default.removeItem(at: profilesDir.appendingPathComponent("\(name).json"))
        profiles.removeAll { $0.name == name }
    }

    func profile(forTitle title: String) -> MapProfile? {
        let t = OCR.norm(title)
        if let exact = profiles.filter({ !OCR.norm($0.name).isEmpty && t.contains(OCR.norm($0.name)) })
            .max(by: { OCR.norm($0.name).count < OCR.norm($1.name).count }) { return exact }
        // Misread by a letter or two ("Navy Ban" for "Navy Bay").
        let n = canonicalName(MacroEngine.mapName(fromTitle: title))
        return profiles.first { $0.name == n }
    }

    /// A known map whose name is within 2 letters of this one (so OCR slips don't create a
    /// second copy of the same map), else the name itself.
    /// Every Summer Hunt map seen so far, spelled correctly. Names are matched against this list
    /// first, so a misread can only ever land on a real map (or on a new, unknown name).
    static let knownMapNames = [
        "Adventurer Town", "Alien Spaceship", "Assassin Park", "Cursed Festival", "Dungeon Throne",
        "Fabled Kingdom", "Future City", "Hellish City", "Magic Town", "Mountain Temple", "Navy Bay",
        "Nightmare Train", "Otherwordly Plane", "Planet Greenie", "Ruined City", "Sand Village",
        "Sky Aircraft", "Sky Island", "Snowy Kingdom", "Snowy Town", "Spirit World", "Storm Hideout",
        "Strange Town", "Walled City",
    ]

    /// Closest correctly-spelled known map name, or nil.
    static func knownMap(_ name: String) -> String? {
        let n = OCR.norm(name)
        guard n.count >= 5 else { return nil }
        // Contained in a longer misread ("ve O walled city …")? Longest match wins.
        if let inside = knownMapNames.filter({ n.contains(OCR.norm($0)) }).max(by: { $0.count < $1.count }) { return inside }
        let best = knownMapNames.map { ($0, editDistance(n, OCR.norm($0))) }.min { $0.1 < $1.1 }
        if let best, best.1 <= (n.count >= 12 ? 3 : n.count >= 6 ? 2 : 1) { return best.0 }
        return nil
    }

    func canonicalName(_ name: String) -> String {
        if let k = Self.knownMap(name) { return k }
        let n = OCR.norm(name)
        guard n.count >= 5 else { return name }
        // A known map's name inside a longer misread ("ve O walled city") → that map.
        if let inside = profiles.filter({ let k = OCR.norm($0.name); return k.count >= 5 && n.contains(k) })
            .max(by: { OCR.norm($0.name).count < OCR.norm($1.name).count }) { return inside.name }
        let best = profiles.map { ($0.name, Self.editDistance(n, OCR.norm($0.name))) }.min { $0.1 < $1.1 }
        // Allowed typos: 1 for short names, 2 from 6 letters ("navwba" → "navybay"), 3 from 12.
        if let best, best.1 <= (n.count >= 12 ? 3 : n.count >= 6 ? 2 : 1) { return best.0 }
        return name
    }

    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }; if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        for i in 1...a.count {
            var cur = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return prev[b.count]
    }

    func load() {
        let pfiles = (try? FileManager.default.contentsOfDirectory(at: profilesDir, includingPropertiesForKeys: nil)) ?? []
        profiles = pfiles.filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(MapProfile.self, from: Data(contentsOf: $0)) }
        // One-time fix: scans saved under the vote screen's text. The only one so far was learned
        // on Adventurer Town; any others can't be identified and are removed.
        for bad in profiles where OCR.norm(bad.name).contains("vote") {
            try? FileManager.default.removeItem(at: profilesDir.appendingPathComponent("\(bad.name).json"))
            profiles.removeAll { $0.name == bad.name }
            if !profiles.contains(where: { $0.name == "Adventurer Town" }) && bad.ground.count + bad.hill.count > 0 {
                var fixed = bad; fixed.name = "Adventurer Town"
                saveProfile(fixed)
            }
        }
        // Maps saved under a misread name ("Dunaeon Throne", "Navy Ban", "Walled Cito Smmer Hunt")
        // are renamed to the real map; if the real one exists too, the one with more data is kept.
        for p in profiles {
            guard let real = Self.knownMap(p.name), real != p.name else { continue }
            let existing = profiles.first { $0.name == real }
            func weight(_ x: MapProfile) -> Int {
                x.ground.count + x.hill.count + (x.learned?.count ?? 0) * 5 + (x.taught?.count ?? 0) * 10
            }
            try? FileManager.default.removeItem(at: profilesDir.appendingPathComponent("\(p.name).json"))
            profiles.removeAll { $0.name == p.name }
            if let e = existing, weight(e) >= weight(p) {
                var merged = e
                if merged.taught == nil { merged.taught = p.taught }
                if merged.learned == nil { merged.learned = p.learned }
                merged.wins = (e.wins ?? 0) + (p.wins ?? 0); merged.losses = (e.losses ?? 0) + (p.losses ?? 0)
                saveProfile(merged)
            } else {
                var renamed = p; renamed.name = real
                if let e = existing {
                    if renamed.taught == nil { renamed.taught = e.taught }
                    if renamed.learned == nil { renamed.learned = e.learned }
                    renamed.wins = (e.wins ?? 0) + (p.wins ?? 0); renamed.losses = (e.losses ?? 0) + (p.losses ?? 0)
                }
                saveProfile(renamed)
            }
        }
        let dec = JSONDecoder()
        if let data = try? Data(contentsOf: root.appendingPathComponent("settings.json")),
           let s = try? dec.decode(MacroSettings.self, from: data) { settings = s }
        let files = (try? FileManager.default.contentsOfDirectory(at: mapsDir, includingPropertiesForKeys: nil)) ?? []
        maps = files.filter { $0.pathExtension == "json" }
            .compactMap { try? dec.decode(MapRecording.self, from: Data(contentsOf: $0)) }
            .sorted { $0.name < $1.name }
        // Clean up recordings saved under a bad name (the vote screen's text instead of the map).
        for bad in maps where OCR.norm(bad.name).contains("vote") || OCR.norm(bad.name).count < 3 {
            try? FileManager.default.removeItem(at: mapsDir.appendingPathComponent("\(bad.name).json"))
        }
        maps.removeAll { OCR.norm($0.name).contains("vote") || OCR.norm($0.name).count < 3 }
    }

    func save(_ map: MapRecording) {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(map) {
            try? data.write(to: mapsDir.appendingPathComponent("\(map.name).json"), options: .atomic)
        }
        if let i = maps.firstIndex(where: { $0.id == map.id }) { maps[i] = map } else { maps.append(map) }
    }

    func delete(_ map: MapRecording) {
        try? FileManager.default.removeItem(at: mapsDir.appendingPathComponent("\(map.name).json"))
        maps.removeAll { $0.id == map.id }
    }

    private func saveSettings() {
        let enc = JSONEncoder(); enc.outputFormatting = .prettyPrinted
        if let data = try? enc.encode(settings) {
            try? data.write(to: root.appendingPathComponent("settings.json"), options: .atomic)
        }
    }

    /// Loads a template PNG (e.g. "play_button") as a CGImage.
    func template(_ name: String) -> CGImage? {
        let url = templatesDir.appendingPathComponent("\(name).png")
        guard let img = NSImage(contentsOf: url) else { return nil }
        return img.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    func saveReference(_ image: CGImage, name: String) -> String {
        let file = "\(name).png"
        let rep = NSBitmapImageRep(cgImage: image)
        try? rep.representation(using: .png, properties: [:])?
            .write(to: referencesDir.appendingPathComponent(file))
        return file
    }

    var walksDir: URL {
        let d = root.appendingPathComponent("walks")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    func saveWalk(_ w: WalkRecording) {
        let enc = JSONEncoder(); enc.outputFormatting = .prettyPrinted
        try? enc.encode(w).write(to: walksDir.appendingPathComponent("\(w.name).json"), options: .atomic)
    }
    func walk(named name: String) -> WalkRecording? {
        guard let d = try? Data(contentsOf: walksDir.appendingPathComponent("\(name).json")) else { return nil }
        return try? JSONDecoder().decode(WalkRecording.self, from: d)
    }

    func savePlan(_ p: PortalPlan) {
        let enc = JSONEncoder(); enc.outputFormatting = .prettyPrinted
        try? enc.encode(p).write(to: walksDir.appendingPathComponent("plan-\(p.name).json"), options: .atomic)
    }
    func plan(named name: String) -> PortalPlan? {
        guard let d = try? Data(contentsOf: walksDir.appendingPathComponent("plan-\(name).json")) else { return nil }
        return try? JSONDecoder().decode(PortalPlan.self, from: d)
    }

    func reference(_ file: String) -> CGImage? {
        NSImage(contentsOf: referencesDir.appendingPathComponent(file))?
            .cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}
