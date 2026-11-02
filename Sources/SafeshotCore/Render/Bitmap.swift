import CoreGraphics
import Foundation

public struct RGBA: Sendable, Hashable {
    public var r: Double, g: Double, b: Double, a: Double

    public init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    public init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
        if s.count == 6 {
            self.init(Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255)
        } else {
            self.init(Double((v >> 24) & 0xFF) / 255, Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255)
        }
    }

    public var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
    public var luminance: Double { 0.2126 * r + 0.7152 * g + 0.0722 * b }

    public func distance(_ o: RGBA) -> Double {
        let dr = r - o.r, dg = g - o.g, db = b - o.b
        return (dr * dr + dg * dg + db * db).squareRoot()
    }

    public func mix(_ o: RGBA, _ t: Double) -> RGBA {
        RGBA(r + (o.r - r) * t, g + (o.g - g) * t, b + (o.b - b) * t, a + (o.a - a) * t)
    }

    public func with(alpha: Double) -> RGBA { RGBA(r, g, b, alpha) }
}

/// A CPU-side 8-bit sRGB copy of an image for sampling and analysis. Row 0 is the TOP row.
public final class Bitmap {
    public let width: Int
    public let height: Int
    let bytesPerRow: Int
    var data: [UInt8]

    public init(_ image: CGImage) {
        width = image.width
        height = image.height
        bytesPerRow = width * 4
        data = [UInt8](repeating: 0, count: bytesPerRow * height)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        data.withUnsafeMutableBytes { buf in
            let ctx = CGContext(data: buf.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: bytesPerRow, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            // CGBitmapContext memory is top-row-first, so row 0 is the top of the image.
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    @inline(__always) public func pixel(_ x: Int, _ y: Int) -> RGBA {
        let xx = min(max(x, 0), width - 1), yy = min(max(y, 0), height - 1)
        let o = yy * bytesPerRow + xx * 4
        let a = Double(data[o + 3]) / 255
        guard a > 0 else { return RGBA(0, 0, 0, 0) }
        return RGBA(Double(data[o]) / 255 / a, Double(data[o + 1]) / 255 / a, Double(data[o + 2]) / 255 / a, a)
    }

    /// Most common colour (5 bits per channel buckets, averaged) among the given pixels.
    public func dominantColor(_ points: [(Int, Int)]) -> RGBA? {
        guard !points.isEmpty else { return nil }
        var buckets: [Int: (Int, Double, Double, Double, Double)] = [:]
        for (x, y) in points {
            let p = pixel(x, y)
            let key = (Int(p.r * 31) << 15) | (Int(p.g * 31) << 10) | (Int(p.b * 31) << 5) | Int(p.a * 31)
            var e = buckets[key] ?? (0, 0, 0, 0, 0)
            e.0 += 1; e.1 += p.r; e.2 += p.g; e.3 += p.b; e.4 += p.a
            buckets[key] = e
        }
        guard let best = buckets.values.max(by: { $0.0 < $1.0 }) else { return nil }
        let n = Double(best.0)
        return RGBA(best.1 / n, best.2 / n, best.3 / n, best.4 / n)
    }

    /// Background colour around a rect (top-left coordinates): dominant colour of a ring just outside it.
    public func surroundingColor(of rect: CGRect, ring: Int = 3) -> RGBA {
        let x0 = Int(rect.minX.rounded(.down)) - ring, x1 = Int(rect.maxX.rounded(.up)) + ring
        let y0 = Int(rect.minY.rounded(.down)) - ring, y1 = Int(rect.maxY.rounded(.up)) + ring
        var pts: [(Int, Int)] = []
        let stepX = max(1, (x1 - x0) / 200), stepY = max(1, (y1 - y0) / 60)
        for x in stride(from: x0, through: x1, by: stepX) {
            for k in 0..<ring { pts.append((x, y0 + k)); pts.append((x, y1 - k)) }
        }
        for y in stride(from: y0, through: y1, by: stepY) {
            for k in 0..<ring { pts.append((x0 + k, y)); pts.append((x1 - k, y)) }
        }
        pts = pts.filter { $0.0 >= 0 && $0.1 >= 0 && $0.0 < width && $0.1 < height }
        return dominantColor(pts) ?? RGBA(0.5, 0.5, 0.5)
    }

    /// Text colour inside a rect: average of the pixels furthest from the background.
    public func foregroundColor(in rect: CGRect, background bg: RGBA) -> RGBA {
        let x0 = max(0, Int(rect.minX)), x1 = min(width - 1, Int(rect.maxX))
        let y0 = max(0, Int(rect.minY)), y1 = min(height - 1, Int(rect.maxY))
        guard x1 > x0, y1 > y0 else { return bg.luminance > 0.5 ? RGBA(0.1, 0.1, 0.1) : RGBA(0.9, 0.9, 0.9) }
        var samples: [(Double, RGBA)] = []
        let step = max(1, Int((Double((x1 - x0) * (y1 - y0)) / 20000).squareRoot()))
        for y in stride(from: y0, through: y1, by: step) {
            for x in stride(from: x0, through: x1, by: step) {
                let p = pixel(x, y)
                samples.append((p.distance(bg), p))
            }
        }
        samples.sort { $0.0 > $1.0 }
        let top = samples.prefix(max(1, samples.count / 10))
        guard let first = top.first, first.0 > 0.12 else {
            return bg.luminance > 0.5 ? bg.mix(RGBA(0, 0, 0), 0.6) : bg.mix(RGBA(1, 1, 1), 0.6)
        }
        var acc = RGBA(0, 0, 0, 0)
        for (_, p) in top { acc.r += p.r; acc.g += p.g; acc.b += p.b; acc.a += p.a }
        let n = Double(top.count)
        return RGBA(acc.r / n, acc.g / n, acc.b / n, 1)
    }
}

public enum Canvas {
    public static let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

    public static func make(width: Int, height: Int) -> CGContext {
        let ctx = CGContext(data: nil, width: max(1, width), height: max(1, height), bitsPerComponent: 8,
                            bytesPerRow: 0, space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.interpolationQuality = .high
        ctx.setShouldAntialias(true)
        return ctx
    }

    /// Convert a top-left-origin rect to CoreGraphics' bottom-left origin for a canvas of `height` pixels.
    public static func flip(_ r: CGRect, height: Int) -> CGRect {
        CGRect(x: r.minX, y: CGFloat(height) - r.maxY, width: r.width, height: r.height)
    }
}
