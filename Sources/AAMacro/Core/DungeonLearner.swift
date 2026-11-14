import Foundation

/// Turns watched runs into DungeonKnowledge. Pure: no screen, no input, no files.
enum DungeonLearner {

    static func build(from runs: [DungeonRun]) -> DungeonKnowledge {
        var k = DungeonKnowledge()
        k.runs = runs.count
        for run in runs.sorted(by: { $0.startedAt < $1.startedAt }) {
            for d in run.decisions {
                var offered: [String] = []
                for o in d.options where !offered.contains(o.text) { offered.append(o.text) }
                // A choice needs something to choose between, and a pick we could name.
                guard offered.count >= 2, !d.picked.isEmpty else { continue }
                k.decisions += 1
                for name in offered { k.options[name, default: DungeonOptionStat()].offered += 1 }
                for p in d.picked {
                    k.options[p, default: DungeonOptionStat()].picked += 1
                    for other in offered where !d.picked.contains(other) { k.beats["\(p)>\(other)", default: 0] += 1 }
                }
            }
            for m in run.matches where !m.steps.isEmpty {
                switch m.outcome {
                case .victory: k.matchesWon += 1
                case .defeat:  k.matchesLost += 1
                case .unknown: break
                }
                guard m.outcome == .victory, m.map != "unknown" else { continue }
                k.plans[m.map] = plan(from: m, runID: run.id)        // a later win replaces an earlier one
                if m.usedMoveKeys && m.walk.isEmpty {
                    if !k.keyWalkMaps.contains(m.map) { k.keyWalkMaps.append(m.map) }
                } else {
                    k.keyWalkMaps.removeAll { $0 == m.map }
                }
            }
        }
        return k
    }

    /// A watched match in the same form Portal's taught plans use, so the same code can play it.
    static func plan(from m: DungeonMatchLog, runID: String) -> PortalPlan {
        var walk: WalkRecording?
        if !m.walk.isEmpty {
            walk = WalkRecording(name: m.map, clicks: m.walk, gaps: m.walkGaps,
                                 referenceImage: m.walkEndShot.map { "runs/\(runID)/\($0)" })
        }
        let actions: [PortalPlan.Action] = m.steps.map { s in
            switch s.kind {
            case .place:   return .place(slot: s.slot, at: s.at)
            case .upgrade: return .upgrade(unit: s.unit, times: s.times)
            }
        }
        return PortalPlan(name: m.map, walk: walk, actions: actions)
    }
}

/// What the macro WOULD pick. Not connected to any input yet — step 3 of the dungeon plan.
enum DungeonPolicy {
    struct Choice {
        let name: String
        /// False = it hasn't seen you decide this clearly enough; the autopilot must stop and ask.
        let confident: Bool
        let why: String
    }

    static func choose(among names: [String], knowledge k: DungeonKnowledge) -> Choice? {
        guard !names.isEmpty else { return nil }
        let ranked = names.sorted { (k.options[$0]?.score ?? 0.5) > (k.options[$1]?.score ?? 0.5) }
        let best = ranked[0]
        guard ranked.count > 1 else { return Choice(name: best, confident: true, why: "only option") }
        // Confident only when every option has been seen at least twice, you took the best one
        // over each of the others at least once, and never the other way round.
        var confident = names.allSatisfy { (k.options[$0]?.offered ?? 0) >= 2 }
        for other in ranked.dropFirst() {
            let forBest = k.beats["\(best)>\(other)"] ?? 0, against = k.beats["\(other)>\(best)"] ?? 0
            if forBest == 0 || against > 0 { confident = false }
        }
        let st = k.options[best] ?? DungeonOptionStat()
        return Choice(name: best, confident: confident, why: "taken \(st.picked) of \(st.offered) times offered")
    }
}
