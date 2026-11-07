import Foundation
import CoreGraphics
import AppKit

/// Auto-placement without recordings.
///
/// While you hold a unit, the game paints the map: GREEN where that unit can go (hill units:
/// only hills), RED on the enemy lane and on spots that are taken. Maps differ a lot in color
/// (grass, rain, red roofs), so we compare two screenshots — one WITHOUT a unit held and one
/// WITH — and only trust cells that *changed* toward green or red.
///
/// Spots are then restricted to green cells close to the red lane, with room around them,
/// and scored by how much lane is in the unit's range.
struct AutoPlanner {
    static let cols = 160, rows = 100

    enum Cell: UInt8 { case other, green, red }

    let grid: [Cell]
    let path: [Bool]
    /// Cells covered by the HUD (never placeable).
    let hudMask: [Bool]
    /// True when the lane came from watching enemies rather than from colours.
    let laneFromEnemies: Bool
    /// True when this unit's overlay shows green spots → a hill unit (only green is placeable).
    /// Ground units get no green at all: everything that didn't turn red is allowed.
    var isHillOverlay: Bool { greenCellCount >= 120 }
    /// Distance (in cells) from every cell to the nearest lane cell.
    let distToPath: [Int]

    /// Screen areas covered by HUD — never treated as map.
    static let hud: [CGRect] = [
        CGRect(x: 0.00, y: 0.00, width: 1.00, height: 0.20),   // title, wave, top buttons
        CGRect(x: 0.25, y: 0.20, width: 0.50, height: 0.035),  // boss health bar (just under the top HUD)
        CGRect(x: 0.33, y: 0.74, width: 0.34, height: 0.08),   // "Wave 7" banner above the yen
        CGRect(x: 0.79, y: 0.20, width: 0.21, height: 0.55),   // level info
        CGRect(x: 0.84, y: 0.74, width: 0.16, height: 0.26),   // minimap
        CGRect(x: 0.29, y: 0.87, width: 0.44, height: 0.13),   // hotbar
        CGRect(x: 0.44, y: 0.82, width: 0.12, height: 0.05),   // yen
        CGRect(x: 0.00, y: 0.84, width: 0.18, height: 0.16),   // charm + settings
        CGRect(x: 0.57, y: 0.55, width: 0.18, height: 0.15),   // Place / Rotate / Cancel menu
    ]

    /// Averages each grid cell → RGB per cell (row 0 = top of screen).
    static func cells(_ image: CGImage) -> [(Double, Double, Double)]? {
        let w = cols, h = rows
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var out = [(Double, Double, Double)](repeating: (0, 0, 0), count: w * h)
        for y in 0..<h { for x in 0..<w {
            let i = ((h - 1 - y) * w + x) * 4            // CGContext rows are bottom-up
            out[y * w + x] = (Double(px[i]) / 255, Double(px[i + 1]) / 255, Double(px[i + 2]) / 255)
        }}
        return out
    }

    /// Two screenshots without a unit held (before and after) and two while holding it.
    /// A cell counts as overlay only if ALL four before/after comparisons agree — so things that
    /// change on their own (wave banner popping up, enemies + their health bars walking past,
    /// damage numbers, card animations) are thrown out. Things that never change (unit card
    /// backgrounds, grass, HUD text) are never counted in the first place.
    /// `masks`: screen areas to ignore entirely (e.g. around enemy/summon health bars).
    init?(bases: [CGImage], helds: [CGImage], enemyLane: [NormPoint] = [], masks: [CGRect] = []) {
        aspect = Double(WindowManager.lockedSize.height / WindowManager.lockedSize.width)
        var A = bases.compactMap(Self.cells)
        let B = helds.compactMap(Self.cells)
        guard !A.isEmpty, !B.isEmpty else { return nil }
        let w = Self.cols, h = Self.rows
        var g = [Cell](repeating: .other, count: w * h)
        var hudM = [Bool](repeating: false, count: w * h)
        func classify(_ c0: (Double, Double, Double), _ c1: (Double, Double, Double)) -> Cell {
            let dr = c1.0 - c0.0, dg = c1.1 - c0.1, db = c1.2 - c0.2
            // "Greenness" = how much green beats the other two channels. The hill overlay pushes
            // this up a lot everywhere — even on a WHITE rooftop, where green itself barely rises
            // (it's already near max) but red and blue drop hard. Plain dg missed those.
            let gs0 = c0.1 - max(c0.0, c0.2), gs1 = c1.1 - max(c1.0, c1.2)
            if gs1 - gs0 > 0.15 && gs1 > 0.2 { return .green }
            // Neon overlay green (≈ 100,255,30) even if the "no unit" shot caught it fading out.
            if gs1 > 0.45 && c1.1 > 0.75 { return .green }
            if dg > 0.06 && dg > dr + 0.03 && dg > db && gs1 > 0.15 { return .green }
            if dr > 0.08 && dr > dg + 0.04 && dr > db + 0.02 { return .red }
            return .other
        }
        // Only the first "no unit" shot is trusted: the second one is often taken while the
        // overlay is still fading out, which wiped out all the green.
        A = [A[0]]
        for y in 0..<h { for x in 0..<w {
            let i = y * w + x
            let pt = CGPoint(x: (Double(x) + 0.5) / Double(w), y: (Double(y) + 0.5) / Double(h))
            if Self.hud.contains(where: { $0.contains(pt) }) { hudM[i] = true; continue }
            if masks.contains(where: { $0.contains(pt) }) { continue }
            // The two "no unit" shots must match each other (nothing moved there)…
            if A.count > 1, classify(A[0][i], A[1][i]) != .other { continue }
            // The holding shots are taken with the cursor in opposite corners, so the unit's red
            // range circle covers different parts of the map in each. Green in ANY of them = green
            // (the circle only hides it); red only if red in ALL of them (else it was the circle).
            var verdicts: [Cell] = []
            for a in A { for b in B { verdicts.append(classify(a[i], b[i])) } }
            // Green needs to show in BOTH holding shots — or be green in one and red in the other
            // (the range circle tinting it). Green in one and nothing in the other = something that
            // moved, like a summon's green health bar walking down the track.
            if verdicts.contains(.green), !verdicts.contains(.other) { g[i] = .green }
            else if !verdicts.isEmpty, verdicts.allSatisfy({ $0 == .red }) { g[i] = .red }
        }}
        // Real hill areas are big SOLID patches; health bars are long thin strips — drop anything
        // where less than half the cells have green on all four sides.
        g = Self.dropSpecks(g, kind: .green, minSize: 40, solidShare: 2)
        grid = g
        hudMask = hudM
        // Lane: where enemies were actually seen walking (reliable on every map), if we have
        // enough sightings. Otherwise fall back to "what turned red" from the overlay.
        if enemyLane.count >= 25 {
            var lane = [Bool](repeating: false, count: w * h)
            for p in enemyLane {
                let cx = Int(p.x * Double(w)), cy = Int(p.y * Double(h))
                for dy in -2...2 { for dx in -2...2 {
                    let x = cx + dx, y = cy + dy
                    if x >= 0, y >= 0, x < w, y < h, !hudM[y * w + x] { lane[y * w + x] = true }
                }}
            }
            path = lane
            laneFromEnemies = true
        } else {
            // Holding a hill unit: hills are green, so red can only be lane (+ taken spots).
            // Holding a ground unit: hills are red too, so drop really wide red blocks.
            let hillish = g.filter { $0 == .green }.count >= 120
            path = Self.cleanPath(g, removeWide: !hillish)
            laneFromEnemies = false
        }
        distToPath = Self.distances(from: path)
    }

    /// Lane = long red STRIPS. Removed: wide red blocks (hills/blocked areas show red for ground
    /// units — "opening" by a 7×7 square deletes anything that wide), thin lines (range rings),
    /// and small blobs (other players' units).
    private static func cleanPath(_ g: [Cell], removeWide: Bool) -> [Bool] {
        let w = cols, h = rows, n = w * h
        func at(_ m: [Bool], _ x: Int, _ y: Int) -> Bool { x >= 0 && y >= 0 && x < w && y < h && m[y * w + x] }
        let red = g.map { $0 == .red }

        // Distance from each red cell to the nearest non-red cell (8-neighbour steps).
        var inside = [Int](repeating: 0, count: n)
        var queue: [Int] = []
        for i in 0..<n where red[i] {
            let x = i % w, y = i / w
            var edge = false
            for dy in -1...1 { for dx in -1...1 where !at(red, x + dx, y + dy) { edge = true } }
            if edge { inside[i] = 1; queue.append(i) }
        }
        var head = 0
        while head < queue.count {
            let i = queue[head]; head += 1
            let x = i % w, y = i / w
            for dy in -1...1 { for dx in -1...1 {
                let nx = x + dx, ny = y + dy
                guard at(red, nx, ny) else { continue }
                let j = ny * w + nx
                if inside[j] == 0 { inside[j] = inside[i] + 1; queue.append(j) }
            }}
        }
        // Wide areas: cores deeper than 5 cells (≈ 11+ cells across — wider than any lane),
        // grown back by 5 cells.
        var wide = [Bool](repeating: false, count: n)
        var frontier = removeWide ? (0..<n).filter { inside[$0] >= 6 } : []
        for i in frontier { wide[i] = true }
        for _ in 0..<5 {
            var next: [Int] = []
            for i in frontier {
                let x = i % w, y = i / w
                for dy in -1...1 { for dx in -1...1 {
                    let nx = x + dx, ny = y + dy
                    guard at(red, nx, ny) else { continue }
                    let j = ny * w + nx
                    if !wide[j] { wide[j] = true; next.append(j) }
                }}
            }
            frontier = next
        }
        let strip = (0..<n).map { red[$0] && !wide[$0] }

        // Keep only sizeable, non-hairline strip pieces.
        var interior = [Bool](repeating: false, count: n)
        for y in 0..<h { for x in 0..<w where strip[y * w + x] {
            interior[y * w + x] = at(red, x-1, y) && at(red, x+1, y) && at(red, x, y-1) && at(red, x, y+1)
        }}
        var out = [Bool](repeating: false, count: n)
        var seen = [Bool](repeating: false, count: n)
        for start in 0..<n where strip[start] && !seen[start] {
            var stack = [start], comp: [Int] = []
            seen[start] = true
            while let i = stack.popLast() {
                comp.append(i)
                let x = i % w, y = i / w
                for dy in -1...1 { for dx in -1...1 {
                    let nx = x + dx, ny = y + dy
                    if at(strip, nx, ny) && !seen[ny * w + nx] { seen[ny * w + nx] = true; stack.append(ny * w + nx) }
                }}
            }
            let thickness = Double(comp.filter { interior[$0] }.count) / Double(comp.count)
            if comp.count >= 20 && thickness >= 0.15 { for i in comp { out[i] = true } }
        }
        return out
    }

    /// Removes small or hairline blobs of one colour (enemy health bars, sparkles, text).
    /// Real placement overlay comes in big solid patches.
    private static func dropSpecks(_ g: [Cell], kind: Cell, minSize: Int = 15, solidShare: Int = 4) -> [Cell] {
        let w = cols, h = rows, n = w * h
        var out = g
        var seen = [Bool](repeating: false, count: n)
        func isK(_ x: Int, _ y: Int) -> Bool { x >= 0 && y >= 0 && x < w && y < h && g[y * w + x] == kind }
        for start in 0..<n where g[start] == kind && !seen[start] {
            var stack = [start], comp: [Int] = []
            seen[start] = true
            while let i = stack.popLast() {
                comp.append(i)
                let x = i % w, y = i / w
                for dy in -1...1 { for dx in -1...1 where isK(x + dx, y + dy) && !seen[(y + dy) * w + x + dx] {
                    seen[(y + dy) * w + x + dx] = true; stack.append((y + dy) * w + x + dx)
                }}
            }
            let solid = comp.filter { i in
                let x = i % w, y = i / w
                return isK(x-1, y) && isK(x+1, y) && isK(x, y-1) && isK(x, y+1)
            }.count
            if comp.count < minSize || solid * solidShare < comp.count { for i in comp { out[i] = .other } }
        }
        return out
    }

    /// Breadth-first distance (8-neighbour steps) from every cell to the nearest lane cell.
    private static func distances(from path: [Bool]) -> [Int] {
        let w = cols, h = rows
        var d = [Int](repeating: Int.max, count: w * h)
        var queue: [Int] = []
        for i in 0..<(w * h) where path[i] { d[i] = 0; queue.append(i) }
        var head = 0
        while head < queue.count {
            let i = queue[head]; head += 1
            let x = i % w, y = i / w
            for dy in -1...1 { for dx in -1...1 where dx != 0 || dy != 0 {
                let nx = x + dx, ny = y + dy
                guard nx >= 0, ny >= 0, nx < w, ny < h else { continue }
                let j = ny * w + nx
                if d[j] == Int.max { d[j] = d[i] + 1; queue.append(j) }
            }}
        }
        return d
    }

    /// How many of the 3×3 cells around a point are green / red in the overlay.
    func overlayCounts(at p: NormPoint) -> (green: Int, red: Int) {
        let cx = min(Self.cols - 1, max(0, Int(p.x * Double(Self.cols))))
        let cy = min(Self.rows - 1, max(0, Int(p.y * Double(Self.rows))))
        var g = 0, r = 0
        for dy in -1...1 { for dx in -1...1 {
            let x = cx + dx, y = cy + dy
            guard x >= 0, y >= 0, x < Self.cols, y < Self.rows else { continue }
            let c = y * Self.cols + x
            switch grid[c] {
            case .green: if distToPath[c] >= 2 { g += 1 }     // green on the track = a health bar, not a hill
            case .red: r += 1
            default: break
            }
        }}
        return (g, r)
    }

    var pathCellCount: Int { path.filter { $0 }.count }
    var greenCellCount: Int { grid.filter { $0 == .green }.count }

    /// Window height/width, cached once. (Recomputing it inside the distance loops froze the app.)
    let aspect: Double
    private static func point(_ c: Int) -> NormPoint {
        NormPoint(x: (Double(c % cols) + 0.5) / Double(cols), y: (Double(c / cols) + 0.5) / Double(rows))
    }
    private func dist(_ a: NormPoint, _ b: NormPoint) -> Double {
        let dx = a.x - b.x, dy = (a.y - b.y) * aspect
        return (dx * dx + dy * dy).squareRoot()
    }
    private func cell(of p: NormPoint) -> Int {
        let x = min(Self.cols - 1, max(0, Int(p.x * Double(Self.cols))))
        let y = min(Self.rows - 1, max(0, Int(p.y * Double(Self.rows))))
        return y * Self.cols + x
    }

    /// Placeable spots, best first.
    /// - maxLaneDistance: how far from the red lane a spot may be (cells). Ground units: close.
    /// A cell a unit could stand on: hill units need green, ground units need "not red, not HUD".
    func placeable(_ c: Int, hill: Bool) -> Bool {
        // Hills are never on the track: a green cell on/next to the lane is a summon's health bar.
        hill ? (grid[c] == .green && distToPath[c] >= 2) : (grid[c] != .red && !hudMask[c] && !path[c])
    }

    func candidates(range: Double, taken: [NormPoint], covered: [Int: Int], hill: Bool,
                    maxLaneDistance: Int, avoid: [NormPoint] = [], limit: Int = 6) -> [(spot: NormPoint, score: Double)] {
        let w = Self.cols, h = Self.rows
        let pathCells = (0..<(w * h)).filter { path[$0] }
        guard !pathCells.isEmpty else { return [] }
        var all: [(NormPoint, Double)] = []
        for y in 2..<(h - 2) { for x in 2..<(w - 2) {
            let c = y * w + x
            // Ground units: off the lane but close to it. Hill units: anywhere green.
            if !hill { guard distToPath[c] >= 2, distToPath[c] <= maxLaneDistance else { continue } }
            // Room for the unit: a full 3×3 patch it could stand on (nothing red = no other unit there).
            var roomy = true
            outer: for dy in -1...1 { for dx in -1...1 where !placeable((y + dy) * w + x + dx, hill: hill) { roomy = false; break outer } }
            guard roomy else { continue }
            let p = Self.point(c)
            if taken.contains(where: { dist($0, p) < 0.035 }) { continue }
            if avoid.contains(where: { dist($0, p) < 0.015 }) { continue }
            var score = 0.0
            for pc in pathCells where dist(p, Self.point(pc)) <= range {
                score += 1.0 / Double(1 + (covered[pc] ?? 0))
            }
            // Small bonus for hugging the lane (enemies are in range sooner and longer).
            score *= 1.0 + 0.15 / Double(max(1, distToPath[c]))
            // Hill spots out of range of the lane still count (closest first) so a hill unit always has somewhere to go.
            if score > 0 { all.append((p, score)) }
            else if hill, distToPath[c] != Int.max { all.append((p, 0.001 / Double(distToPath[c]))) }
        }}
        // Best first, and spread out: skip spots right next to a better one.
        var picked: [(spot: NormPoint, score: Double)] = []
        for (p, s) in all.sorted(by: { $0.1 > $1.1 }) where !picked.contains(where: { dist($0.spot, p) < 0.03 }) {
            picked.append((p, s))
            if picked.count >= limit { break }
        }
        return picked
    }

    /// One cell closer to the lane, if that cell is still green. Used after a failed placement.
    func nudgedTowardLane(_ p: NormPoint, hill: Bool) -> NormPoint? {
        let c = cell(of: p), x = c % Self.cols, y = c / Self.cols
        var best: (Int, Int)?
        for dy in -2...2 { for dx in -2...2 where dx != 0 || dy != 0 {
            let nx = x + dx, ny = y + dy
            guard nx >= 0, ny >= 0, nx < Self.cols, ny < Self.rows else { continue }
            let j = ny * Self.cols + nx
            guard placeable(j, hill: hill), distToPath[j] < distToPath[c], distToPath[j] >= (hill ? 1 : 2) else { continue }
            if best == nil || distToPath[j] < best!.1 { best = (j, distToPath[j]) }
        }}
        return best.map { Self.point($0.0) }
    }

    func pathCells(near p: NormPoint, range: Double) -> [Int] {
        (0..<(Self.cols * Self.rows)).filter { path[$0] && dist(p, Self.point($0)) <= range }
    }

    /// Debug picture: the held screenshot with green/lane cells tinted and picks circled.
    func debugImage(over held: CGImage, picks: [NormPoint]) -> CGImage? {
        let W = held.width, H = held.height
        guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(held, in: CGRect(x: 0, y: 0, width: W, height: H))
        let cw = Double(W) / Double(Self.cols), ch = Double(H) / Double(Self.rows)
        for i in 0..<(Self.cols * Self.rows) {
            let x = Double(i % Self.cols) * cw, y = Double(H) - Double(i / Self.cols + 1) * ch
            if path[i] { ctx.setFillColor(CGColor(red: 1, green: 1, blue: 0, alpha: 0.45)) }
            else if grid[i] == .green { ctx.setFillColor(CGColor(red: 0, green: 1, blue: 1, alpha: 0.30)) }
            else { continue }
            ctx.fill(CGRect(x: x, y: y, width: cw, height: ch))
        }
        ctx.setStrokeColor(CGColor(red: 1, green: 0, blue: 1, alpha: 1)); ctx.setLineWidth(6)
        for (n, p) in picks.enumerated() {
            let r = n == 0 ? 22.0 : 14.0
            ctx.strokeEllipse(in: CGRect(x: p.x * Double(W) - r, y: Double(H) - p.y * Double(H) - r, width: 2 * r, height: 2 * r))
        }
        return ctx.makeImage()
    }
}
