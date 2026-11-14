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
    /// Every slot+click ever seen this session (not consumed by take) — to spot retries.
    private(set) var allClicks: [Click] = []
    /// Right clicks (walk targets), with time — used by "Record walk".
    private(set) var rightClicks: [(at: NormPoint, time: Date)] = []
    /// Everything, in order — used by "Teach portal" (walk + placements + upgrade order).
    enum Event { case right(NormPoint), slotKey(Int), left(NormPoint), key(String) }
    private(set) var events: [(event: Event, time: Date)] = []
    /// Diagnostics: right clicks seen at all, and ones outside the Roblox window.
    private(set) var rightClicksSeen = 0
    private(set) var rightClicksOutside = 0
    /// Index of the next event the engine hasn't processed yet.
    var cursor = 0
    /// A click on a hotbar card picks that unit (true in a match). The dungeon watcher turns this
    /// off on menu screens, where a click that low is a menu click.
    var hotbarClicksSelect = true

    func start() {
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.leftMouseDown.rawValue)
                              | (1 << CGEventType.rightMouseDown.rawValue) | (1 << CGEventType.otherMouseDown.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                eventsOfInterest: mask, callback: { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<TeachListener>.fromOpaque(refcon).takeUnretainedValue()
            let code = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
            let loc = event.location
            let ctrl = event.flags.contains(.maskControl)
            // Control-click and a trackpad's secondary click both count as a right click.
            let t: CGEventType = (type == .leftMouseDown && ctrl) || type == .otherMouseDown ? .rightMouseDown : type
            Task { @MainActor in me.handle(type: t, keyCode: code, location: loc) }
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
            if let slot = Int(k), (1...6).contains(slot) { events.append((.slotKey(slot), Date())) }
            else { events.append((.key(k), Date())) }
            if let slot = Int(k), (1...6).contains(slot) { pendingSlot = slot }
            else if k == "q" || k == "escape" { pendingSlot = nil }
        case .rightMouseDown:
            rightClicksSeen += 1
            if let p = WindowManager.normalize(location) { rightClicks.append((p, Date())); events.append((.right(p), Date())) }
            else { rightClicksOutside += 1 }
        case .leftMouseDown where pendingSlot == nil:
            guard let p = WindowManager.normalize(location) else { return }
            // Clicking a unit card on the hotbar selects that unit, same as pressing its number key.
            if hotbarClicksSelect, p.y > 0.86, let i = Region.hotbarSlotX.firstIndex(where: { abs($0 - p.x) < 0.032 }) {
                pendingSlot = i + 1
                events.append((.slotKey(i + 1), Date()))
                return
            }
            events.append((.left(p), Date()))
        case .leftMouseDown:
            guard let slot = pendingSlot, let p = WindowManager.normalize(location) else { return }
            clicks.append(Click(slot: slot, at: p, time: Date()))
            allClicks.append(Click(slot: slot, at: p, time: Date()))
            pendingSlot = nil
        default: break
        }
    }
}
