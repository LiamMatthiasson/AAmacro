import SwiftUI
import AppKit

/// Wraps the Roblox window in a tight frame, like an all-in-one macro window:
///
///   ┌───────────── top bar (title · status · Start/Stop) ─────────────┬──────────┐
///   │                                                                  │  Units   │
///   │                         Roblox window                            │  1 … 6   │
///   │                                                                  │  + auto  │
///   ├──────────── bottom strip: Process · Settings · Stats · Record ──────────────┤
///
/// macOS can't put another app's window inside ours, so the frame is three borderless
/// panels that sit flush against Roblox and follow it. They never overlap the game, never
/// take keyboard focus, and float above other apps.
@MainActor
final class DockPanel {
    static let shared = DockPanel()
    static var width: CGFloat { WindowManager.frameRight }
    private var top: NSPanel?, right: NSPanel?, bottom: NSPanel?
    private var timer: Timer?
    var openMainWindow: (() -> Void)?

    func show(engine: MacroEngine, recorder: Recorder, store: Store) {
        guard top == nil else { return }
        func make<V: View>(_ v: V) -> NSPanel {
            let p = TypeablePanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless],
                                  backing: .buffered, defer: false)
            p.isFloatingPanel = true
            p.level = .floating
            p.hidesOnDeactivate = false
            p.becomesKeyOnlyIfNeeded = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.backgroundColor = .clear
            p.isOpaque = false
            p.hasShadow = true
            p.contentView = NSHostingView(rootView: v
                .environmentObject(engine).environmentObject(recorder).environmentObject(store)
                .preferredColorScheme(.dark))
            return p
        }
        top = make(FrameTopBar())
        right = make(FrameRightColumn())
        bottom = make(FrameBottomStrip())
        follow()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            Task { @MainActor in DockPanel.shared.follow() }
        }
    }

    /// Give the keyboard back to Roblox (after you typed into one of the frame's text boxes).
    func releaseKeyboard() {
        for p in [top, right, bottom].compactMap({ $0 }) where p.isKeyWindow {
            p.makeFirstResponder(nil)
            p.resignKey()
        }
    }

    /// Lay the three pieces around Roblox (or around where Roblox will be locked, if it's not open).
    func follow() {
        guard let top, let right, let bottom else { return }
        let r = WindowManager.robloxFrame()
            ?? CGRect(origin: WindowManager.lockedOrigin, size: WindowManager.lockedSize)
        let g = WindowManager.frameGap
        let tH = WindowManager.frameTop, rW = WindowManager.frameRight, bH = WindowManager.frameBottom
        let fullW = r.width + g + rW

        // CG (top-left origin) → AppKit (bottom-left origin of the primary screen).
        let screenH = NSScreen.screens.first?.frame.height ?? (r.maxY + bH)
        func place(_ p: NSPanel, _ cg: CGRect) {
            let ns = NSRect(x: cg.minX, y: screenH - cg.maxY, width: cg.width, height: cg.height)
            if p.frame != ns { p.setFrame(ns, display: true) }
            if !p.isVisible { p.orderFrontRegardless() }
        }
        place(top,    CGRect(x: r.minX, y: r.minY - g - tH, width: fullW, height: tH))
        place(right,  CGRect(x: r.maxX + g, y: r.minY, width: rW, height: r.height))
        place(bottom, CGRect(x: r.minX, y: r.maxY + g, width: fullW, height: bH))
    }
}

/// Borderless panels can't take keyboard input unless they say so. This one can — only when
/// you click into a text field — and it never activates the app, so Roblox keeps its focus otherwise.
final class TypeablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Text box for a list of slots ("6 1 3"). Keeps exactly what you type; saves the parsed list
/// as you go, so spaces and commas never get eaten mid-typing.
struct SlotListField: View {
    @Binding var slots: [Int]
    var placeholder = "6 1 3"
    @State private var draft = ""
    @State private var loaded = false

    var body: some View {
        TextField(placeholder, text: $draft)
            .textFieldStyle(.roundedBorder).monospaced()
            .onAppear { if !loaded { draft = slots.map(String.init).joined(separator: " "); loaded = true } }
            .onChange(of: draft) { _, text in
                // "6 1 3", "6,1,3" and "613" all mean slots 6, 1, 3.
                slots = text.compactMap { $0.wholeNumberValue }.filter { (1...6).contains($0) }
            }
            .onSubmit {                                                          // Return: tidy up, hand keys back
                draft = slots.map(String.init).joined(separator: " ")
                DockPanel.shared.releaseKeyboard()
            }
    }
}

// MARK: - Shared look

private enum Theme {
    static let bg = Color(red: 0.09, green: 0.09, blue: 0.11)
    static let card = Color(red: 0.14, green: 0.14, blue: 0.17)
    static let line = Color.white.opacity(0.12)
    static let accent = Color(red: 0.55, green: 0.42, blue: 1.0)
}

private struct FrameSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11, weight: .bold)).foregroundStyle(.white.opacity(0.85))
                .frame(maxWidth: .infinity)
            Rectangle().fill(Theme.line).frame(height: 1)
            content
        }
        .padding(6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 5))
    }
}

private struct FramePanel<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Theme.bg)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.line))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .font(.system(size: 11))
    }
}

// MARK: - Top bar

struct FrameTopBar: View {
    @EnvironmentObject var engine: MacroEngine
    @EnvironmentObject var recorder: Recorder
    @State private var screen = Permissions.screenRecording
    @State private var access = Permissions.accessibility
    @State private var roblox = WindowManager.robloxFrame() != nil
    private static let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var running: Bool { engine.state != .idle }

    var body: some View {
        FramePanel {
            HStack(spacing: 10) {
                Circle().fill(running ? .green : (recorder.isRecording ? .red : .gray)).frame(width: 8, height: 8)
                Text("AA Macro").font(.system(size: 12, weight: .heavy))
                Text(running ? engine.state.rawValue : (recorder.isRecording ? "recording" : "idle"))
                    .monospaced().foregroundStyle(.secondary)
                Spacer()
                check("Screen", screen); check("Access", access); check("Roblox", roblox)
                if !(screen && access) {
                    Button("Fix") {
                        Permissions.requestIfNeeded()
                        let pane = access ? "Privacy_ScreenCapture" : "Privacy_Accessibility"
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
                    }.controlSize(.mini)
                }
                Button(running ? "Stop (F6)" : "Start") {
                    if running { engine.stop() } else { engine.start() }
                }
                .buttonStyle(.borderedProminent).tint(running ? .red : Theme.accent).controlSize(.small)
                .disabled(recorder.isRecording)
                Button("Camera") { engine.testCamera() }.controlSize(.small).disabled(running)
                    .help("Test: zoom fully out and tilt top-down")
                Button("Diagnose") { engine.diagnose() }.controlSize(.small)
                    .help("Save a screenshot + everything the macro can read to the logs folder")
                Button { DockPanel.shared.openMainWindow?(); NSApp.activate(ignoringOtherApps: true) } label: {
                    Image(systemName: "gearshape.fill")
                }.buttonStyle(.borderless).help("Maps & full settings")
            }
            .padding(.horizontal, 10).frame(maxHeight: .infinity)
        }
        .onReceive(Self.tick) { _ in
            screen = Permissions.screenRecording; access = Permissions.accessibility
            roblox = WindowManager.robloxFrame() != nil
        }
    }

    private func check(_ name: String, _ ok: Bool) -> some View {
        HStack(spacing: 3) {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill").foregroundStyle(ok ? .green : .red)
            Text(name).foregroundStyle(.secondary)
        }.font(.system(size: 10))
    }
}

// MARK: - Right column: per-unit cards + auto mode

struct FrameRightColumn: View {
    @EnvironmentObject var store: Store

    var body: some View {
        FramePanel {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Units").font(.system(size: 13, weight: .heavy)).frame(maxWidth: .infinity)
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible())], spacing: 6) {
                        ForEach(1...6, id: \.self) { UnitCard(slot: $0) }
                    }
                    FrameSection(title: "Auto placement") {
                        Toggle("Auto on maps without a recording", isOn: $store.settings.autoWhenNoRecording)
                        Toggle("Always use auto", isOn: $store.settings.preferAuto)
                        Toggle("Save winning layouts", isOn: $store.settings.autoSaveWins)
                        Toggle("Learn unscanned maps while playing", isOn: $store.settings.learnWhilePlaying)
                            .help("Once the team is placed, scan the map mid-match and save it for next time.")
                        HStack {
                            Text("Place order")
                            SlotListField(slots: $store.settings.autoPlaceOrder)
                        }
                        Text("Slots placed first → last. Repeat a slot to place it twice (e.g. 6 1 3 1).")
                            .font(.system(size: 9)).foregroundStyle(.secondary)
                        Text("Steps (optional — overrides Place order)").font(.system(size: 10, weight: .bold)).padding(.top, 4)
                        TextEditor(text: $store.settings.autoSteps)
                            .font(.system(size: 11, design: .monospaced))
                            .frame(height: 130)
                            .scrollContentBackground(.hidden)
                            .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 4))
                        Text("One per line: place 6 · place 2 x4 · upgrade 6 max · upgrade 1 +3 · upgrade all max · wait wave 10 · wait 30")
                            .font(.system(size: 9)).foregroundStyle(.secondary)
                        let check = MacroEngine.parseSteps(store.settings.autoSteps)
                        if !check.problems.isEmpty {
                            Text("Not understood: " + check.problems.joined(separator: ", "))
                                .font(.system(size: 9)).foregroundStyle(.orange)
                        }
                        Stepper("Upgrade levels right after placing: \(store.settings.autoEarlyUpgrades >= 15 ? "MAX" : "\(store.settings.autoEarlyUpgrades)")",
                                value: $store.settings.autoEarlyUpgrades, in: 0...15)
                        Text("For Priority units only — how many levels they get before the next unit is placed. MAX = fully upgrade first.")
                            .font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                    .toggleStyle(.checkbox).controlSize(.small)
                }
                .padding(8)
            }
        }
    }
}

/// One hotbar slot: priority, max upgrade level, range.
struct UnitCard: View {
    let slot: Int
    @EnvironmentObject var store: Store

    var body: some View {
        FrameSection(title: "Unit \(slot)") {
            Toggle("Priority", isOn: Binding(
                get: { store.settings.prioritySlots.contains(slot) },
                set: { on in
                    if on { store.settings.prioritySlots.append(slot) }
                    else { store.settings.prioritySlots.removeAll { $0 == slot } }
                }))
            .toggleStyle(.checkbox)
            Toggle("Hill unit", isOn: Binding(
                get: { store.settings.hillSlots.contains(slot) },
                set: { on in
                    if on { store.settings.hillSlots.append(slot) }
                    else { store.settings.hillSlots.removeAll { $0 == slot } }
                }))
            .toggleStyle(.checkbox)
            Toggle("Can't sell", isOn: Binding(
                get: { store.settings.unsellableSlots.contains(slot) },
                set: { on in
                    if on { store.settings.unsellableSlots.append(slot) }
                    else { store.settings.unsellableSlots.removeAll { $0 == slot } }
                }))
            .toggleStyle(.checkbox)
            .help("The game won't let you sell this unit — scans never test-place with it.")
            if let rank = store.settings.prioritySlots.firstIndex(of: slot) {
                Text("upgrade order #\(rank + 1)").font(.system(size: 9)).foregroundStyle(Theme.accent)
            }
            HStack(spacing: 2) {
                Text("Max upgrade").foregroundStyle(.secondary)
                    .help("Highest upgrade level for this unit (∞ = keep upgrading). Not how many to place — that comes from Place order.")
                Spacer()
                Text(maxLevel == 0 ? "∞" : "\(maxLevel)").monospaced()
                Stepper("", value: Binding(get: { maxLevel },
                                           set: { store.settings.maxLevelPerSlot[slot] = $0 == 0 ? nil : $0 }),
                        in: 0...15).labelsHidden()
            }
            HStack(spacing: 2) {
                Text("Cost ¥").foregroundStyle(.secondary)
                Spacer()
                TextField("auto", text: Binding(
                    get: { store.settings.unitCost[slot].map(String.init) ?? "" },
                    set: { v in
                        let n = Int(v.filter(\.isNumber)) ?? 0
                        store.settings.unitCost[slot] = n > 0 ? n : nil
                    }))
                    .textFieldStyle(.roundedBorder).frame(width: 52).multilineTextAlignment(.trailing)
                    .onSubmit { DockPanel.shared.releaseKeyboard() }
            }
            HStack(spacing: 2) {
                Text("Range").foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(range * 100))%").monospaced()
                Stepper("", value: Binding(get: { range },
                                           set: { store.settings.autoRangePerSlot[slot] = $0 }),
                        in: 0.04...0.4, step: 0.01).labelsHidden()
            }
        }
        .controlSize(.mini)
        .font(.system(size: 10))
    }

    private var maxLevel: Int { store.settings.maxLevelPerSlot[slot] ?? 0 }
    private var range: Double { store.settings.autoRangePerSlot[slot] ?? 0.12 }
}

// MARK: - Bottom strip

struct FrameBottomStrip: View {
    @EnvironmentObject var engine: MacroEngine
    @EnvironmentObject var recorder: Recorder
    @EnvironmentObject var store: Store
    @State private var mapName = ""
    @State private var now = Date()
    private static let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        FramePanel {
            HStack(spacing: 6) {
                FrameSection(title: "Current Process") {
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 1) {
                                ForEach(Array(engine.log.suffix(60).enumerated()), id: \.offset) { i, line in
                                    Text(line).font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(line.contains("⚠️") ? .orange : .white.opacity(0.85))
                                        .lineLimit(1).id(i)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .onChange(of: engine.log.count) { _, _ in proxy.scrollTo(min(59, max(0, engine.log.count - 1))) }
                    }
                }
                .frame(minWidth: 300)

                FrameSection(title: "Settings") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text("Upgrade key").foregroundStyle(.secondary)
                        TextField("r", text: $store.settings.upgradeKey).textFieldStyle(.roundedBorder).frame(width: 34)
                    }
                    Stepper("Input delay \(store.settings.inputDelayMs)ms", value: $store.settings.inputDelayMs, in: 20...300, step: 10)
                    Stepper("Stop after \(store.settings.maxRuns == 0 ? "∞" : "\(store.settings.maxRuns)") runs",
                            value: $store.settings.maxRuns, in: 0...500)
                    Stepper("Lag \(String(format: "%.1f", store.settings.lagFactor))×", value: $store.settings.lagFactor, in: 1...3, step: 0.25)
                        .help("Stretches every wait. Raise it if Roblox is laggy and steps get skipped.")
                    Stepper("Match timeout \(store.settings.matchTimeoutSec)s", value: $store.settings.matchTimeoutSec, in: 30...600, step: 15)
                    Stepper("Stuck after \(store.settings.stuckMinutes) min", value: $store.settings.stuckMinutes, in: 15...120, step: 5)
                    Stepper("Stop after \(store.settings.stopAfterLosses == 0 ? "∞" : "\(store.settings.stopAfterLosses)") losses in a row",
                            value: $store.settings.stopAfterLosses, in: 0...20)
                    Stepper("Typing delay \(store.settings.typeDelayMs)ms", value: $store.settings.typeDelayMs, in: 0...500, step: 20)
                    Toggle("Camera: zoom out + top-down", isOn: $store.settings.cameraReset).toggleStyle(.checkbox)
                    Toggle("Tilt by dragging down", isOn: $store.settings.cameraTiltDown).toggleStyle(.checkbox)
                        .help("Flip this if the camera ends up looking at the sky")
                                        }
                    }
                }
                .controlSize(.mini)

                FrameSection(title: "Statistics") {
                    stat("Map", engine.currentMap.isEmpty ? "—" : engine.currentMap)
                    stat("Runs", "\(engine.runsCompleted)")
                    stat("Wins / Losses", "\(engine.wins) / \(engine.losses)")
                    stat("Running for", elapsed)
                    stat("Maps recorded", "\(store.maps.filter { !$0.name.hasPrefix("_") }.count)")
                    stat("Maps scanned", "\(store.profiles.count)")
                }

                FrameSection(title: "Record") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                    TextField("Map name", text: $mapName).textFieldStyle(.roundedBorder)
                    Button(recorder.isRecording ? "Stop & save" : "Record map") {
                        if recorder.isRecording { recorder.stop() } else if !mapName.isEmpty { recorder.start(mapName: mapName) }
                    }
                    .tint(recorder.isRecording ? .red : Theme.accent).buttonStyle(.borderedProminent)
                    .disabled(engine.state != .idle)
                    Text(recorder.isRecording ? "\(recorder.actions.count) steps" : "Start during the vote screen")
                        .font(.system(size: 9)).foregroundStyle(recorder.isRecording ? .red : .secondary)
                    Button(engine.scanning ? "Stop scan" : "Scan map") {
                        if engine.scanning { engine.stop() } else { engine.scanMap(name: mapName) }
                    }
                    .tint(engine.scanning ? .red : .teal).buttonStyle(.borderedProminent)
                    .disabled(engine.state != .idle || recorder.isRecording)
                    .help("Start the stage and place one unit yourself first. Then: teleports to spawn, sets the camera, then tests every spot for ground + hill units and watches enemies to learn the lane. Name = the box above, or read from the title.")
                    Button("Test scan") { engine.testScan(name: mapName) }
                        .disabled(engine.state != .idle || recorder.isRecording || engine.scanning)
                        .help("In a stage on a scanned map: places each unit on its saved spots (middle of the map first) and reports how many spots were good.")
                    Text(engine.scanning ? engine.scanProgress : "\(store.profiles.count) maps scanned")
                        .font(.system(size: 9)).foregroundStyle(engine.scanning ? .teal : .secondary).lineLimit(2)
                                        }
                    }
                }
                .controlSize(.small)
            }
            .padding(6)
        }
        .onReceive(Self.tick) { now = $0 }
    }

    private var elapsed: String {
        guard let s = engine.startedAt else { return "—" }
        let t = Int(now.timeIntervalSince(s))
        return String(format: "%d:%02d:%02d", t / 3600, (t / 60) % 60, t % 60)
    }

    private func stat(_ k: String, _ v: String) -> some View {
        HStack { Text(k).foregroundStyle(.secondary); Spacer(); Text(v).monospaced().lineLimit(1) }
    }
}
