import Foundation
import AppKit
import CoreGraphics

/// Writes the macro's log, failure screenshots and diagnostics to ~/Desktop/AAMacro/logs
/// (falls back to Application Support if that folder doesn't exist), so problems can be
/// read after the fact instead of described.
enum DebugLog {
    static let dir: URL = {
        let fm = FileManager.default
        let desktop = fm.homeDirectoryForCurrentUser.appendingPathComponent("Desktop/AAMacro")
        let base = fm.fileExists(atPath: desktop.path) ? desktop
            : fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("AAMacro")
        let d = base.appendingPathComponent("logs")
        try? fm.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
    static var logFile: URL { dir.appendingPathComponent("macro.log") }

    static func append(_ line: String) {
        let data = Data((line + "\n").utf8)
        if let h = try? FileHandle(forWritingTo: logFile) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        } else {
            try? data.write(to: logFile)
        }
    }

    /// Keeps the logs folder from growing forever: a new macro.log each day (old ones kept as
    /// macro-YYYY-MM-DD.log for a week) and pictures/snapshots deleted after 3 days.
    static func cleanup() {
        let fm = FileManager.default
        let cal = Calendar.current
        if let attrs = try? fm.attributesOfItem(atPath: logFile.path),
           let made = (attrs[.creationDate] as? Date) ?? (attrs[.modificationDate] as? Date),
           !cal.isDateInToday(made) {
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
            let dest = dir.appendingPathComponent("macro-\(f.string(from: made)).log")
            if fm.fileExists(atPath: dest.path) {
                // Same day already rotated: append to it.
                if let data = try? Data(contentsOf: logFile), let h = try? FileHandle(forWritingTo: dest) {
                    h.seekToEndOfFile(); h.write(data); try? h.close()
                    try? fm.removeItem(at: logFile)
                }
            } else {
                try? fm.moveItem(at: logFile, to: dest)
            }
        }
        let now = Date()
        for url in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            guard let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { continue }
            let days = now.timeIntervalSince(mod) / 86_400
            let ext = url.pathExtension.lowercased()
            let name = url.lastPathComponent
            if (ext == "png" || ext == "txt") && days > 3 { try? fm.removeItem(at: url) }
            if ext == "log" && name.hasPrefix("macro-") && days > 7 { try? fm.removeItem(at: url) }
        }
    }

    static func stamp() -> String {
        let f = DateFormatter(); f.dateFormat = "HHmmss"; return f.string(from: Date())
    }

    static func savePNG(_ img: CGImage, name: String) {
        let rep = NSBitmapImageRep(cgImage: img)
        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name))
    }

    /// Screenshot + every line OCR can read (with positions as window fractions).
    /// Called on every failure, and by the Diagnose button.
    @MainActor @discardableResult
    static func snapshot(_ label: String) async -> String {
        let s = stamp()
        var report = "=== \(label) @ \(s) ===\n"
        report += "Screen Recording: \(CGPreflightScreenCaptureAccess())  Accessibility: \(AXIsProcessTrusted())\n"
        report += "Roblox frame: \(WindowManager.robloxFrame().map { "\($0)" } ?? "NOT FOUND")\n"
        report += "Locked target: origin \(WindowManager.lockedOrigin) size \(WindowManager.lockedSize)\n"
        do {
            let img = try await ScreenCapture.captureRoblox()
            report += "Captured: \(img.width)×\(img.height) px\n"
            savePNG(img, name: "\(s)-\(label).png")
            let lines = try OCR.read(img)
            report += "OCR (\(lines.count) lines, x/y = window fractions):\n"
            for l in lines.sorted(by: { ($0.box.minY, $0.box.minX) < ($1.box.minY, $1.box.minX) }) {
                report += String(format: "  (%.3f, %.3f)  %@\n", l.box.midX, l.box.midY, l.text)
            }
            if let play = try OCR.find("play", in: img, region: Region.lobbyHUD, exact: true) {
                report += "Lobby 'Play' button: FOUND at \(play.center)\n"
            } else {
                report += "Lobby 'Play' button: not found in lobbyHUD region\n"
            }
            report += "Yen read: \(MacroEngine.readYen(img).map(String.init) ?? "none")\n"
        } catch {
            report += "Capture failed: \(error.localizedDescription)\n"
        }
        try? report.write(to: dir.appendingPathComponent("\(s)-\(label).txt"), atomically: true, encoding: .utf8)
        append(report)
        return report
    }
}
