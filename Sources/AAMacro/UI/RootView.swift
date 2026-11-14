import SwiftUI
import AppKit

/// The macro page.
struct RootView: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        TabView {
            RunView().tabItem { Label("Run", systemImage: "play.circle") }
            MapDataView().tabItem { Label("Map data", systemImage: "square.grid.3x3") }
            SettingsView().tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .padding()
        .fontDesign(.monospaced)
        .tint(Color(red: 1.00, green: 0.45, blue: 0.68))
        .background(Color(red: 0.98, green: 0.92, blue: 0.96))
        .environment(\.colorScheme, .light)
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
                Text("Maps known: \(store.profiles.count)").foregroundStyle(.secondary)
            }
            Text("F6 stops everything, anytime.").font(.caption).foregroundStyle(.secondary)
            FullLog(journal: engine.journal)
        }
    }
}

/// The whole log (the dock shows the last 80 lines; this shows everything kept in memory).
struct FullLog: View {
    @ObservedObject var journal: MacroJournal
    var body: some View {
        ScrollViewReader { proxy in
            List(journal.lines) { line in
                Text(line.text).font(.system(.caption, design: .monospaced)).id(line.id)
            }
            .onChange(of: journal.lines.last?.id) { _, id in if let id { proxy.scrollTo(id) } }
        }
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
            Section("Auto placement") {
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
            Section("Lifetime stats") {
                let st = store.stats
                Text("\(st.runs) runs · \(st.wins)W / \(st.losses)L\(st.unknown > 0 ? " / \(st.unknown) unknown" : "") · \(st.pearls) pearls · \(st.secrets) secrets · \(String(format: "%.1f", st.seconds / 3600)) h since \(st.since.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption)
                Text("Runs before Nov 10, 2026 were seeded from the log files (pearls weren't logged then).")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Reset lifetime stats", role: .destructive) { store.resetStats() }
            }
            Section("Folders") {
                Text("Data: \(store.root.path)").textSelection(.enabled).font(.caption)
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
                TableColumn("Hills?") { p in
                    Button(p.noHills == true ? "none ↺" : "yes") {
                        var q = p; q.noHills = (p.noHills == true) ? nil : true; store.saveProfile(q)
                    }.buttonStyle(.borderless).help("\"none\" = hill units skip the search on this map. Click to toggle.")
                }.width(60)
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
