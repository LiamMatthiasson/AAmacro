import Foundation
import ScreenCaptureKit
import CoreGraphics

/// "Eyes": grabs a frame of just the Roblox window (even if other windows overlap it).
enum ScreenCapture {
    static let robloxBundleID = "com.roblox.RobloxPlayer"

    /// Captures the Roblox window at native (Retina) resolution.
    static func captureRoblox() async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: {
            $0.owningApplication?.bundleIdentifier == robloxBundleID && $0.frame.width > 200
        }) else {
            throw MacroError.robloxNotFound
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        let scale = Double(filter.pointPixelScale)
        config.width = Int(window.frame.width * scale)
        config.height = Int(window.frame.height * scale)
        config.showsCursor = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }
}

enum MacroError: LocalizedError {
    case robloxNotFound
    case timedOut(String)
    case unknownMap(String)
    case placementFailed(Int)

    var errorDescription: String? {
        switch self {
        case .robloxNotFound:          return "Roblox window not found. Is the game open and windowed?"
        case .timedOut(let what):      return "Timed out waiting for: \(what)"
        case .unknownMap(let text):    return "Couldn't match a recording to this map (OCR saw: \(text))"
        case .placementFailed(let s):  return "Placement for slot \(s) failed after retries"
        }
    }
}
