import CoreGraphics
import CoreImage
import Foundation

/// How detected regions are hidden.
///
/// None of the styles ever lets the original pixels influence the output: the region is first painted
/// over with its surrounding background colour, and only then decorated. That matters because a plain
/// Gaussian blur or a plain mosaic of real text is a deterministic, low-pass function of the glyphs and
/// can be partially reversed by brute force (render candidate strings, blur them the same way, compare —
/// see "Depix" and the 2022 "unredacter" work). Here the "blur" and "pixelate" looks are generated from
/// random noise in the text/background colours, so there is nothing to invert.
public enum RedactionStyle: String, Codable, Sendable, CaseIterable {
    /// Mosaic of random blocks in the text/background colours (default).
    case pixelate
    /// Blurred random "glyph" noise — looks like blurred text, contains none.
    case blur
    /// Solid rounded bar in a shade of the surrounding background.
    case bar
    /// Detect and report only; leave the image untouched.
    case off
}

public struct RedactionRegion: Sendable, Hashable {
    /// Top-left-origin pixel rect.
    public var rect: CGRect
    public var severity: Severity
    public var label: String

    public init(rect: CGRect, severity: Severity = .high, label: String = "") {
        self.rect = rect
        self.severity = severity
        self.label = label
    }
}

public enum Redactor {
    public static func apply(_ image: CGImage, regions: [RedactionRegion], style: RedactionStyle) -> CGImage {
        guard style != .off, !regions.isEmpty else { return image }
        let bitmap = Bitmap(image)
        let W = image.width, H = image.height
        let ctx = Canvas.make(width: W, height: H)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: W, height: H))
        var rng = SystemRandomNumberGenerator()

        for region in merged(regions) {
            let r = region.rect.intersection(CGRect(x: 0, y: 0, width: W, height: H)).integral
            guard !r.isNull, r.width >= 1, r.height >= 1 else { continue }
            let bg = bitmap.surroundingColor(of: r)
            let fg = bitmap.foregroundColor(in: r, background: bg)
            let cg = Canvas.flip(r, height: H)
            let radius = min(r.height * 0.22, 8)

            ctx.saveGState()
            // 1. Destroy: paint the background over the whole region.
            ctx.setFillColor(bg.with(alpha: 1).cgColor)
            ctx.fill(cg)

            switch style {
            case .bar:
                let barColor = bg.mix(fg, bg.luminance < 0.5 ? 0.22 : 0.16).with(alpha: 1)
                ctx.addPath(CGPath(roundedRect: cg.insetBy(dx: 0.5, dy: 0.5), cornerWidth: radius, cornerHeight: radius, transform: nil))
                ctx.setFillColor(barColor.cgColor)
                ctx.fillPath()

            case .pixelate:
                let block = max(4, (r.height / 2.6).rounded())
                ctx.addPath(CGPath(roundedRect: cg, cornerWidth: radius * 0.5, cornerHeight: radius * 0.5, transform: nil))
                ctx.clip()
                var y = cg.minY
                while y < cg.maxY {
                    var x = cg.minX
                    while x < cg.maxX {
                        let t = Double.random(in: 0.04...0.42, using: &rng)
                        ctx.setFillColor(bg.mix(fg, t).with(alpha: 1).cgColor)
                        ctx.fill(CGRect(x: x, y: y, width: block, height: block))
                        x += block
                    }
                    y += block
                }

            case .blur:
                if let blurred = blurredNoise(size: r.size, bg: bg, fg: fg, rng: &rng) {
                    ctx.addPath(CGPath(roundedRect: cg, cornerWidth: radius, cornerHeight: radius, transform: nil))
                    ctx.clip()
                    ctx.draw(blurred, in: cg)
                }

            case .off:
                break
            }
            ctx.restoreGState()
        }
        return ctx.makeImage() ?? image
    }

    /// Union regions that overlap or touch, so one secret read by several OCR passes becomes one clean shape.
    public static func merged(_ regions: [RedactionRegion]) -> [RedactionRegion] {
        var out = regions
        var changed = true
        while changed {
            changed = false
            outer: for i in out.indices {
                for j in out.indices where j > i {
                    let a = out[i].rect, b = out[j].rect
                    let inter = a.insetBy(dx: -1, dy: -1).intersection(b)
                    // Same row (vertical overlap > 50% of the smaller box) or substantial overlap.
                    let vOverlap = min(a.maxY, b.maxY) - max(a.minY, b.minY)
                    guard !inter.isNull, vOverlap > 0.5 * min(a.height, b.height) || inter.width * inter.height > 0.5 * min(a.width * a.height, b.width * b.height) else { continue }
                    out[i].rect = a.union(b)
                    out[i].severity = max(out[i].severity, out[j].severity)
                    out.remove(at: j)
                    changed = true
                    break outer
                }
            }
        }
        return out
    }

    /// Random word-shaped strokes in the text colour, heavily blurred. Generated from noise only.
    static func blurredNoise(size: CGSize, bg: RGBA, fg: RGBA, rng: inout SystemRandomNumberGenerator) -> CGImage? {
        let w = Int(size.width.rounded(.up)), h = Int(size.height.rounded(.up))
        guard w > 0, h > 0 else { return nil }
        let ctx = Canvas.make(width: w, height: h)
        ctx.setFillColor(bg.with(alpha: 1).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let glyphH = Double(h) * 0.5
        var x = Double(h) * 0.15
        while x < Double(w) {
            let gw = Double.random(in: glyphH * 0.35...glyphH * 0.75, using: &rng)
            let gh = Double.random(in: glyphH * 0.6...glyphH * 1.1, using: &rng)
            ctx.setFillColor(bg.mix(fg, 0.7).with(alpha: 1).cgColor)
            ctx.fill(CGRect(x: x, y: (Double(h) - gh) / 2, width: gw, height: gh))
            x += gw + Double.random(in: glyphH * 0.1...glyphH * 0.35, using: &rng)
        }
        guard let noise = ctx.makeImage() else { return nil }
        let ci = CIImage(cgImage: noise).clampedToExtent()
        let radius = max(2, Double(h) / 3.5)
        let blurred = ci.applyingGaussianBlur(sigma: radius).cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
        let cictx = CIContext(options: [.workingColorSpace: Canvas.srgb, .outputColorSpace: Canvas.srgb])
        return cictx.createCGImage(blurred, from: CGRect(x: 0, y: 0, width: w, height: h))
    }

    /// Dry-run preview: outline every region with a severity colour and a small rule label.
    public static func outline(_ image: CGImage, regions: [RedactionRegion], scale: Double) -> CGImage {
        let W = image.width, H = image.height
        let ctx = Canvas.make(width: W, height: H)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: W, height: H))
        for region in regions {
            let cg = Canvas.flip(region.rect, height: H)
            let color: RGBA = switch region.severity {
            case .critical: RGBA(1, 0.18, 0.33)
            case .high: RGBA(1, 0.42, 0.2)
            case .medium: RGBA(1, 0.72, 0.1)
            case .low: RGBA(0.25, 0.65, 1)
            }
            ctx.setFillColor(color.with(alpha: 0.16).cgColor)
            ctx.fill(cg)
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(max(1.5, 1.5 * scale))
            ctx.stroke(cg)
            if !region.label.isEmpty {
                // Label to the right of the box (vertically centred) so it doesn't hide the row above.
                let lh = 13 * scale
                TextDraw.label(region.label, in: ctx, at: CGPoint(x: cg.maxX + 3 * scale, y: cg.midY - lh / 2), color: color, scale: scale)
            }
        }
        return ctx.makeImage() ?? image
    }
}
