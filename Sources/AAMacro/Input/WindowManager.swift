import Foundation
import AppKit
import ApplicationServices

/// Finds the Roblox window, converts normalized points to screen points,
/// and locks the window to a fixed size/position so recordings stay valid.
enum WindowManager {
    /// Size every recording is made at (your current windowed size, in points).
    /// Change once, before recording any maps — all regions are fractions of this.
    /// Size of the frame pieces that wrap around Roblox (see UI/DockPanel.swift).
    static let frameTop: CGFloat = 34, frameRight: CGFloat = 300, frameBottom: CGFloat = 170, frameGap: CGFloat = 2

    /// The usable screen area in CG coordinates (top-left origin), below the menu bar.
    static var usable: CGRect {
        let screenH = NSScreen.screens.first?.frame.height ?? 900
        let vis = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1512, height: 944)
        return CGRect(x: vis.minX, y: screenH - vis.maxY, width: vis.width, height: vis.height)
    }

    /// Roblox's top-left: just inside the frame's top-left corner.
    static var lockedOrigin: CGPoint {
        CGPoint(x: usable.minX + 6, y: usable.minY + frameTop + frameGap + 4)
    }

    /// As big as possible (up to 1320×832) while the whole frame fits on screen.
    /// The shape never changes, so recordings and regions stay valid at any size.
    static var lockedSize: CGSize {
        let aspect = 832.0 / 1320.0
        let maxW = min(1320, usable.width - 12 - frameRight - frameGap)
        let maxH = usable.height - frameTop - frameBottom - 2 * frameGap - 10
        let w = min(maxW, maxH / aspect)
        return CGSize(width: w.rounded(), height: (w * aspect).rounded())
    }

    /// Re-applies the lock if Roblox was moved/resized (or relaunched). Cheap; call often.
    @discardableResult
    static func ensureLocked() -> Bool {
        guard let f = robloxFrame() else { return false }
        if abs(f.width - lockedSize.width) > 2 || abs(f.height - lockedSize.height) > 2
            || abs(f.minX - lockedOrigin.x) > 2 || abs(f.minY - lockedOrigin.y) > 2 {
            lockAndFocus()
        }
        return true
    }

    /// Current Roblox window frame in global screen points (top-left origin, like CGEvent uses).
    static func robloxFrame() -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        // Match by process ID of the Roblox app (bundle ID), not by name — names vary.
        let pids = Set(NSRunningApplication.runningApplications(withBundleIdentifier: ScreenCapture.robloxBundleID)
            .map(\.processIdentifier))
        guard !pids.isEmpty else { return nil }
        for info in list {
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, pids.contains(pid),
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let b = info[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            let r = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
            if r.width > 200 { return r }
        }
        return nil
    }

    /// Normalized window point -> global screen point.
    static func screenPoint(_ p: NormPoint) -> CGPoint? {
        guard let f = robloxFrame() else { return nil }
        // Both this frame and the captured image include the title bar, so the same
        // fractions line up for seeing and clicking — no offset needed.
        return CGPoint(x: f.minX + p.x * f.width, y: f.minY + p.y * f.height)
    }

    /// Global screen point -> normalized window point (used while recording).
    static func normalize(_ pt: CGPoint) -> NormPoint? {
        guard let f = robloxFrame(), f.contains(pt) else { return nil }
        return NormPoint(x: (pt.x - f.minX) / f.width, y: (pt.y - f.minY) / f.height)
    }

    /// Brings Roblox to the front (keyboard input only goes to the active app).
    static func focusRoblox() async {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: ScreenCapture.robloxBundleID).first
        else { return }
        let hadKeyboard = await MainActor.run { () -> Bool in
            let had = NSApp.keyWindow is TypeablePanel
            DockPanel.shared.releaseKeyboard()                 // frame text boxes must not swallow keys
            return had
        }
        if !app.isActive || hadKeyboard {
            app.activate()
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
    }

    /// Moves/resizes Roblox via the Accessibility API and brings it to front.
    /// Returns a problem description, or nil if it worked.
    @discardableResult
    static func lockAndFocus() -> String? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: ScreenCapture.robloxBundleID).first
        else { return "Roblox isn't running" }
        guard AXIsProcessTrusted() else { return "No Accessibility permission — can't move/resize Roblox or click" }
        app.activate()
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &value) != .success || value == nil {
            // Not focused yet (we just activated it) — fall back to its first window.
            var list: CFTypeRef?
            if AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &list) == .success,
               let wins = list as? [AXUIElement], let first = wins.first { value = first }
        }
        guard let win = value else { return "Couldn't get Roblox's window via Accessibility" }
        let window = win as! AXUIElement
        var origin = lockedOrigin, size = lockedSize
        if let pos = AXValueCreate(.cgPoint, &origin) {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, pos)
        }
        if let sz = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sz)
        }
        return nil
    }
}
