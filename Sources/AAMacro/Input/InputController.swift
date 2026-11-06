import Foundation
import CoreGraphics

/// "Hands": synthesizes mouse and keyboard events with CGEvent.
/// Roblox ignores clicks that teleport the cursor and click instantly,
/// so every click is: move → tiny wiggle → down → up, with delays.
struct InputController {
    /// Called before every click / key press / hold. The engine uses it to pause whatever is
    /// running and vote on cards the moment they appear, then let the action continue.
    @MainActor static var beforeAction: (() async -> Void)?
    private func gate() async { if let h = await InputController.beforeAction { await h() } }

    var delayMs: Int = 60
    private let source = CGEventSource(stateID: .hidSystemState)

    private func pause(_ ms: Int? = nil) async {
        try? await Task.sleep(nanoseconds: UInt64((ms ?? delayMs) * 1_000_000))
    }

    func move(to p: CGPoint) {
        CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?
            .post(tap: .cghidEventTap)
    }

    func click(_ p: CGPoint) async {
        await gate()
        move(to: CGPoint(x: p.x + 1, y: p.y + 1)); await pause(20)
        move(to: p); await pause()
        CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: p, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        await pause(70)
        CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: p, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        await pause()
    }

    /// Move (no click) to a point given as a fraction of the Roblox window.
    func move(_ p: NormPoint) {
        if let s = WindowManager.screenPoint(p) { move(to: s) }
    }

    /// Click a point given as a fraction of the Roblox window.
    func click(_ p: NormPoint) async {
        if let s = WindowManager.screenPoint(p) { await click(s) }
    }

    func key(_ char: String, holdMs: Int = 50) async {
        await gate()
        guard let code = KeyCodes.code(for: char) else { return }
        let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)
        // Attach the actual character for single letters/digits — text boxes read this.
        if char.count == 1 {
            let u = Array(char.utf16)
            down?.keyboardSetUnicodeString(stringLength: u.count, unicodeString: u)
            up?.keyboardSetUnicodeString(stringLength: u.count, unicodeString: u)
        }
        down?.post(tap: .cghidEventTap)
        await pause(holdMs)
        up?.post(tap: .cghidEventTap)
        await pause()
    }

    /// Hold a key for a duration — walking.
    func hold(_ char: String, seconds: Double) async {
        await key(char, holdMs: Int(seconds * 1000))
    }

    /// Type a string one key at a time (for the matchmaking code).
    func type(_ text: String, extraDelayMs: Int = 0) async {
        for ch in text {
            await key(String(ch), holdMs: 60)
            if extraDelayMs > 0 { await pause(extraDelayMs) }
        }
    }
}

/// macOS virtual key codes (ANSI layout).
enum KeyCodes {
    static let table: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26, "8": 28, "0": 29,
        "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
        "return": 36, "tab": 48, "space": 49, "escape": 53, "backspace": 51,
        "left": 123, "right": 124, "down": 125, "up": 126, "forwarddelete": 117,
    ]
    static func code(for s: String) -> CGKeyCode? { table[s.lowercased()] }
    static func name(for code: CGKeyCode) -> String? { table.first { $0.value == code }?.key }
}
