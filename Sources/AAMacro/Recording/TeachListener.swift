import Foundation
import CoreGraphics

/// Teach mode: listens (read-only) to YOUR input during a match and notes every
/// "slot key, then click" — where you put each unit. The engine checks each one actually
/// placed (the unit panel pops up) before saving it.
@MainActor
final class TeachListener {
    struct Click { let slot: Int; let at: NormPoint; let time: Date }

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var pendingSlot: Int?
    private var clicks: [Click] = []

    func start() {
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.leftMouseDown.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                eventsOfInterest: mask, callback: { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<TeachListener>.fromOpaque(refcon).takeUnretainedValue()
            let code = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
            let loc = event.location
            Task { @MainActor in me.handle(type: type, keyCode: code, location: loc) }
            return Unmanaged.passUnretained(event)
        }, userInfo: refcon)
        guard let tap else { return }
        source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil; source = nil
    }

    var isListening: Bool { tap != nil }

    /// Clicks at least `age` seconds old (so the game has had time to react), removed from the queue.
    func take(olderThan age: TimeInterval) -> [Click] {
        let now = Date()
        let ready = clicks.filter { now.timeIntervalSince($0.time) >= age }
        clicks.removeAll { now.timeIntervalSince($0.time) >= age }
        return ready
    }

    private func handle(type: CGEventType, keyCode: CGKeyCode, location: CGPoint) {
        switch type {
        case .keyDown:
            guard let k = KeyCodes.name(for: keyCode) else { return }
            if let slot = Int(k), (1...6).contains(slot) { pendingSlot = slot }
            else if k == "q" || k == "escape" { pendingSlot = nil }
        case .leftMouseDown:
            guard let slot = pendingSlot, let p = WindowManager.normalize(location) else { return }
            clicks.append(Click(slot: slot, at: p, time: Date()))
            pendingSlot = nil
        default: break
        }
    }
}
