import SwiftUI
import AppKit

/// Entry point. One window = the "macro page" with three tabs: Run, Maps, Settings.
@main
struct AAMacroApp: App {
    @StateObject private var store = Store()
    @StateObject private var engine = MacroEngine()
    @StateObject private var recorder = Recorder()

    init() {
        // An SPM executable has no .app bundle, so tell AppKit to show a normal window + Dock icon.
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        Window("AA Macro", id: "main") {
            RootView()
                .environmentObject(store)
                .environmentObject(engine)
                .environmentObject(recorder)
                .frame(minWidth: 720, minHeight: 520)
                .onAppear {
                    // No automatic permission prompts on launch — the top bar shows red checks
                    // and its Fix button asks only when something is actually missing.
                    engine.store = store
                    recorder.store = store
                    Hotkeys.shared.install(engine: engine, recorder: recorder)
                    DockPanel.shared.show(engine: engine, recorder: recorder, store: store)
                }
        }
    }
}

/// Screen Recording (to see the game) + Accessibility (to click/type and record input).
enum Permissions {
    static var screenRecording: Bool { CGPreflightScreenCaptureAccess() }
    static var accessibility: Bool { AXIsProcessTrusted() }

    static func requestIfNeeded() {
        if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }
}

/// Global panic/stop key so you can always kill the macro: F6 = stop everything.
final class Hotkeys {
    static let shared = Hotkeys()
    private var monitor: Any?

    func install(engine: MacroEngine, recorder: Recorder) {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 97 /* F6 */ {
                Task { @MainActor in
                    engine.stop()
                    recorder.stop()
                }
            }
        }
    }
}
