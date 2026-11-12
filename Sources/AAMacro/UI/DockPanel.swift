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

/// Y2K "pastel desktop" theme ✦ — every section is a little retro window: lavender outline,
/// gradient title bar with tiny window buttons, hard drop shadow, on a pastel grid background.
private enum Theme {
    static let bgTop = Color(red: 0.99, green: 0.93, blue: 0.97)      // milky pink
    static let bgMid = Color(red: 0.95, green: 0.93, blue: 1.00)      // milky lavender
    static let bgBottom = Color(red: 0.92, green: 0.96, blue: 1.00)   // milky blue
    static let grid = Color.white.opacity(0.45)
    static let outline = Color(red: 0.55, green: 0.47, blue: 0.90)    // periwinkle outline
    static let shadow = Color(red: 0.62, green: 0.55, blue: 0.95).opacity(0.55)
    static let card = Color(red: 0.99, green: 0.98, blue: 1.00)
    static let line = Color(red: 0.80, green: 0.75, blue: 1.00)
    static let accent = Color(red: 1.00, green: 0.45, blue: 0.70)     // bubblegum pink
    static let mint = Color(red: 0.55, green: 0.88, blue: 0.75)
    static let ink = Color(red: 0.30, green: 0.25, blue: 0.48)        // soft indigo text
    static let title = Color(red: 0.36, green: 0.30, blue: 0.62)
    static let titleBar = LinearGradient(colors: [Color(red: 0.84, green: 0.80, blue: 1.00),
                                                  Color(red: 0.98, green: 0.82, blue: 0.93),
                                                  Color(red: 0.82, green: 0.92, blue: 1.00)],
                                         startPoint: .leading, endPoint: .trailing)
    static let rainbow: [Color] = [Color(red: 1, green: 0.62, blue: 0.75), Color(red: 1, green: 0.78, blue: 0.62),
                                   Color(red: 1, green: 0.93, blue: 0.62), Color(red: 0.70, green: 0.92, blue: 0.70),
                                   Color(red: 0.62, green: 0.85, blue: 1.00), Color(red: 0.75, green: 0.70, blue: 1.00)]

    /// A little icon in front of every window title.
    static func decorate(_ title: String) -> String {
        if title.hasPrefix("Unit ") {
            let icons = ["🌸", "🍓", "🍡", "🧁", "🍑", "⭐️"]
            let n = Int(title.dropFirst(5)) ?? 1
            return "\(icons[(n - 1 + icons.count) % icons.count]) unit \(n)"
        }
        switch title {
        case "Auto placement": return "🪄 auto placement"
        case "Current Process": return "💻 what i'm doing.exe"
        case "Settings": return "🎀 settings"
        case "Statistics": return "🏆 my stats"
        case "Record": return "📁 record & teach"
        default: return "✦ \(title.lowercased())"
        }
    }
}

/// Pixel-art look: flat colours, hard edges, no gradients/blur/soft shadows (cheap to draw).
enum Pix {
    static let ink = Color(red: 0.24, green: 0.17, blue: 0.33)          // dark plum outline
    static let paper = Color(red: 1.00, green: 0.97, blue: 0.99)
    static let bg = Color(red: 0.98, green: 0.90, blue: 0.95)           // flat pastel pink
    static let dot = Color(red: 0.93, green: 0.80, blue: 0.90)
    static let font = Font.system(size: 11, weight: .semibold, design: .monospaced)
    static func font(_ size: CGFloat, _ w: Font.Weight = .bold) -> Font { .system(size: size, weight: w, design: .monospaced) }
}

/// Flat pastel background with a sparse pixel dot pattern (drawn once, off the main thread).
private struct PastelGrid: View {
    var body: some View {
        ZStack {
            Pix.bg
            Canvas(rendersAsynchronously: true) { ctx, size in
                var y: CGFloat = 6
                var row = 0
                while y < size.height {
                    var x: CGFloat = row % 2 == 0 ? 6 : 18
                    while x < size.width { ctx.fill(Path(CGRect(x: x, y: y, width: 2, height: 2)), with: .color(Pix.dot)); x += 24 }
                    y += 12; row += 1
                }
            }
        }
    }
}

/// A chunky pixel box: 2 px dark outline, light top-left bevel, dark bottom-right bevel.
struct PixelBox: ViewModifier {
    var fill: Color
    var pressed = false
    func body(content: Content) -> some View {
        content
            .background(
                ZStack {
                    Rectangle().fill(Pix.ink)
                    Rectangle().fill(fill).padding(2)
                    // bevel
                    VStack(spacing: 0) {
                        Rectangle().fill(.white.opacity(pressed ? 0 : 0.75)).frame(height: 2)
                        Spacer(minLength: 0)
                    }.padding(2)
                    HStack(spacing: 0) {
                        Rectangle().fill(.white.opacity(pressed ? 0 : 0.75)).frame(width: 2)
                        Spacer(minLength: 0)
                    }.padding(2)
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        Rectangle().fill(Pix.ink.opacity(pressed ? 0.05 : 0.22)).frame(height: 2)
                    }.padding(2)
                    HStack(spacing: 0) {
                        Spacer(minLength: 0)
                        Rectangle().fill(Pix.ink.opacity(pressed ? 0.05 : 0.22)).frame(width: 2)
                    }.padding(2)
                }
            )
            // hard 2 px drop shadow, the classic pixel-UI look
            .background(Rectangle().fill(Pix.ink.opacity(0.35)).offset(x: 3, y: 3))
    }
}

extension View {
    func pixelBox(_ fill: Color, pressed: Bool = false) -> some View { modifier(PixelBox(fill: fill, pressed: pressed)) }
}

/// Segmented pixel health bar.
struct RainbowBar: View {
    var value: Double          // 0…1
    var segments = 12
    var body: some View {
        HStack(spacing: 1) {
            ForEach(0..<segments, id: \.self) { i in
                Rectangle()
                    .fill(Double(i) < value * Double(segments) ? Theme.rainbow[i * Theme.rainbow.count / segments] : Pix.paper)
                    .frame(height: 8)
            }
        }
        .padding(2)
        .background(Rectangle().fill(Pix.ink))
    }
}

/// Each window gets its own flat candy colour (units cycle pink, mint, lavender, blue, peach, lemon).
private func jellyTint(for title: String) -> Color {
    let palette: [Color] = [Color(red: 1.00, green: 0.80, blue: 0.89), Color(red: 0.76, green: 0.95, blue: 0.87),
                            Color(red: 0.87, green: 0.82, blue: 1.00), Color(red: 0.80, green: 0.89, blue: 1.00),
                            Color(red: 1.00, green: 0.87, blue: 0.80), Color(red: 1.00, green: 0.95, blue: 0.76)]
    if title.hasPrefix("Unit "), let n = Int(title.dropFirst(5)) { return palette[(n - 1) % palette.count] }
    switch title {
    case "Auto placement": return palette[2]
    case "Current Process": return palette[3]
    case "Settings": return palette[0]
    case "Statistics": return palette[1]
    case "Record": return palette[4]
    default: return palette[2]
    }
}

private struct FrameSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        let tint = jellyTint(for: title)
        VStack(alignment: .leading, spacing: 0) {
            // solid title strip
            HStack(spacing: 4) {
                Text(Theme.decorate(title)).font(Pix.font(10.5, .heavy)).foregroundStyle(Pix.ink).lineLimit(1)
                Spacer(minLength: 2)
                HStack(spacing: 2) {      // tiny pixel window buttons
                    ForEach(0..<3, id: \.self) { _ in Rectangle().fill(Pix.paper).frame(width: 7, height: 7)
                        .overlay(Rectangle().strokeBorder(Pix.ink, lineWidth: 1.5)) }
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(tint)
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
            .tint(Color(red: 1.0, green: 0.45, blue: 0.70))
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
    private static let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

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
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                    Image(systemName: "chevron.right")
                    Image(systemName: "arrow.clockwise")
                }
                .font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.outline)
                HStack(spacing: 4) {
                    Text("☆").foregroundStyle(Theme.accent)
                    Text(running ? "welcome to aa macro ♡ — \(engine.state.rawValue)" : (recorder.isRecording ? "recording…" : "welcome to aa macro ♡ — napping 💤"))
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced)).lineLimit(1)
                }
                .padding(.horizontal, 10).padding(.vertical, 3)
                .frame(minWidth: 220, alignment: .leading)
                .background(Capsule().fill(Color.white.opacity(0.85)))
                .overlay(Capsule().stroke(Theme.outline, lineWidth: 1.2))
                Spacer()
                check("Screen", screen); check("Access", access); check("Roblox", roblox)
                if !(screen && access) {
                    Button("Fix") {
                        Permissions.requestIfNeeded()
                        let pane = access ? "Privacy_ScreenCapture" : "Privacy_Accessibility"
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
                    }.controlSize(.mini)
                }
                Button {
                    if running { engine.stop() } else { engine.start() }
                } label: {
                    Text(running ? "■ STOP (F6)" : "▶ START")
                        .font(Pix.font(12, .black))
                        .foregroundStyle(Pix.ink)
                        .padding(.horizontal, 12).padding(.vertical, 4)
                        .pixelBox(running ? Color(red: 1.0, green: 0.70, blue: 0.72) : Color(red: 1.0, green: 0.78, blue: 0.90))
                }
                .buttonStyle(.plain)
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
            Image(systemName: ok ? "heart.fill" : "heart.slash.fill").foregroundStyle(ok ? Theme.accent : .gray)
            Text(name).foregroundStyle(.secondary)
        }.font(.system(size: 10, design: .monospaced))
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
                        .foregroundStyle(Theme.title).frame(maxWidth: .infinity)
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible())], spacing: 6) {
                        ForEach(1...6, id: \.self) { UnitCard(slot: $0) }
                    }
                    FrameSection(title: "Auto placement") {
                        Toggle("Auto on maps without a recording", isOn: $store.settings.autoWhenNoRecording)
                        Toggle("Always use auto", isOn: $store.settings.preferAuto)
                        Toggle("Save winning layouts", isOn: $store.settings.autoSaveWins)
                        Toggle("Learn unscanned maps while playing", isOn: $store.settings.learnWhilePlaying)
                            .help("Once the team is placed, scan the map mid-match and save it for next time.")
                        Toggle("Teach mode (I place units on new maps)", isOn: $store.settings.teachMode)
                        Toggle("   …only ask me for hill units", isOn: $store.settings.teachHillsOnly)
                            .disabled(!store.settings.teachMode)
                            .help("Ground units are placed automatically (they already do well); you only place the hill units once per map.")
                            .help("On a map you haven't taught yet, you place the units yourself and pick cards; the macro saves where each slot went. Maps already taught play automatically. Turn off before sleeping.")
                        Text("Taught maps: \(store.profiles.filter { !($0.taught ?? []).isEmpty }.map(\.name).sorted().joined(separator: ", ").isEmpty ? "none yet" : store.profiles.filter { !($0.taught ?? []).isEmpty }.map(\.name).sorted().joined(separator: ", "))")
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
                Text("upgrade order #\(rank + 1)").font(.system(size: 9, design: .monospaced)).foregroundStyle(Theme.accent)
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
                                        .foregroundStyle(line.contains("⚠️") ? Color.orange : (line.contains("✓") ? Color(red: 0.2, green: 0.6, blue: 0.45) : Color(red: 0.33, green: 0.24, blue: 0.40)))
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
                        Text("Discord").foregroundStyle(.secondary)
                        SecureField("webhook URL (alerts)", text: $store.settings.discordWebhook).textFieldStyle(.roundedBorder)
                        Button("Test") {
                            Discord.send("💖 AA Macro test message — Discord alerts are working!", webhook: store.settings.discordWebhook)
                        }.controlSize(.mini).disabled(store.settings.discordWebhook.isEmpty)
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
                                        }
                    }
                }
                .controlSize(.mini)

                FrameSection(title: "Statistics") {
                    stat("Map", engine.currentMap.isEmpty ? "—" : engine.currentMap)
                    stat("Runs", "\(engine.runsCompleted)")
                    stat("Wins / Losses", "\(engine.wins) / \(engine.losses)")
                    HStack(spacing: 6) {
                        Text("win rate").foregroundStyle(.secondary)
                        RainbowBar(value: engine.wins + engine.losses == 0 ? 0 : Double(engine.wins) / Double(engine.wins + engine.losses))
                        Text(engine.wins + engine.losses == 0 ? "—" : "\(engine.wins * 100 / max(1, engine.wins + engine.losses))%")
                            .monospaced().font(.system(size: 10))
                    }
                    stat("Running for", elapsed)
                    stat("Summer Pearls", "\(engine.sessionPearls)")
                    stat("Pearls / hour", {
                        guard let st = engine.startedAt else { return "—" }
                        let h = Date().timeIntervalSince(st) / 3600
                        return h < 0.05 ? "—" : "\(Int(Double(engine.sessionPearls) / h))"
                    }())
                    stat("✦ Secrets", engine.sessionSecrets == 0 ? "none yet" : "\(engine.sessionSecrets) ✦")
                    stat("Maps recorded", "\(store.maps.filter { !$0.name.hasPrefix("_") }.count)")
                    stat("Maps scanned", "\(store.profiles.count)")
                }

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
                    } else {
                        // ── Summer Hunt tools ──
                        Button(recorder.isRecording ? "Stop & save" : "Record map") {
                            if recorder.isRecording { recorder.stop() } else if !mapName.isEmpty { recorder.start(mapName: mapName) }
                        }
                        .tint(recorder.isRecording ? .red : Theme.accent).buttonStyle(.borderedProminent)
                        .disabled(engine.state != .idle)
                        Text(recorder.isRecording ? "\(recorder.actions.count) steps" : "Start during the vote screen")
                            .font(.system(size: 9, design: .monospaced)).foregroundStyle(recorder.isRecording ? .red : .secondary)
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
                    Text(engine.scanning ? engine.scanProgress : "\(store.profiles.count) maps scanned")
                        .font(.system(size: 9, design: .monospaced)).foregroundStyle(engine.scanning ? .teal : .secondary).lineLimit(2)
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


// MARK: - Mochi ♡ — the pixel slime companion in the top bar

/// Your slime sprite (the app icon), drawn crisp at 2×, with a 4-fps bob and little pixel extras:
/// "z" while asleep, sparkles + hearts after a win, a tear after a loss, "?" when worried.
struct Mochi: View {
    @ObservedObject var engine: MacroEngine
    @State private var mood: Mood = .sleepy
    @State private var moodUntil = Date.distantPast
    @State private var seenWins = -1
    @State private var seenLosses = -1

    enum Mood { case sleepy, happy, party, sad, worried }

    static let sprite: NSImage? = {
        if let u = Bundle.main.url(forResource: "slime", withExtension: "png"), let i = NSImage(contentsOf: u) { return i }
        let dev = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop/AAMacro/Resources/AppIcon.png")
        return NSImage(contentsOf: dev)
    }()

    private var line: String {
        switch mood {
        case .sleepy:  return "zzz… すやすや"
        case .happy:   return "がんばるぞ〜!"
        case .party:   return "やった〜!! WIN ♥"
        case .sad:     return "うぅ… next time!"
        case .worried: return "あれれ…?"
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            TimelineView(.periodic(from: .now, by: mood == .sleepy ? 0.8 : 0.25)) { tl in
                let frame = Int(tl.date.timeIntervalSinceReferenceDate / (mood == .sleepy ? 0.8 : 0.25))
                let hop: CGFloat = mood == .party ? (frame % 2 == 0 ? -3 : 0) : (frame % 4 < 2 ? 0 : -1)
                ZStack {
                    if let img = Self.sprite {
                        Image(nsImage: img).resizable().interpolation(.none).frame(width: 26, height: 26)
                    } else {
                        Rectangle().fill(Color(red: 1.0, green: 0.55, blue: 0.80)).frame(width: 18, height: 14)
                    }
                    extra(frame: frame)
                }
                .offset(y: hop)
                .frame(width: 30, height: 28)
            }
            Text(line)
                .font(Pix.font(9.5, .bold))
                .foregroundStyle(Pix.ink)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .pixelBox(Pix.paper)
                .fixedSize()
        }
        .onAppear { seenWins = engine.wins; seenLosses = engine.losses; update() }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in update() }
        .help("Mochi ♡")
    }

    @ViewBuilder private func extra(frame: Int) -> some View {
        switch mood {
        case .sleepy:
            Text(frame % 2 == 0 ? "z" : "Z").font(Pix.font(8, .black)).foregroundStyle(Color(red: 0.45, green: 0.38, blue: 0.80))
                .offset(x: 13, y: frame % 2 == 0 ? -10 : -13)
        case .party:
            Text("✦").font(.system(size: 8)).foregroundStyle(.yellow).offset(x: -13, y: frame % 2 == 0 ? -9 : -11)
            Text("♥").font(Pix.font(8, .black)).foregroundStyle(Color(red: 1.0, green: 0.35, blue: 0.55)).offset(x: 13, y: frame % 2 == 0 ? -11 : -9)
        case .sad:
            Rectangle().fill(Color(red: 0.50, green: 0.75, blue: 1.0)).frame(width: 2, height: 3).offset(x: 6, y: CGFloat(frame % 4) * 2)
        case .worried:
            Text("?").font(Pix.font(9, .black)).foregroundStyle(Pix.ink).offset(x: 13, y: -11)
        case .happy:
            EmptyView()
        }
    }

    private func update() {
        if engine.wins > seenWins, seenWins >= 0 { mood = .party; moodUntil = Date().addingTimeInterval(25) }
        if engine.losses > seenLosses, seenLosses >= 0 { mood = .sad; moodUntil = Date().addingTimeInterval(25) }
        seenWins = engine.wins; seenLosses = engine.losses
        if Date() < moodUntil { return }
        if engine.state == .idle { mood = .sleepy }
        else if engine.state == .recovering || (engine.log.last?.contains("⚠️") ?? false) { mood = .worried }
        else { mood = .happy }
    }
}
