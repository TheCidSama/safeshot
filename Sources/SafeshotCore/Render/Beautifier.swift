import CoreGraphics
import CoreText
import Foundation
import ImageIO

public enum Background: Sendable, Hashable {
    case gradient(GradientPreset)
    case solid(RGBA)
    case transparent
    case image(String)

    /// `ocean`, `#1e1e2e`, `transparent`, `image:/path/to/wallpaper.jpg`
    public static func parse(_ s: String) -> Background? {
        let l = s.lowercased()
        if l == "transparent" || l == "clear" || l == "none" { return .transparent }
        if l.hasPrefix("image:") { return .image(String(s.dropFirst(6))) }
        if let p = GradientPreset(rawValue: l) { return .gradient(p) }
        if let c = RGBA(hex: s) { return .solid(c) }
        if FileManager.default.fileExists(atPath: (s as NSString).expandingTildeInPath) { return .image(s) }
        return nil
    }
}

public enum GradientPreset: String, Sendable, CaseIterable {
    case ocean, sunset, candy, aurora, forest, peach, midnight, graphite, paper, lavender

    /// Colours top-left -> bottom-right.
    public var colors: [RGBA] {
        let hex: [String] = switch self {
        case .ocean: ["#4FACFE", "#5B6CF9", "#8E54E9"]
        case .sunset: ["#FF9A6C", "#FF6A88", "#C1407B"]
        case .candy: ["#F9A8D4", "#C4B5FD", "#93C5FD"]
        case .aurora: ["#34D399", "#22D3EE", "#818CF8"]
        case .forest: ["#A8E063", "#56AB2F", "#1D7A55"]
        case .peach: ["#FFE0C2", "#FFB6A3", "#F79AB2"]
        case .midnight: ["#334155", "#1E293B", "#0B1120"]
        case .graphite: ["#4B4B53", "#2A2A30", "#16161A"]
        case .paper: ["#F8F7F4", "#ECEAE4", "#DEDBD2"]
        case .lavender: ["#E0C3FC", "#B9B4F7", "#8EC5FC"]
        }
        return hex.compactMap { RGBA(hex: $0) }
    }
}

public enum ShadowStyle: String, Sendable, CaseIterable { case none, soft, strong }

public enum WindowFrame: String, Sendable, CaseIterable {
    case none
    /// macOS-style title bar with traffic lights; colour adapts to the screenshot.
    case macos
    case macosLight = "macos-light"
    case macosDark = "macos-dark"
}

public enum SizePreset: Sendable, Hashable {
    case original
    case aspect(Double, Double)

    public static func parse(_ s: String) -> SizePreset? {
        switch s.lowercased() {
        case "original", "auto": return .original
        case "twitter", "x", "16:9", "wide": return .aspect(16, 9)
        case "square", "1:1", "instagram": return .aspect(1, 1)
        case "4:3": return .aspect(4, 3)
        case "3:2": return .aspect(3, 2)
        case "4:5", "portrait": return .aspect(4, 5)
        default:
            let parts = s.split(separator: ":").compactMap { Double($0) }
            if parts.count == 2, parts[0] > 0, parts[1] > 0 { return .aspect(parts[0], parts[1]) }
            return nil
        }
    }
}

public struct BeautifyOptions: Sendable, Hashable {
    public var background: Background = .gradient(.ocean)
    /// Points (multiplied by the image scale).
    public var padding: Double = 64
    public var cornerRadius: Double = 12
    public var shadow: ShadowStyle = .soft
    public var frame: WindowFrame = .none
    public var title: String? = nil
    public var size: SizePreset = .original
    /// Detect the screenshot's own border colour and re-pad the content evenly inside it.
    public var autoBalance = true

    public init() {}
}

public enum Beautifier {
    public static func render(_ input: CGImage, scale: Double, options o: BeautifyOptions) -> CGImage {
        let s = max(1, scale)
        var content = input
        let border = BorderAnalysis.borderColor(of: Bitmap(input))
        if o.autoBalance, let border, let balanced = BorderAnalysis.balance(input, border: border, scale: s) {
            content = balanced
        }

        // --- Window (content + optional title bar), drawn at full resolution.
        let titleH = o.frame == .none ? 0 : Int((28 * s).rounded())
        let winW = content.width, winH = content.height + titleH
        let radius = o.cornerRadius * s

        let pad = o.padding * s
        var canvasW = Double(winW) + 2 * pad, canvasH = Double(winH) + 2 * pad
        if case let .aspect(aw, ah) = o.size {
            let target = aw / ah
            if canvasW / canvasH < target { canvasW = canvasH * target } else { canvasH = canvasW / target }
        }
        let CW = Int(canvasW.rounded()), CH = Int(canvasH.rounded())
        let ctx = Canvas.make(width: CW, height: CH)

        drawBackground(o.background, in: ctx, size: CGSize(width: CW, height: CH))

        let winRect = CGRect(x: ((Double(CW) - Double(winW)) / 2).rounded(), y: ((Double(CH) - Double(winH)) / 2).rounded(),
                             width: Double(winW), height: Double(winH))
        let path = CGPath(roundedRect: winRect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        let bodyColor = border ?? RGBA(0.5, 0.5, 0.5)

        // --- Multi-layer soft shadow (contact + mid + ambient).
        let layers: [(dy: Double, blur: Double, alpha: Double)] = switch o.shadow {
        case .none: []
        case .soft: [(1, 3, 0.10), (8, 22, 0.16), (24, 60, 0.22)]
        case .strong: [(2, 4, 0.18), (12, 30, 0.28), (36, 90, 0.38)]
        }
        for l in layers {
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -l.dy * s), blur: l.blur * s,
                          color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: l.alpha))
            ctx.addPath(path)
            ctx.setFillColor(bodyColor.with(alpha: 1).cgColor)
            ctx.fillPath()
            ctx.restoreGState()
        }

        // --- Window body.
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        ctx.setFillColor(bodyColor.with(alpha: 1).cgColor)
        ctx.fill(winRect)
        ctx.draw(content, in: CGRect(x: winRect.minX, y: winRect.minY, width: Double(content.width), height: Double(content.height)))
        if titleH > 0 {
            drawTitleBar(in: ctx, rect: CGRect(x: winRect.minX, y: winRect.maxY - Double(titleH), width: winRect.width, height: Double(titleH)),
                         frame: o.frame, body: bodyColor, title: o.title, scale: s)
        }
        ctx.restoreGState()

        // --- Hairline edge so dark windows don't melt into dark backgrounds.
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: winRect.insetBy(dx: 0.5, dy: 0.5), cornerWidth: radius, cornerHeight: radius, transform: nil))
        let edge = bodyColor.luminance < 0.5 ? RGBA(1, 1, 1, 0.14) : RGBA(0, 0, 0, 0.10)
        ctx.setStrokeColor(edge.cgColor)
        ctx.setLineWidth(1)
        ctx.strokePath()
        ctx.restoreGState()

        return ctx.makeImage() ?? input
    }

    static func drawBackground(_ bg: Background, in ctx: CGContext, size: CGSize) {
        let full = CGRect(origin: .zero, size: size)
        switch bg {
        case .transparent:
            ctx.clear(full)
        case let .solid(c):
            ctx.setFillColor(c.cgColor)
            ctx.fill(full)
        case let .gradient(p):
            let colors = p.colors.map(\.cgColor) as CFArray
            let n = p.colors.count
            let locs: [CGFloat] = (0..<n).map { CGFloat($0) / CGFloat(max(1, n - 1)) }
            let g = CGGradient(colorsSpace: Canvas.srgb, colors: colors, locations: locs)!
            ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: size.height), end: CGPoint(x: size.width, y: 0),
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            // Soft light bloom in the upper-left for depth.
            let bloom = CGGradient(colorsSpace: Canvas.srgb,
                                   colors: [CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.18), CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0)] as CFArray,
                                   locations: [0, 1])!
            let c = CGPoint(x: size.width * 0.2, y: size.height * 0.85)
            ctx.drawRadialGradient(bloom, startCenter: c, startRadius: 0, endCenter: c, endRadius: max(size.width, size.height) * 0.6, options: [])
        case let .image(path):
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            if let src = CGImageSourceCreateWithURL(url as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) {
                // Aspect-fill.
                let sx = size.width / CGFloat(img.width), sy = size.height / CGFloat(img.height)
                let k = max(sx, sy)
                let w = CGFloat(img.width) * k, h = CGFloat(img.height) * k
                ctx.draw(img, in: CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h))
            } else {
                drawBackground(.gradient(.ocean), in: ctx, size: size)
            }
        }
    }

    static func drawTitleBar(in ctx: CGContext, rect: CGRect, frame: WindowFrame, body: RGBA, title: String?, scale s: Double) {
        let dark: Bool = switch frame {
        case .macosDark: true
        case .macosLight: false
        default: body.luminance < 0.5
        }
        let barColor: RGBA = switch frame {
        case .macos: body.mix(dark ? RGBA(1, 1, 1) : RGBA(0, 0, 0), dark ? 0.06 : 0.04)
        case .macosDark: RGBA(hex: "#2A2A2E")!
        default: RGBA(hex: "#ECECEE")!
        }
        ctx.setFillColor(barColor.with(alpha: 1).cgColor)
        ctx.fill(rect)
        ctx.setFillColor((dark ? RGBA(0, 0, 0, 0.35) : RGBA(0, 0, 0, 0.08)).cgColor)
        ctx.fill(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: max(1, s * 0.5)))

        let d = 12 * s
        let cy = rect.midY
        let lights = ["#FF5F57", "#FEBC2E", "#28C840"].compactMap { RGBA(hex: $0) }
        for (i, c) in lights.enumerated() {
            let cx = rect.minX + 20 * s + Double(i) * 20 * s
            let r = CGRect(x: cx - d / 2, y: cy - d / 2, width: d, height: d)
            ctx.setFillColor(c.cgColor)
            ctx.fillEllipse(in: r)
            ctx.setStrokeColor(RGBA(0, 0, 0, 0.12).cgColor)
            ctx.setLineWidth(max(1, 0.5 * s))
            ctx.strokeEllipse(in: r.insetBy(dx: 0.25 * s, dy: 0.25 * s))
        }
        if let title, !title.isEmpty {
            let l = TextDraw.line(title, size: 13 * s, color: dark ? RGBA(1, 1, 1, 0.75) : RGBA(0, 0, 0, 0.7), bold: true)
            let w = CTLineGetTypographicBounds(l, nil, nil, nil)
            ctx.textPosition = CGPoint(x: rect.midX - w / 2, y: cy - 4.5 * s)
            CTLineDraw(l, ctx)
        }
    }
}

/// "Auto-balance": screenshots are often cropped unevenly (more space on the right than the left).
/// If the image has a uniform border colour, crop to the content and re-pad it evenly with that colour.
public enum BorderAnalysis {
    /// The colour of the outermost pixel ring, if at least 92% of it is (nearly) one colour.
    public static func borderColor(of bm: Bitmap) -> RGBA? {
        var pts: [(Int, Int)] = []
        let stepX = max(1, bm.width / 400), stepY = max(1, bm.height / 400)
        for x in stride(from: 0, to: bm.width, by: stepX) { pts.append((x, 0)); pts.append((x, bm.height - 1)) }
        for y in stride(from: 0, to: bm.height, by: stepY) { pts.append((0, y)); pts.append((bm.width - 1, y)) }
        guard let dom = bm.dominantColor(pts) else { return nil }
        let close = pts.filter { bm.pixel($0.0, $0.1).distance(dom) < 0.06 }.count
        return Double(close) / Double(pts.count) >= 0.92 ? dom : nil
    }

    /// Bounding box (top-left coords) of pixels that differ from `border`.
    public static func contentBounds(_ bm: Bitmap, border: RGBA, tolerance: Double = 0.08) -> CGRect? {
        var minX = bm.width, minY = bm.height, maxX = -1, maxY = -1
        for y in 0..<bm.height {
            for x in 0..<bm.width where bm.pixel(x, y).distance(border) > tolerance {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    public static func balance(_ image: CGImage, border: RGBA, scale s: Double) -> CGImage? {
        let bm = Bitmap(image)
        guard let c = contentBounds(bm, border: border) else { return nil }
        let left = c.minX, top = c.minY
        let right = Double(bm.width) - c.maxX, bottom = Double(bm.height) - c.maxY
        let margins = [left, top, right, bottom]
        // Edge-to-edge UI (sidebars, toolbars touching the border): nothing to balance.
        if margins.min()! < 2 { return nil }
        // Already balanced (within 2pt)? Leave it alone.
        if (margins.max()! - margins.min()!) < 2 * s { return nil }
        let m = min(max(margins.reduce(0, +) / 4, 16 * s), 48 * s).rounded()
        let W = Int(c.width + 2 * m), H = Int(c.height + 2 * m)
        let ctx = Canvas.make(width: W, height: H)
        ctx.setFillColor(border.with(alpha: 1).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        guard let crop = image.cropping(to: c) else { return nil }
        ctx.draw(crop, in: CGRect(x: m, y: m, width: c.width, height: c.height))
        return ctx.makeImage()
    }
}
