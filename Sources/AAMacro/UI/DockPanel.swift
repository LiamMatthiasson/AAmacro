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

/// Pixel-art look: flat colours, hard edges, no gradients/blur/soft shadows (cheap to draw).
enum Pix {
    static let ink = Color(red: 0.24, green: 0.17, blue: 0.33)          // dark plum outline
    static let paper = Color(red: 1.00, green: 0.97, blue: 0.99)
    static let bg = Color(red: 0.98, green: 0.90, blue: 0.95)           // flat pastel pink
    static let dot = Color(red: 0.93, green: 0.80, blue: 0.90)
    static let accent = Color(red: 1.00, green: 0.45, blue: 0.70)       // bubblegum pink
    static let mint = Color(red: 0.55, green: 0.88, blue: 0.75)
    static let sky = Color(red: 0.62, green: 0.85, blue: 1.00)
    static let lemon = Color(red: 1.00, green: 0.93, blue: 0.62)
    static let muted = Color(red: 0.55, green: 0.47, blue: 0.66)
    static let font = Font.system(size: 11, weight: .semibold, design: .monospaced)
    static func font(_ size: CGFloat, _ w: Font.Weight = .bold) -> Font { .system(size: size, weight: w, design: .monospaced) }
    static let rainbow: [Color] = [Color(red: 1, green: 0.62, blue: 0.75), Color(red: 1, green: 0.78, blue: 0.62),
                                   Color(red: 1, green: 0.93, blue: 0.62), Color(red: 0.70, green: 0.92, blue: 0.70),
                                   Color(red: 0.62, green: 0.85, blue: 1.00), Color(red: 0.75, green: 0.70, blue: 1.00)]
    /// Each window gets its own flat candy colour (units cycle pink, mint, lavender, blue, peach, lemon).
    static let candy: [Color] = [Color(red: 1.00, green: 0.80, blue: 0.89), Color(red: 0.76, green: 0.95, blue: 0.87),
                                 Color(red: 0.87, green: 0.82, blue: 1.00), Color(red: 0.80, green: 0.89, blue: 1.00),
                                 Color(red: 1.00, green: 0.87, blue: 0.80), Color(red: 1.00, green: 0.95, blue: 0.76)]
}

/// Flat pastel background with a sparse pixel dot pattern. One 24×24 tile drawn ONCE and
/// repeated by the GPU — nothing is redrawn when the panel updates.
private struct PastelGrid: View {
    static let tile: NSImage = {
        NSImage(size: NSSize(width: 24, height: 24), flipped: false) { rect in
            NSColor(Pix.bg).setFill(); rect.fill()
            NSColor(Pix.dot).setFill()
            NSRect(x: 6, y: 6, width: 2, height: 2).fill()
            NSRect(x: 18, y: 18, width: 2, height: 2).fill()
            return true
        }
    }()
    var body: some View { Image(nsImage: Self.tile).resizable(resizingMode: .tile) }
}

/// A chunky pixel box: 2 px dark outline, light top-left bevel, dark bottom-right bevel,
/// hard 3 px drop shadow. Drawn with four rectangles — no shadows, no blur.
struct PixelBox: ViewModifier {
    var fill: Color
    var pressed = false
    func body(content: Content) -> some View {
        content
            .background(
                ZStack {
                    Rectangle().fill(Pix.ink)
                    Rectangle().fill(fill).padding(2)
                    VStack(spacing: 0) {
                        Rectangle().fill(.white.opacity(pressed ? 0 : 0.75)).frame(height: 2)
                        Spacer(minLength: 0)
                        Rectangle().fill(Pix.ink.opacity(pressed ? 0.05 : 0.22)).frame(height: 2)
                    }.padding(2)
                    HStack(spacing: 0) {
                        Rectangle().fill(.white.opacity(pressed ? 0 : 0.75)).frame(width: 2)
                        Spacer(minLength: 0)
                        Rectangle().fill(Pix.ink.opacity(pressed ? 0.05 : 0.22)).frame(width: 2)
                    }.padding(2)
                }
            )
            .background(Rectangle().fill(Pix.ink.opacity(0.35)).offset(x: 3, y: 3))
    }
}

extension View {
    func pixelBox(_ fill: Color, pressed: Bool = false) -> some View { modifier(PixelBox(fill: fill, pressed: pressed)) }
}

/// A pixel push button.
struct PixelButton: View {
    let title: String
    var fill: Color = Pix.candy[0]
    var size: CGFloat = 11
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(Pix.font(size, .black)).foregroundStyle(Pix.ink)
                .padding(.horizontal, 9).padding(.vertical, 3)
                .pixelBox(fill)
        }
        .buttonStyle(.plain)
    }
}

/// Segmented pixel bar (win rate, progress).
struct RainbowBar: View {
    var value: Double          // 0…1
    var segments = 12
    var body: some View {
        HStack(spacing: 1) {
            ForEach(0..<segments, id: \.self) { i in
                Rectangle()
                    .fill(Double(i) < value * Double(segments) ? Pix.rainbow[i * Pix.rainbow.count / segments] : Pix.paper)
                    .frame(height: 8)
            }
        }
        .padding(2)
        .background(Rectangle().fill(Pix.ink))
    }
}

private func windowTitle(_ title: String) -> (text: String, tint: Color) {
    if title.hasPrefix("Unit "), let n = Int(title.dropFirst(5)) {
        let icons = ["🌸", "🍓", "🍡", "🧁", "🍑", "⭐️"]
        return ("\(icons[(n - 1) % icons.count]) unit \(n)", Pix.candy[(n - 1) % Pix.candy.count])
    }
    switch title {
    case "Auto placement": return ("🪄 auto placement", Pix.candy[2])
    case "Current Process": return ("💻 what i'm doing.exe", Pix.candy[3])
    case "Settings": return ("🎀 settings", Pix.candy[0])
    case "Statistics": return ("🏆 my stats", Pix.candy[1])
    case "Record": return ("📁 record & teach", Pix.candy[4])
    default: return ("✦ \(title.lowercased())", Pix.candy[2])
    }
}

private struct FrameSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        let t = windowTitle(title)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Text(t.text).font(Pix.font(10.5, .heavy)).foregroundStyle(Pix.ink).lineLimit(1)
                Spacer(minLength: 2)
                HStack(spacing: 2) {
                    ForEach(0..<3, id: \.self) { _ in
                        Rectangle().fill(Pix.paper).frame(width: 7, height: 7)
                            .overlay(Rectangle().strokeBorder(Pix.ink, lineWidth: 1.5))
                    }
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(t.tint)
            .overlay(alignment: .bottom) { Rectangle().fill(Pix.ink).frame(height: 2) }
            VStack(alignment: .leading, spacing: 4) { content }
                .padding(7)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .pixelBox(Pix.paper)
        .padding(.trailing, 3).padding(.bottom, 3)
    }
}

private struct FramePanel<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(PastelGrid())
            .overlay(Rectangle().strokeBorder(Pix.ink, lineWidth: 2))
            .font(Pix.font)
            .foregroundStyle(Pix.ink)
            .tint(Pix.accent)
            .environment(\.colorScheme, .light)
    }
}

// MARK: - Top bar

struct FrameTopBar: View {
    @EnvironmentObject var engine: MacroEngine
    @EnvironmentObject var recorder: Recorder
    @EnvironmentObject var store: Store
    @State private var screen = Permissions.screenRecording
    @State private var access = Permissions.accessibility
    @State private var roblox = WindowManager.robloxFrame() != nil
    private static let tick = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var running: Bool { engine.state != .idle }

    var body: some View {
        FramePanel {
            HStack(spacing: 10) {
                Mochi(engine: engine)
                Text("AA MACRO").font(Pix.font(14, .black))
                    .foregroundStyle(Color(red: 0.90, green: 0.36, blue: 0.62))
                    .background(Text("AA MACRO").font(Pix.font(14, .black)).foregroundStyle(Pix.ink).offset(x: 1.5, y: 1.5))
                Picker("", selection: $store.settings.mode) {
                    ForEach(GameMode.allCases) { m in Text(m.rawValue).tag(m) }
                }
                .labelsHidden().controlSize(.small).fixedSize().disabled(running)
                .help("What to farm. More modes (Story, Infinite…) can be added later.")
                LoopTrack(state: engine.state, recording: recorder.isRecording)
                Spacer()
                check("Screen", screen); check("Access", access); check("Roblox", roblox)
                if !(screen && access) {
                    Button("Fix") {
                        Permissions.requestIfNeeded()
                        let pane = access ? "Privacy_ScreenCapture" : "Privacy_Accessibility"
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
                    }.controlSize(.mini)
                }
                PixelButton(title: running ? "■ STOP (F6)" : "▶ START",
                            fill: running ? Color(red: 1.0, green: 0.70, blue: 0.72) : Color(red: 1.0, green: 0.78, blue: 0.90),
                            size: 12) {
                    if running { engine.stop() } else { engine.start() }
                }
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
            Image(systemName: ok ? "heart.fill" : "heart.slash.fill").foregroundStyle(ok ? Pix.accent : .gray)
            Text(name).foregroundStyle(.secondary)
        }.font(.system(size: 10, design: .monospaced))
    }
}

/// The farming loop as a row of pixel chips, the current step lit up:
///   lobby ▸ pad ▸ code ▸ vote ▸ play ▸ results
struct LoopTrack: View {
    let state: MacroEngine.State
    var recording = false

    private static let steps: [(MacroEngine.State, String)] = [
        (.lobby, "lobby"), (.walkToEvent, "pad"), (.matchmaking, "code"), (.loadingStage, "vote"),
        (.playStage, "play"), (.results, "results"),
    ]
    private var current: MacroEngine.State { state == .enterCode ? .matchmaking : state }

    var body: some View {
        HStack(spacing: 3) {
            if state == .idle {
                chip(recording ? "● recording" : "zzz napping", lit: recording, color: recording ? Pix.candy[0] : Pix.paper)
            } else if state == .recovering {
                chip("⚠ recovering…", lit: true, color: Pix.lemon)
            } else {
                ForEach(Self.steps, id: \.1) { step in
                    chip(step.1, lit: step.0 == current, color: step.0 == current ? Pix.mint : Pix.paper)
                    if step.1 != "results" { Text("▸").font(Pix.font(8, .black)).foregroundStyle(Pix.muted) }
                }
            }
        }
    }

    private func chip(_ text: String, lit: Bool, color: Color) -> some View {
        Text(text)
            .font(Pix.font(9.5, lit ? .black : .semibold))
            .foregroundStyle(lit ? Pix.ink : Pix.muted)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .pixelBox(color, pressed: !lit)
    }
}

// MARK: - Right column: per-unit cards + auto mode

struct FrameRightColumn: View {
    @EnvironmentObject var store: Store

    var body: some View {
        FramePanel {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text("🎀 My Team 🎀").font(.system(size: 15, weight: .black, design: .monospaced))
                        .foregroundStyle(Pix.ink).frame(maxWidth: .infinity)
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible())], spacing: 6) {
                        ForEach(1...6, id: \.self) { UnitCard(slot: $0) }
                    }
                    FrameSection(title: "Auto placement") {
                        Toggle("Learn unscanned maps while playing", isOn: $store.settings.learnWhilePlaying)
                            .help("Once the team is placed, scan the map mid-match and save it for next time.")
                        Toggle("Teach mode (I place units on new maps)", isOn: $store.settings.teachMode)
                            .help("On a map you haven't taught yet, you place the units yourself; the macro saves where each slot went. Maps already taught play automatically. Turn off before sleeping.")
                        Toggle("   …only ask me for hill units", isOn: $store.settings.teachHillsOnly)
                            .disabled(!store.settings.teachMode)
                            .help("Ground units are placed automatically (they already do well); you only place the hill units once per map.")
                        let taught = store.profiles.filter { !($0.taught ?? []).isEmpty }.map(\.name).sorted()
                        Text("Taught maps: \(taught.isEmpty ? "none yet" : taught.joined(separator: ", "))")
                            .font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                        HStack {
                            Text("Place order")
                            SlotListField(slots: $store.settings.autoPlaceOrder)
                        }
                        Text("Slots placed first → last. Repeat a slot to place it twice (e.g. 6 1 3 1).")
                            .font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                        Text("Steps (optional — overrides Place order)").font(.system(size: 10, weight: .bold, design: .monospaced)).padding(.top, 4)
                        TextEditor(text: $store.settings.autoSteps)
                            .font(.system(size: 11, design: .monospaced))
                            .frame(height: 130)
                            .scrollContentBackground(.hidden)
                            .background(Color.white.opacity(0.85), in: RoundedRectangle(cornerRadius: 4))
                        Text("One per line: place 6 · place 2 x4 · upgrade 6 max · upgrade 1 +3 · upgrade all max · wait wave 10 · wait 30")
                            .font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                        Text("Map-specific steps: add a line like [Storm Hideout] and that map's steps below it. Steps above the first [Map] line are for every other map.")
                            .font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                        let check = MacroEngine.parseSteps(store.settings.autoSteps)
                        if !check.problems.isEmpty {
                            Text("Not understood: " + check.problems.joined(separator: ", "))
                                .font(.system(size: 9, design: .monospaced)).foregroundStyle(.orange)
                        }
                        Stepper("Upgrade levels right after placing: \(store.settings.autoEarlyUpgrades >= 15 ? "MAX" : "\(store.settings.autoEarlyUpgrades)")",
                                value: $store.settings.autoEarlyUpgrades, in: 0...15)
                        Text("For Priority units only — how many levels they get before the next unit is placed. MAX = fully upgrade first.")
                            .font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
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
                Text("upgrade order #\(rank + 1)").font(.system(size: 9, design: .monospaced)).foregroundStyle(Pix.accent)
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
        .font(.system(size: 10, design: .monospaced))
    }

    private var maxLevel: Int { store.settings.maxLevelPerSlot[slot] ?? 0 }
    private var range: Double { store.settings.autoRangePerSlot[slot] ?? 0.12 }
}

// MARK: - Bottom strip
//
// Four windows, each watching only what it needs: a new log line redraws the log window and
// nothing else; the clock ticks only inside the stats window.

struct FrameBottomStrip: View {
    @EnvironmentObject var engine: MacroEngine

    var body: some View {
        FramePanel {
            HStack(spacing: 6) {
                ProcessLogBox(journal: engine.journal).frame(minWidth: 300)
                SettingsBox().controlSize(.mini)
                StatsBox()
                RecordBox().controlSize(.small)
            }
            .padding(6)
        }
    }
}

/// The live log. Watches the journal only.
private struct ProcessLogBox: View {
    @ObservedObject var journal: MacroJournal

    var body: some View {
        FrameSection(title: "Current Process") {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(journal.lines.suffix(80)) { line in
                            Text(line.text).font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(color(line.kind))
                                .lineLimit(1).id(line.id)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: journal.lines.last?.id) { _, id in if let id { proxy.scrollTo(id) } }
            }
        }
    }

    private func color(_ k: LogLine.Kind) -> Color {
        switch k {
        case .warn:  return .orange
        case .good:  return Color(red: 0.2, green: 0.6, blue: 0.45)
        case .teach: return Color(red: 0.55, green: 0.35, blue: 0.80)
        case .info:  return Color(red: 0.33, green: 0.24, blue: 0.40)
        }
    }
}

private struct SettingsBox: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var engine: MacroEngine

    var body: some View {
        FrameSection(title: "Settings") {
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text("Discord").foregroundStyle(.secondary)
                        SecureField("webhook URL (alerts)", text: $store.settings.discordWebhook).textFieldStyle(.roundedBorder)
                        Button("Test") { engine.testDiscord() }
                            .controlSize(.mini).disabled(store.settings.discordWebhook.isEmpty)
                            .help("Sends a test message and says in the log whether Discord actually accepted it.")
                    }
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
                    Toggle("Game auto-skips card votes", isOn: $store.settings.cardsAutoSkipped).toggleStyle(.checkbox)
                        .help("Leave on while the game's own Auto-skip card votes setting is on: the macro then never spends time reading the card screen. Turn off if a card vote ever sits there unanswered.")
                }
            }
        }
    }
}

/// Session numbers big, lifetime numbers small. Only this window ticks every second.
private struct StatsBox: View {
    @EnvironmentObject var engine: MacroEngine
    @EnvironmentObject var store: Store
    @State private var now = Date()
    private static let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        FrameSection(title: "Statistics") {
            HStack(spacing: 4) {
                tile("runs", "\(engine.runsCompleted)", Pix.candy[3])
                tile("wins", "\(engine.wins)", Pix.candy[1])
                tile("losses", engine.unknowns > 0 ? "\(engine.losses)+\(engine.unknowns)?" : "\(engine.losses)", Pix.candy[0])
                tile("pearls", short(engine.sessionPearls), Pix.candy[5])
                tile("pearls/h", pearlsPerHour, Pix.candy[2])
                tile("✦ secrets", "\(engine.sessionSecrets)", Pix.candy[4])
            }
            HStack(spacing: 6) {
                Text("win rate").foregroundStyle(.secondary)
                RainbowBar(value: engine.wins + engine.losses == 0 ? 0 : Double(engine.wins) / Double(engine.wins + engine.losses))
                Text(engine.wins + engine.losses == 0 ? "—" : "\(engine.wins * 100 / max(1, engine.wins + engine.losses))%")
                    .monospaced().font(.system(size: 10))
            }
            row("map", engine.currentMap.isEmpty ? "—" : engine.currentMap)
            row("running for", elapsed)
            Rectangle().fill(Pix.ink.opacity(0.25)).frame(height: 1).padding(.vertical, 2)
            let s = store.stats
            Text("all time · since \(s.since.formatted(.dateTime.month(.abbreviated).day()))")
                .font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundStyle(.secondary)
            row("runs", "\(s.runs)  (\(s.wins)W / \(s.losses)L\(s.unknown > 0 ? " / \(s.unknown)?" : ""))")
            row("win rate", s.wins + s.losses == 0 ? "—" : "\(Int(s.winRate * 100))%")
            row("pearls", short(s.pearls) + (s.pearlsPerHour > 0 ? "  (\(short(s.pearlsPerHour))/h)" : ""))
            row("✦ secrets · hours", "\(s.secrets) · \(String(format: "%.1f", s.seconds / 3600))")
        }
        .onReceive(Self.tick) { now = $0 }
    }

    private var pearlsPerHour: String {
        guard let st = engine.startedAt else { return "—" }
        let h = now.timeIntervalSince(st) / 3600
        return h < 0.05 ? "—" : short(Int(Double(engine.sessionPearls) / h))
    }

    private var elapsed: String {
        guard let s = engine.startedAt else { return "—" }
        let t = Int(now.timeIntervalSince(s))
        return String(format: "%d:%02d:%02d", t / 3600, (t / 60) % 60, t % 60)
    }

    private func short(_ n: Int) -> String {
        n >= 1_000_000 ? String(format: "%.1fM", Double(n) / 1e6) : n >= 10_000 ? String(format: "%.1fk", Double(n) / 1e3) : "\(n)"
    }

    private func tile(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(spacing: 1) {
            Text(value).font(Pix.font(13, .black)).lineLimit(1).minimumScaleFactor(0.6)
            Text(label).font(Pix.font(8, .semibold)).foregroundStyle(Pix.muted)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 3).padding(.horizontal, 2)
        .pixelBox(color)
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack { Text(k).foregroundStyle(.secondary); Spacer(); Text(v).monospaced().lineLimit(1) }
            .font(.system(size: 10, design: .monospaced))
    }
}

private struct RecordBox: View {
    @EnvironmentObject var engine: MacroEngine
    @EnvironmentObject var recorder: Recorder
    @EnvironmentObject var store: Store
    @State private var mapName = ""

    var body: some View {
        FrameSection(title: "Record") {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Map name", text: $mapName).textFieldStyle(.roundedBorder)
                    if store.settings.mode == .portal {
                        // ── Portal tools (only in Portal mode) ──
                        HStack(spacing: 4) {
                            Button(engine.planTeaching ? "Stop & save plan" : "Teach portal") { engine.togglePlanTeach(name: mapName) }
                                .tint(engine.planTeaching ? .red : .pink).buttonStyle(.borderedProminent)
                                .help("At spawn: press, RIGHT-click your way to your spot, place your units, upgrade them in your order (click unit + R). Press again to save. Named after the Map name box.")
                            Button("Test plan") { engine.testPlan(name: mapName) }
                                .disabled(engine.planTeaching)
                                .help("In a match at spawn: walks, lines up, then places and upgrades exactly in your taught order.")
                        }
                        HStack(spacing: 4) {
                            Button(engine.walkRecording ? "Stop & save walk" : "Record walk") { engine.toggleRecordWalk(name: mapName) }
                                .tint(engine.walkRecording ? .red : .teal).buttonStyle(.borderedProminent)
                                .help("Portal groundwork: at spawn, press this, RIGHT-click your way to your setup spot, press again. Saves the clicks + the end view (named after the Map name box or the stage).")
                            Button("Test walk") { engine.testWalk(name: mapName) }
                                .disabled(engine.walkRecording)
                                .help("Replays the saved walk for this map from spawn, then lines up with the saved end view.")
                        }
                    } else if store.settings.mode == .dungeon {
                        // ── Dungeon tools (only in Dungeon mode): watch and learn, no input sent ──
                        Button(engine.dungeonWatching ? "Stop & save run" : "Watch my dungeon") { engine.toggleDungeonWatch() }
                            .tint(engine.dungeonWatching ? .red : .purple).buttonStyle(.borderedProminent)
                            .disabled(engine.state != .idle)
                            .help("Press before you start a dungeon, then play it yourself. Every tile, shop and relic choice and every match's walk, placements and upgrades are saved to the dungeon folder. Press again (or F6) when the run ends.")
                        Text(engine.dungeonStatus)
                            .font(.system(size: 9, design: .monospaced)).foregroundStyle(.purple).lineLimit(3)
                            .onAppear { engine.refreshDungeonStatus() }
                    } else {
                        // ── Summer Hunt tools ──
                        Button(engine.scanning ? "Stop scan" : "Scan map") {
                            if engine.scanning { engine.stop() } else { engine.scanMap(name: mapName) }
                        }
                        .tint(engine.scanning ? .red : .teal).buttonStyle(.borderedProminent)
                        .disabled(engine.state != .idle || recorder.isRecording)
                        .help("Start the stage and place one unit yourself first. Then: teleports to spawn, sets the camera, then tests every spot for ground + hill units and watches enemies to learn the lane. Name = the box above, or read from the title.")
                        Button(engine.teachNowActive ? "Stop teaching" : "Teach now") { engine.teachNow(name: mapName) }
                            .tint(engine.teachNowActive ? .red : .orange).buttonStyle(.borderedProminent)
                            .disabled(recorder.isRecording || engine.scanning)
                            .help("Teach placements any time. Macro running: it asks you for units for the rest of this match and the next one. Macro stopped: just play — every unit you place is saved for this map.")
                        Button("Test scan") { engine.testScan(name: mapName) }
                            .disabled(engine.state != .idle || recorder.isRecording || engine.scanning)
                            .help("In a stage on a scanned map: places each unit on its saved spots (middle of the map first) and reports how many spots were good.")
                    }
                    Text(engine.scanning ? engine.scanProgress : "\(store.profiles.count) maps known")
                        .font(.system(size: 9, design: .monospaced)).foregroundStyle(engine.scanning ? .teal : .secondary).lineLimit(2)
                }
            }
        }
    }
}

// MARK: - Mochi — the pixel slime companion in the top bar

/// A horizontal strip of square frames (64x64 each), drawn one frame at a time.
/// Sheets live in Resources/ as slime-<mood>.png. A mood whose sheet hasn't been drawn yet
/// falls back to the still icon, so new art lights up just by being dropped in the folder.
enum MochiSheet {
    struct Strip { let frames: [CGImage]; let fps: Double }

    private static var cache: [String: Strip?] = [:]

    static func named(_ name: String, fps: Double) -> Strip? {
        if let hit = cache[name] { return hit }          // nil results are cached too
        let strip = slice(name, fps: fps)
        cache[name] = strip
        return strip
    }

    /// The still app icon, for any mood with no sheet.
    static let still: CGImage? = load("slime") ?? load("AppIcon")

    private static func slice(_ name: String, fps: Double) -> Strip? {
        guard let img = load(name) else { return nil }
        let h = img.height
        guard h > 0, img.width >= h, img.width % h == 0 else { return nil }
        let frames = (0..<(img.width / h)).compactMap {
            img.cropping(to: CGRect(x: $0 * h, y: 0, width: h, height: h))
        }
        return frames.isEmpty ? nil : Strip(frames: frames, fps: fps)
    }

    private static func load(_ name: String) -> CGImage? {
        var urls: [URL] = []
        if let u = Bundle.main.url(forResource: name, withExtension: "png") { urls.append(u) }
        urls.append(FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop/AAMacro/Resources/\(name).png"))
        for u in urls {
            if let i = NSImage(contentsOf: u)?.cgImage(forProposedRect: nil, context: nil, hints: nil) { return i }
        }
        return nil
    }
}

/// Your slime, played from a sprite sheet. He naps while the macro farms — the same way you do —
/// wakes up for a win, a loss or trouble, and is awake and waiting whenever it's stopped.
struct Mochi: View {
    @ObservedObject var engine: MacroEngine
    @State private var mood: Mood = .awake
    @State private var moodUntil = Date.distantPast
    @State private var seenWins = -1
    @State private var seenLosses = -1
    @State private var seenSecrets = -1

    /// 32 would be pixel-exact on a Retina display, but the top bar is only 34pt tall.
    private static let size: CGFloat = 28

    enum Mood {
        case awake, napping, win, lose, worried, secret

        /// Which sheet plays, and how fast.
        var sheet: (name: String, fps: Double) {
            switch self {
            case .awake:   return ("slime-awake", 2)
            case .napping: return ("slime-sleep", 3)     // 15 frames = one 5-second breath
            case .win:     return ("slime-win", 8)
            case .lose:    return ("slime-lose", 4)
            case .worried: return ("slime-worried", 5)
            case .secret:  return ("slime-secret", 8)
            }
        }

        var line: String {
            switch self {
            case .awake:   return "がんばるぞ〜!"
            case .napping: return "zzz… すやすや"
            case .win:     return "やった〜!! WIN ♥"
            case .lose:    return "うぅ… next time!"
            case .worried: return "あれれ…?"
            case .secret:  return "✦ SECRET ✦ すごい!!"
            }
        }
    }

    private var strip: MochiSheet.Strip? {
        let s = mood.sheet
        return MochiSheet.named(s.name, fps: s.fps)
    }

    var body: some View {
        let sheet = strip
        let period = 1 / (sheet?.fps ?? 2)
        HStack(spacing: 5) {
            TimelineView(.periodic(from: .now, by: period)) { tl in
                let tick = Int(tl.date.timeIntervalSinceReferenceDate / period)
                ZStack {
                    if let sheet {
                        // The sheet carries its own z's, sparkles and tears — no overlays needed.
                        Image(decorative: sheet.frames[abs(tick) % sheet.frames.count], scale: 1)
                            .resizable().interpolation(.none)
                            .frame(width: Self.size, height: Self.size)
                    } else if let still = MochiSheet.still {
                        Image(decorative: still, scale: 1)
                            .resizable().interpolation(.none)
                            .frame(width: Self.size - 4, height: Self.size - 4)
                            .offset(y: abs(tick) % 4 < 2 ? 0 : -1)
                        extra(abs(tick))                  // stand-in until this mood has a sheet
                    } else {
                        Rectangle().fill(Color(red: 1.0, green: 0.55, blue: 0.80)).frame(width: 18, height: 14)
                    }
                }
                .frame(width: Self.size + 2, height: Self.size)
            }
            Text(mood.line)
                .font(Pix.font(9.5, .bold))
                .foregroundStyle(Pix.ink)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .pixelBox(Pix.paper)
                .fixedSize()
        }
        .onAppear {
            seenWins = engine.wins; seenLosses = engine.losses; seenSecrets = engine.sessionSecrets
            update()
        }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in update() }
        .help("Mochi")
    }

    /// Pixel extras drawn over the still icon for moods whose sheet isn't drawn yet.
    @ViewBuilder private func extra(_ tick: Int) -> some View {
        switch mood {
        case .napping:
            Text(tick % 2 == 0 ? "z" : "Z").font(Pix.font(8, .black))
                .foregroundStyle(Color(red: 0.45, green: 0.38, blue: 0.80))
                .offset(x: 13, y: tick % 2 == 0 ? -10 : -13)
        case .win, .secret:
            Text("✦").font(.system(size: 8)).foregroundStyle(.yellow)
                .offset(x: -13, y: tick % 2 == 0 ? -9 : -11)
            Text("♥").font(Pix.font(8, .black))
                .foregroundStyle(Color(red: 1.0, green: 0.35, blue: 0.55))
                .offset(x: 13, y: tick % 2 == 0 ? -11 : -9)
        case .lose:
            Rectangle().fill(Color(red: 0.50, green: 0.75, blue: 1.0)).frame(width: 2, height: 3)
                .offset(x: 6, y: CGFloat(tick % 4) * 2)
        case .worried:
            Text("?").font(Pix.font(9, .black)).foregroundStyle(Pix.ink).offset(x: 13, y: -11)
        case .awake:
            EmptyView()
        }
    }

    private func update() {
        // A reaction interrupts the nap for a while, then he settles back down.
        if engine.sessionSecrets > seenSecrets, seenSecrets >= 0 {
            mood = .secret; moodUntil = Date().addingTimeInterval(40)
        } else if engine.wins > seenWins, seenWins >= 0 {
            mood = .win; moodUntil = Date().addingTimeInterval(25)
        } else if engine.losses > seenLosses, seenLosses >= 0 {
            mood = .lose; moodUntil = Date().addingTimeInterval(25)
        }
        seenWins = engine.wins; seenLosses = engine.losses; seenSecrets = engine.sessionSecrets
        if Date() < moodUntil { return }
        if engine.state == .idle { mood = .awake }
        else if engine.state == .recovering || engine.journal.lines.last?.kind == .warn { mood = .worried }
        else { mood = .napping }        // farming: he sleeps through it, like you
    }
}
