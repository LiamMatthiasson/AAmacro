import Foundation
import CoreGraphics
import Vision

/// Grayscale pixel buffer — the format all matching works on.
struct GrayImage {
    let width: Int
    let height: Int
    var pixels: [UInt8]

    /// Converts (and optionally downscales) a CGImage to grayscale.
    init?(_ image: CGImage, scale: Double = 1.0) {
        width = max(1, Int(Double(image.width) * scale))
        height = max(1, Int(Double(image.height) * scale))
        pixels = [UInt8](repeating: 0, count: width * height)
        let ok: Bool = pixels.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        if !ok { return nil }
    }

    subscript(x: Int, y: Int) -> UInt8 { pixels[y * width + x] }
}

/// Template matching: "where on screen is this cropped button?"
/// Mean absolute difference over a downscaled image; good enough for flat UI buttons
/// and fast enough to run several times per second on small regions.
enum Matcher {
    struct Match { let point: NormPoint; let score: Double }   // score: 0 = perfect, 1 = nothing alike

    /// - Parameters:
    ///   - region: optional normalized search rect (0...1) to speed things up, e.g. the bottom-right corner.
    ///   - threshold: max acceptable score. Tune this once you have real screenshots.
    static func find(_ template: CGImage, in screen: CGImage,
                     region: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1),
                     scale: Double = 0.5, threshold: Double = 0.12) -> Match? {
        guard let s = GrayImage(screen, scale: scale),
              let t = GrayImage(template, scale: scale),
              t.width < s.width, t.height < s.height else { return nil }

        let x0 = Int(region.minX * Double(s.width)), x1 = min(s.width - t.width, Int(region.maxX * Double(s.width)))
        let y0 = Int(region.minY * Double(s.height)), y1 = min(s.height - t.height, Int(region.maxY * Double(s.height)))
        guard x1 > x0, y1 > y0 else { return nil }

        var best = (x: 0, y: 0, score: Double.infinity)
        let step = 2                              // coarse pass; refine around the best hit
        let sample = 3                            // compare every 3rd template pixel
        func score(_ ox: Int, _ oy: Int) -> Double {
            var sum = 0, n = 0
            var ty = 0
            while ty < t.height {
                var tx = 0
                while tx < t.width {
                    sum += abs(Int(s[ox + tx, oy + ty]) - Int(t[tx, ty])); n += 1
                    tx += sample
                }
                ty += sample
            }
            return Double(sum) / Double(n * 255)
        }
        var y = y0
        while y <= y1 {
            var x = x0
            while x <= x1 {
                let sc = score(x, y)
                if sc < best.score { best = (x, y, sc) }
                x += step
            }
            y += step
        }
        for dy in -step...step { for dx in -step...step {
            let x = best.x + dx, y = best.y + dy
            guard x >= 0, y >= 0, x <= s.width - t.width, y <= s.height - t.height else { continue }
            let sc = score(x, y)
            if sc < best.score { best = (x, y, sc) }
        }}

        guard best.score <= threshold else { return nil }
        let cx = Double(best.x + t.width / 2) / Double(s.width)
        let cy = Double(best.y + t.height / 2) / Double(s.height)
        return Match(point: NormPoint(x: cx, y: cy), score: best.score)
    }

    /// Whole-image similarity (0 = identical). Used to recognize a map from a reference screenshot.
    static func similarity(_ a: CGImage, _ b: CGImage) -> Double {
        let size = 64
        guard let ga = GrayImage(a, scale: Double(size) / Double(a.width)),
              let gb = GrayImage(b, scale: Double(size) / Double(b.width)) else { return 1 }
        let n = min(ga.pixels.count, gb.pixels.count)
        var sum = 0
        for i in 0..<n { sum += abs(Int(ga.pixels[i]) - Int(gb.pixels[i])) }
        return Double(sum) / Double(n * 255)
    }

    /// Average RGB over a normalized rect.
    static func averageColor(in image: CGImage, rect: CGRect) -> (r: Double, g: Double, b: Double)? {
        guard let crop = image.cropped(to: rect) else { return nil }
        var px = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return (Double(px[0]) / 255, Double(px[1]) / 255, Double(px[2]) / 255)
    }

    /// Average RGB in a small box around a point — e.g. to check the placement ghost is green, not red.
    static func averageColor(in image: CGImage, at p: NormPoint, radius: Int = 6) -> (r: Double, g: Double, b: Double)? {
        let cx = Int(p.x * Double(image.width)), cy = Int(p.y * Double(image.height))
        let rect = CGRect(x: cx - radius, y: cy - radius, width: radius * 2, height: radius * 2)
        guard let crop = image.cropping(to: rect) else { return nil }
        var px = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))   // 1×1 draw = average
        return (Double(px[0]) / 255, Double(px[1]) / 255, Double(px[2]) / 255)
    }
}

/// OCR via Apple's Vision framework: reads the matchmaking code, wave number, yen, stage name.
enum OCR {
    struct Line { let text: String; let box: CGRect }   // box is normalized, origin top-left

    // The same frame is often read several times in a row by different checks (cards, end of
    // match, popups, the wave counter…). Each read is a full Vision pass, so the last few results
    // are kept and handed back when the SAME image is asked for again with the same region/mode.
    // Entries hold the image strongly, so a recycled address can never match a different frame.
    private struct Key: Equatable { let image: ObjectIdentifier; let x, y, w, h: Double; let fast: Bool }
    private struct Entry { let key: Key; let image: CGImage; let lines: [Line] }
    private static var cache: [Entry] = []
    private static let cacheLock = NSLock()
    private static let cacheSize = 8

    static func read(_ image: CGImage, region: CGRect? = nil, fast: Bool = false) throws -> [Line] {
        let r = region ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        let key = Key(image: ObjectIdentifier(image), x: r.minX, y: r.minY, w: r.width, h: r.height, fast: fast)
        cacheLock.lock()
        if let hit = cache.first(where: { $0.key == key && $0.image === image }) { cacheLock.unlock(); return hit.lines }
        cacheLock.unlock()
        let lines = try recognize(image, region: region, fast: fast)
        cacheLock.lock()
        cache.append(Entry(key: key, image: image, lines: lines))
        if cache.count > cacheSize { cache.removeFirst(cache.count - cacheSize) }
        cacheLock.unlock()
        return lines
    }

    private static func recognize(_ image: CGImage, region: CGRect?, fast: Bool) throws -> [Line] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = fast ? .fast : .accurate
        request.usesLanguageCorrection = false            // codes/numbers aren't words
        if let region {
            // Vision uses bottom-left origin; flip our top-left region.
            request.regionOfInterest = CGRect(x: region.minX, y: 1 - region.maxY,
                                              width: region.width, height: region.height)
        }
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { obs in
            guard let top = obs.topCandidates(1).first else { return nil }
            // Vision returns boxes relative to the region of interest (bottom-left origin).
            // Convert to full-image, top-left-origin coordinates.
            let b = obs.boundingBox
            let r = region ?? CGRect(x: 0, y: 0, width: 1, height: 1)
            return Line(text: top.string,
                        box: CGRect(x: r.minX + b.minX * r.width,
                                    y: r.minY + (1 - b.maxY) * r.height,
                                    width: b.width * r.width, height: b.height * r.height))
        }
    }

    /// First line whose text contains `needle` (case, spaces and punctuation ignored).
    /// With `exact`, the whole line must equal it — so "Play" doesn't match "Play Here".
    static func find(_ needle: String, in image: CGImage, region: CGRect? = nil,
                     exact: Bool = false, fast: Bool = false) throws -> Line? {
        let n = norm(needle)
        return try read(image, region: region, fast: fast).first {
            exact ? norm($0.text) == n : norm($0.text).contains(n)
        }
    }

    static func norm(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }

    /// All digits found in a region, joined — e.g. "4 7 1 9" -> "4719".
    static func digits(_ image: CGImage, region: CGRect, fast: Bool = false) throws -> String {
        try read(image, region: region, fast: fast).map(\.text).joined().filter(\.isNumber)
    }
}

extension OCR.Line {
    var center: NormPoint { NormPoint(x: box.midX, y: box.midY) }
}

extension CGImage {
    /// Crops a normalized (0...1, top-left origin) rect out of the image.
    func cropped(to r: CGRect) -> CGImage? {
        cropping(to: CGRect(x: r.minX * Double(width), y: r.minY * Double(height),
                            width: r.width * Double(width), height: r.height * Double(height)))
    }
}

extension Matcher {
    /// How far the current view is shifted from a reference view. Compares downscaled grayscale
    /// images over the map area (HUD excluded) for every offset up to ±maxShift cells.
    /// Returns the best offset as window fractions, its difference score (0 = identical) and
    /// the score with no shift.
    static func viewShift(reference: CGImage, current: CGImage, maxShift: Int = 10)
        -> (dx: Double, dy: Double, score: Double, unshifted: Double)? {
        let W = 160
        guard let a = GrayImage(reference, scale: Double(W) / Double(reference.width)),
              let b = GrayImage(current, scale: Double(W) / Double(current.width)) else { return nil }
        let w = min(a.width, b.width), h = min(a.height, b.height)
        // Compare only the map area: skip the top HUD, the hotbar and the right-side panels.
        let x0 = Int(Double(w) * 0.05), x1 = Int(Double(w) * 0.75)
        let y0 = Int(Double(h) * 0.22), y1 = Int(Double(h) * 0.80)
        func score(_ dx: Int, _ dy: Int) -> Double {
            var sum = 0, n = 0
            var y = y0
            while y < y1 {
                var x = x0
                while x < x1 {
                    let xs = x + dx, ys = y + dy
                    if xs >= 0, ys >= 0, xs < w, ys < h {
                        sum += abs(Int(a[x, y]) - Int(b[xs, ys])); n += 1
                    }
                    x += 2
                }
                y += 2
            }
            return n == 0 ? 1 : Double(sum) / Double(n * 255)
        }
        var best = (dx: 0, dy: 0, s: score(0, 0))
        let zero = best.s
        for dy in -maxShift...maxShift { for dx in -maxShift...maxShift where dx != 0 || dy != 0 {
            let sc = score(dx, dy)
            if sc < best.s { best = (dx, dy, sc) }
        }}
        return (Double(best.dx) / Double(w), Double(best.dy) / Double(h), best.s, zero)
    }
}
