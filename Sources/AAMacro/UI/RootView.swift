import SwiftUI
import AppKit

/// The macro page.
struct RootView: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        TabView {
            RunView().tabItem { Label("Run", systemImage: "play.circle") }
            MapDataView().tabItem { Label("Map data", systemImage: "square.grid.3x3") }
            MapsView().tabItem { Label("Recordings", systemImage: "map") }
            SettingsView().tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .padding()
        .onAppear { DockPanel.shared.openMainWindow = { openWindow(id: "main") } }
    }
}

// MARK: - Run tab: start/stop, current state, live log

struct RunView: View {
    @EnvironmentObject var engine: MacroEngine
    @EnvironmentObject var store: Store

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button(engine.state == .idle ? "Start" : "Stop") {
                    if engine.state == .idle { engine.start() } else { engine.stop() }
                }
                .keyboardShortcut(.return)
                .buttonStyle(.borderedProminent)
                Text("State: \(engine.state.rawValue)").monospaced()
                Spacer()
                Text("Runs: \(engine.runsCompleted)")
                Text("Maps recorded: \(store.maps.count)").foregroundStyle(.secondary)
            }
            Text("F6 stops everything, anytime.").font(.caption).foregroundStyle(.secondary)
            ScrollViewReader { proxy in
                List(engine.log.indices, id: \.self) { i in
                    Text(engine.log[i]).font(.system(.caption, design: .monospaced)).id(i)
                }
                .onChange(of: engine.log.count) { _, n in proxy.scrollTo(n - 1) }
            }
        }
    }
}

// MARK: - Maps tab: record new maps, edit a recording's action list

struct MapsView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var recorder: Recorder
    @State private var newName = ""
    @State private var selection: MapRecording.ID?

    var body: some View {
        HSplitView {
            VStack(alignment: .leading) {
                List(store.maps, selection: $selection) { m in
                    VStack(alignment: .leading) {
                        Text(m.name).bold()
                        Text("\(m.actions.count) actions · keywords: \(m.keywords.joined(separator: ", "))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    TextField("Stage name (e.g. Planet Namak)", text: $newName)
                    Button(recorder.isRecording ? "Stop & save" : "Record") {
                        if recorder.isRecording { recorder.stop() }
                        else if !newName.isEmpty { recorder.start(mapName: newName) }
                    }
                    .tint(recorder.isRecording ? .red : .accentColor)
                }
                if recorder.isRecording {
                    Text("Recording… \(recorder.actions.count) actions. Play the map normally; F6 also stops.")
                        .font(.caption).foregroundStyle(.red)
                }
            }
            .frame(minWidth: 260)

            if let id = selection, let i = store.maps.firstIndex(where: { $0.id == id }) {
                MapEditor(map: $store.maps[i])
            } else {
                Text("Select a map to edit its steps").foregroundStyle(.secondary).frame(maxWidth: .infinity)
            }
        }
    }
}

/// Reorder/delete recorded steps and edit recognition keywords.
struct MapEditor: View {
    @Binding var map: MapRecording
    @EnvironmentObject var store: Store
    @State private var keywords = ""

    var body: some View {
        VStack(alignment: .leading) {
            Text(map.name).font(.title2).bold()
            HStack {
                TextField("Keywords (comma separated)", text: $keywords)
                Button("Apply") {
                    map.keywords = keywords.lowercased().split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    store.save(map)
                }
            }
            List {
                ForEach(map.actions) { a in Text(a.label).monospaced() }
                    .onMove { map.actions.move(fromOffsets: $0, toOffset: $1); store.save(map) }
                    .onDelete { map.actions.remove(atOffsets: $0); store.save(map) }
            }
            HStack {
                Button("Add 'wait for wave'") { map.actions.append(.waitForWave(5)); store.save(map) }
                Spacer()
                Button("Delete map", role: .destructive) { store.delete(map) }
            }
        }
        .padding(.leading)
        .onAppear { keywords = map.keywords.joined(separator: ", ") }
    }
}

// MARK: - Settings tab: upgrade priority, keys, timing

struct SettingsView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var recorder: Recorder

    var body: some View {
        Form {
            Section("Upgrade priority") {
                Text("Units in these hotbar slots are placed and upgraded before everything else.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    ForEach(1...6, id: \.self) { slot in
                        Toggle("Slot \(slot)", isOn: Binding(
                            get: { store.settings.prioritySlots.contains(slot) },
                            set: { on in
                                if on { store.settings.prioritySlots.append(slot) }
                                else { store.settings.prioritySlots.removeAll { $0 == slot } }
                            }))
                        .toggleStyle(.button)
                    }
                }
                Text("Order: \(store.settings.prioritySlots.map(String.init).joined(separator: " → "))")
                    .font(.caption)
            }
            Section("Controls") {
                TextField("Upgrade key", text: $store.settings.upgradeKey)
                Stepper("Input delay: \(store.settings.inputDelayMs) ms",
                        value: $store.settings.inputDelayMs, in: 20...300, step: 10)
                Stepper("Stop after \(store.settings.maxRuns == 0 ? "∞" : String(store.settings.maxRuns)) runs",
                        value: $store.settings.maxRuns, in: 0...500)
            }
            Section("Auto mode (no recording needed)") {
                Toggle("Play maps without a recording automatically", isOn: $store.settings.autoWhenNoRecording)
                Toggle("Use auto mode even when a recording exists", isOn: $store.settings.preferAuto)
                Toggle("Save winning auto layouts as recordings", isOn: $store.settings.autoSaveWins)
                SlotListField(slots: $store.settings.autoPlaceOrder, placeholder: "Placement order, e.g. 6 1 3")
                Text("e.g. \"1 1 3 2 4\" — a slot can repeat. Priority slots (above) get upgraded first.")
                    .font(.caption).foregroundStyle(.secondary)
                Stepper("Early upgrades on priority units: \(store.settings.autoEarlyUpgrades)",
                        value: $store.settings.autoEarlyUpgrades, in: 0...10)
            }
            Section("Cards") {
                Text("Ranking: green buffs (minus excluded words) → OK debuffs → excluded buffs → other debuffs. Priority breaks ties inside a group; Avoid always goes last. One word or name per line.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(alignment: .top) {
                    VStack(alignment: .leading) {
                        Text("Skip buffs mentioning").font(.caption).bold()
                        TextEditor(text: lines($store.settings.cardBuffExclude)).frame(height: 60).monospaced()
                    }
                    VStack(alignment: .leading) {
                        Text("Debuffs that are OK").font(.caption).bold()
                        TextEditor(text: lines($store.settings.cardOkDebuffs)).frame(height: 60).monospaced()
                    }
                }
                HStack(alignment: .top) {
                    VStack(alignment: .leading) {
                        Text("Priority (best → worst)").font(.caption).bold()
                        TextEditor(text: lines($store.settings.cardPriority)).frame(height: 120).monospaced()
                    }
                    VStack(alignment: .leading) {
                        Text("Avoid").font(.caption).bold()
                        TextEditor(text: lines($store.settings.cardAvoid)).frame(height: 120).monospaced()
                    }
                }
            }
            Section("Lobby walk (spawn → summer event)") {
                Text("\(store.settings.lobbyWalk.count) steps recorded").font(.caption)
                Button(recorder.isRecording ? "Stop & save lobby walk" : "Record lobby walk") {
                    if recorder.isRecording {
                        if let rec = recorder.stop() {
                            store.settings.lobbyWalk = rec.actions
                            store.delete(rec)       // not a real map; only keep the walk
                        }
                    } else {
                        recorder.start(mapName: "_lobby_walk")
                    }
                }
            }
            Section("Folders") {
                Text("Templates (cropped buttons): \(store.templatesDir.path)").textSelection(.enabled).font(.caption)
                Button("Open data folder") { NSWorkspace.shared.open(store.root) }
            }
        }
        .formStyle(.grouped)
    }

    /// Edits a [String] as newline-separated text.
    private func lines(_ list: Binding<[String]>) -> Binding<String> {
        Binding(
            get: { list.wrappedValue.joined(separator: "\n") },
            set: { list.wrappedValue = $0.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) }
        )
    }
}


// MARK: - Map data tab: what the macro knows about each map

struct MapDataView: View {
    @EnvironmentObject var store: Store
    @State private var confirmDelete: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Everything the macro has learned per map. Maps that lose a lot may need their own [Map] steps, or a fresh start with \"Forget layout\".")
                .font(.caption).foregroundStyle(.secondary)
            Table(store.profiles.sorted { $0.name < $1.name }) {
                TableColumn("Map") { p in Text(p.name).bold() }
                TableColumn("W / L") { p in
                    let w = p.wins ?? 0, l = p.losses ?? 0
                    Text("\(w) / \(l)").foregroundStyle(l > w ? .orange : .primary)
                }.width(60)
                TableColumn("Taught") { p in Text("\(p.taught?.count ?? 0)") }.width(55)
                TableColumn("Learned") { p in Text("\(p.learned?.count ?? 0)") }.width(60)
                TableColumn("Ground / Hill") { p in Text("\(p.ground.count) / \(p.hill.count)") }.width(90)
                TableColumn("Bad spots") { p in Text("\((p.badGround?.count ?? 0) + (p.badHill?.count ?? 0))") }.width(70)
                TableColumn("") { p in
                    HStack {
                        Button("Forget layout") {
                            var q = p; q.learned = nil; store.saveProfile(q)
                        }.help("Clears the automatically learned layout (keeps taught spots and the scan)")
                        Button("Forget taught") {
                            var q = p; q.taught = nil; store.saveProfile(q)
                        }.disabled((p.taught ?? []).isEmpty)
                        Button("Clear bad spots") {
                            var q = p; q.badGround = nil; q.badHill = nil; q.suspectGround = nil; q.suspectHill = nil
                            store.saveProfile(q)
                        }.help("Use after changing your team: spots that failed for old units may suit new ones")
                        Button("Delete", role: .destructive) { confirmDelete = p.name }
                    }.controlSize(.small)
                }
            }
        }
        .alert("Delete everything saved for \(confirmDelete ?? "")?", isPresented: Binding(
            get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
            Button("Delete", role: .destructive) { if let n = confirmDelete { store.deleteProfile(n) }; confirmDelete = nil }
            Button("Cancel", role: .cancel) { confirmDelete = nil }
        } message: {
            Text("Its scan, taught spots, learned layout and record are removed. It will be learned again from scratch.")
        }
    }
}
