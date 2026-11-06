import Foundation
import CoreGraphics
import AppKit

/// Record mode: you play a map once, this listens (read-only) to your input and
/// turns it into MacroActions — not raw mouse paths.
///
///   W/A/S/D held           → .walk(key, seconds)
///   number key, then click → .place(slot, at:)        (click position saved relative to window)
///   click on a placed unit, then upgrade key → .upgrade(placementIndex, times)
///   pause > 2s between actions → .wait(seconds)
@MainActor
final class Recorder: ObservableObject {
    @Published var isRecording = false
    @Published var actions: [MacroAction] = []
    weak var store: Store?

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var keyDownAt: [String: Date] = [:]
    private var pendingSlot: Int?
    private var selectedPlacement: Int?
    private var placements: [NormPoint] = []
    private var lastActionAt = Date()
    private var mapName = ""
    private var firstFrame: CGImage?
    /// Updated in the background while recording; clicks during the card screen are ignored
    /// because cards are decided live by CardPicker, not replayed.
    private var cardScreenVisible = false
    private var cardWatcher: Task<Void, Never>?

    func start(mapName: String) {
        guard !isRecording else { return }
        self.mapName = mapName
        actions = []; placements = []; pendingSlot = nil; selectedPlacement = nil
        keyDownAt = [:]; lastActionAt = Date()
        WindowManager.lockAndFocus()
        if let s = store?.settings, s.cameraReset {
            Task { await Camera.reset(InputController(delayMs: s.inputDelayMs), settings: s) }
        }
        Task { firstFrame = try? await ScreenCapture.captureRoblox() }   // reference image for recognition
        cardWatcher = Task { [weak self] in
            while !Task.isCancelled {
                if let t = self?.store?.template("card_screen"),
                   let img = try? await ScreenCapture.captureRoblox() {
                    self?.cardScreenVisible = Matcher.find(t, in: img) != nil
                }
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }

        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
                              | (1 << CGEventType.leftMouseDown.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                eventsOfInterest: mask, callback: { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let rec = Unmanaged<Recorder>.fromOpaque(refcon).takeUnretainedValue()
            let code = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
            let loc = event.location
            Task { @MainActor in rec.handle(type: type, keyCode: code, location: loc) }
            return Unmanaged.passUnretained(event)
        }, userInfo: refcon)

        guard let tap else { print("Event tap failed — grant Accessibility/Input Monitoring"); return }
        runLoopSource = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        isRecording = true
    }

    /// Stops and saves as a MapRecording. Keywords default to the words in the map name.
    @discardableResult
    func stop() -> MapRecording? {
        guard isRecording else { return nil }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        tap = nil; runLoopSource = nil; isRecording = false
        cardWatcher?.cancel(); cardWatcher = nil; cardScreenVisible = false

        var map = MapRecording(name: mapName,
                               keywords: [mapName.lowercased()],   // matched against the stage title, e.g. "magic town"
                               actions: actions)
        // Fingerprint = the path minimap. It looks the same every run regardless of camera.
        if let store, let mini = firstFrame?.cropped(to: Region.minimap) {
            map.referenceImage = store.saveReference(mini, name: mapName)
        }
        store?.save(map)
        return map
    }

    private func noteGap() {
        let gap = Date().timeIntervalSince(lastActionAt)
        if gap > 2 { actions.append(.wait(seconds: (gap * 10).rounded() / 10)) }
        lastActionAt = Date()
    }

    private func handle(type: CGEventType, keyCode: CGKeyCode, location: CGPoint) {
        let upgradeKey = store?.settings.upgradeKey ?? "t"
        switch type {
        case .keyDown:
            guard let k = KeyCodes.name(for: keyCode) else { return }
            if "wasd".contains(k), keyDownAt[k] == nil { keyDownAt[k] = Date() }
            else if let slot = Int(k), (1...6).contains(slot) { pendingSlot = slot }
            else if k == upgradeKey, let sel = selectedPlacement {
                noteGap()
                // Merge repeated presses into one action: upgrade(#2, ×3)
                if case let .upgrade(i, n)? = actions.last, i == sel { actions[actions.count - 1] = .upgrade(placementIndex: i, times: n + 1) }
                else { actions.append(.upgrade(placementIndex: sel, times: 1)) }
            }
        case .keyUp:
            guard let k = KeyCodes.name(for: keyCode), let start = keyDownAt.removeValue(forKey: k) else { return }
            noteGap()
            actions.append(.walk(key: k, seconds: (Date().timeIntervalSince(start) * 100).rounded() / 100))
        case .leftMouseDown:
            guard let p = WindowManager.normalize(location) else { return }
            if cardScreenVisible { return }          // card picks are never recorded
            if let slot = pendingSlot {
                noteGap()
                actions.append(.place(slot: slot, at: p))
                placements.append(p)
                pendingSlot = nil
            } else {
                // Clicking near a unit we placed = selecting it for upgrades.
                selectedPlacement = placements.firstIndex { abs($0.x - p.x) < 0.02 && abs($0.y - p.y) < 0.03 }
            }
        default: break
        }
    }
}
