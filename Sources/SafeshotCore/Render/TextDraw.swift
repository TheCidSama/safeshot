import CoreGraphics
import CoreText
import Foundation

enum TextDraw {
    static func line(_ s: String, size: Double, color: RGBA, weight: CTFontUIFontType = .system, bold: Bool = false) -> CTLine {
        var font = CTFontCreateUIFontForLanguage(weight, size, nil) ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        if bold, let b = CTFontCreateCopyWithSymbolicTraits(font, size, nil, .boldTrait, .boldTrait) { font = b }
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color.cgColor,
        ]
        return CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
    }

    /// Small pill label whose bottom-left corner sits at `p` (CoreGraphics coordinates).
    static func label(_ s: String, in ctx: CGContext, at p: CGPoint, color: RGBA, scale: Double) {
        let l = line(s, size: 9 * scale, color: RGBA(1, 1, 1), bold: true)
        let w = CTLineGetTypographicBounds(l, nil, nil, nil)
        let h = 13 * scale
        var origin = p
        if origin.y + h > CGFloat(ctx.height) { origin.y = p.y - h - 2 } // keep inside the canvas
        origin.x = min(origin.x, CGFloat(ctx.width) - (w + 8 * scale))
        let rect = CGRect(x: origin.x, y: origin.y, width: w + 8 * scale, height: h)
        ctx.setFillColor(color.cgColor)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 3 * scale, cornerHeight: 3 * scale, transform: nil))
        ctx.fillPath()
        ctx.textPosition = CGPoint(x: rect.minX + 4 * scale, y: rect.minY + 3.5 * scale)
        CTLineDraw(l, ctx)
    }
}
