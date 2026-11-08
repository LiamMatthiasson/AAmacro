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
    func canonicalName(_ name: String) -> String {
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

    func reference(_ file: String) -> CGImage? {
        NSImage(contentsOf: referencesDir.appendingPathComponent(file))?
            .cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}
