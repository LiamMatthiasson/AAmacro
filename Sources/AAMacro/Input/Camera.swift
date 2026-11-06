import Foundation
import CoreGraphics

/// Puts the Roblox camera in the same spot every run: fully zoomed out and tilted as
/// top-down as Roblox allows. Both zoom and tilt have hard limits, so pushing well past them
/// always lands on the identical view — no matter how zoomed in you spawned.
/// Left/right rotation is never touched, so each map always faces the same way.
enum Camera {
    static func reset(_ input: InputController, settings s: MacroSettings) async {
        guard s.cameraReset, let center = WindowManager.screenPoint(NormPoint(x: 0.5, y: 0.5)) else { return }
        let src = CGEventSource(stateID: .hidSystemState)
        func sleep(_ ms: Int) async { try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000) }

        input.move(to: center)
        await sleep(100)

        // 1) Zoom all the way out: hold O (Roblox's zoom-out key) + scroll toward you.
        await input.hold("o", seconds: 2.0)
        for _ in 0..<30 {
            CGEvent(scrollWheelEvent2Source: src, units: .line, wheelCount: 1, wheel1: -10, wheel2: 0, wheel3: 0)?
                .post(tap: .cghidEventTap)
            await sleep(15)
        }
        await sleep(200)

        // 2) Tilt to top-down: hold right mouse and drag vertically far past the tilt limit.
        let dir: Double = s.cameraTiltDown ? 1 : -1
        CGEvent(mouseEventSource: src, mouseType: .rightMouseDown, mouseCursorPosition: center, mouseButton: .right)?
            .post(tap: .cghidEventTap)
        await sleep(60)
        for i in 1...40 {
            let p = CGPoint(x: center.x, y: center.y + dir * Double(i % 2 == 0 ? 2 : 1))   // stay put on screen…
            if let e = CGEvent(mouseEventSource: src, mouseType: .rightMouseDragged, mouseCursorPosition: p, mouseButton: .right) {
                e.setIntegerValueField(.mouseEventDeltaX, value: 0)
                e.setIntegerValueField(.mouseEventDeltaY, value: Int64(dir * 25))              // …but report big moves
                e.post(tap: .cghidEventTap)
            }
            await sleep(12)
        }
        CGEvent(mouseEventSource: src, mouseType: .rightMouseUp, mouseCursorPosition: center, mouseButton: .right)?
            .post(tap: .cghidEventTap)
        await sleep(250)
    }
}
