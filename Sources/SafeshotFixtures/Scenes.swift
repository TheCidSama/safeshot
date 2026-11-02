import AppKit
import CoreGraphics
import CoreText
import Foundation
import SafeshotCore

/// A synthetic screenshot with ground truth.
public struct Scene: @unchecked Sendable {
    public var name: String
    public var image: CGImage
    public var scale: Double
    /// Values that must not be recoverable from the output.
    public var secrets: [String]
    /// Text that must remain readable.
    public var benign: [String]
}

public enum FontChoice: String, CaseIterable, Sendable {
    case menlo, sfMono, monaco, courier, sfPro, helvetica

    public func font(size: Double) -> CTFont {
        switch self {
        case .menlo: CTFontCreateWithName("Menlo-Regular" as CFString, size, nil)
        case .sfMono: NSFont.monospacedSystemFont(ofSize: size, weight: .regular) as CTFont
        case .monaco: CTFontCreateWithName("Monaco" as CFString, size, nil)
        case .courier: CTFontCreateWithName("Courier" as CFString, size, nil)
        case .sfPro: NSFont.systemFont(ofSize: size) as CTFont
        case .helvetica: CTFontCreateWithName("Helvetica" as CFString, size, nil)
        }
    }
}

public struct Theme: Sendable {
    public var bg: RGBA, fg: RGBA, dim: RGBA, key: RGBA, value: RGBA, accent: RGBA, string: RGBA, prompt: RGBA

    public static let dark = Theme(
        bg: RGBA(hex: "#1E1E2E")!, fg: RGBA(hex: "#CDD6F4")!, dim: RGBA(hex: "#7F849C")!, key: RGBA(hex: "#89B4FA")!,
        value: RGBA(hex: "#A6E3A1")!, accent: RGBA(hex: "#F5C2E7")!, string: RGBA(hex: "#F9E2AF")!, prompt: RGBA(hex: "#94E2D5")!)
    public static let light = Theme(
        bg: RGBA(hex: "#FFFFFF")!, fg: RGBA(hex: "#24292F")!, dim: RGBA(hex: "#6E7781")!, key: RGBA(hex: "#0550AE")!,
        value: RGBA(hex: "#116329")!, accent: RGBA(hex: "#8250DF")!, string: RGBA(hex: "#0A3069")!, prompt: RGBA(hex: "#CF222E")!)
}

typealias Span = (String, RGBA)

/// Draws in points with a top-left origin onto a `scale`x bitmap.
final class Painter {
    let ctx: CGContext
    let scale: Double
    let size: CGSize

    init(width: Double, height: Double, scale: Double, background: RGBA) {
        self.scale = scale
        size = CGSize(width: width, height: height)
        ctx = Canvas.make(width: Int(width * scale), height: Int(height * scale))
        ctx.translateBy(x: 0, y: height * scale)
        ctx.scaleBy(x: scale, y: -scale)
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        fill(CGRect(x: 0, y: 0, width: width, height: height), background)
    }

    func fill(_ r: CGRect, _ c: RGBA, radius: Double = 0) {
        ctx.setFillColor(c.cgColor)
        if radius > 0 {
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.fillPath()
        } else {
            ctx.fill(r)
        }
    }

    /// Draw spans with the baseline at `y`; returns the advance width.
    @discardableResult
    func text(_ spans: [Span], x: Double, baseline y: Double, font: CTFont) -> Double {
        let s = NSMutableAttributedString()
        for (t, c) in spans {
            s.append(NSAttributedString(string: t, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): c.cgColor,
            ]))
        }
        let line = CTLineCreateWithAttributedString(s)
        ctx.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(line, ctx)
        return CTLineGetTypographicBounds(line, nil, nil, nil)
    }

    func image() -> CGImage { ctx.makeImage()! }
}

func advance(_ font: CTFont) -> Double {
    var g = CGGlyph(0)
    var ch = UniChar(("M" as Character).asciiValue!)
    CTFontGetGlyphsForCharacters(font, &ch, &g, 1)
    var adv = CGSize.zero
    CTFontGetAdvancesForGlyphs(font, .horizontal, &g, &adv, 1)
    return adv.width
}

public enum Scenes {
    typealias S = FakeSecrets

    /// A terminal dumping a `.env` file and running `curl` with a bearer token. Long lines soft-wrap at
    /// `columns`, like a real terminal.
    public static func terminal(theme t: Theme = .dark, font fc: FontChoice = .menlo, size: Double = 13, columns: Int = 96, scale: Double = 2) -> Scene {
        let logical: [[Span]] = [
            [("~/acme-api", t.prompt), (" (main) ", t.accent), ("$ ", t.fg), ("cat .env", t.fg)],
            [("NODE_ENV", t.key), ("=production", t.fg)],
            [("PORT", t.key), ("=8080", t.fg)],
            [("ANTHROPIC_API_KEY", t.key), ("=" + S.anthropic, t.value)],
            [("OPENAI_API_KEY", t.key), ("=" + S.openai, t.value)],
            [("GITHUB_TOKEN", t.key), ("=" + S.github, t.value)],
            [("AWS_ACCESS_KEY_ID", t.key), ("=" + S.awsKeyID, t.value)],
            [("AWS_SECRET_ACCESS_KEY", t.key), ("=" + S.awsSecret, t.value)],
            [("STRIPE_SECRET_KEY", t.key), ("=" + S.stripe, t.value)],
            [("DATABASE_URL", t.key), ("=" + S.databaseURL, t.value)],
            [("SESSION_SECRET", t.key), ("=" + S.sessionSecret, t.value)],
            [("LOG_LEVEL", t.key), ("=info", t.fg)],
            [("", t.fg)],
            [("~/acme-api", t.prompt), (" (main) ", t.accent), ("$ ", t.fg),
             ("curl -s -H \"Authorization: Bearer " + S.jwt + "\" https://api.example.com/v1/me", t.fg)],
            [("{\"id\": 1042, \"email\": \"" + S.email1 + "\", \"plan\": \"pro\", \"region\": \"eu-west-1\"}", t.string)],
            [("~/acme-api", t.prompt), (" (main) ", t.accent), ("$ ", t.fg), ("npm run build", t.fg)],
            [("Build finished in 4.2s", t.value)],
        ]
        let font = fc.font(size: size)
        let cw = advance(font)
        let lineH = (size * 1.45).rounded()
        // Soft-wrap spans at `columns` characters.
        var visual: [[Span]] = []
        for spans in logical {
            var cur: [Span] = []
            var col = 0
            for (text, color) in spans {
                var rest = Substring(text)
                while !rest.isEmpty {
                    let take = min(rest.count, columns - col)
                    cur.append((String(rest.prefix(take)), color))
                    rest = rest.dropFirst(take)
                    col += take
                    if col >= columns { visual.append(cur); cur = []; col = 0 }
                }
            }
            if !cur.isEmpty || spans.allSatisfy({ $0.0.isEmpty }) { visual.append(cur) }
        }
        let padX = 14.0, padY = 14.0
        let W = (Double(columns) * cw + 2 * padX).rounded(.up)
        let H = (Double(visual.count) * lineH + 2 * padY).rounded(.up)
        let p = Painter(width: W, height: H, scale: scale, background: t.bg)
        for (i, spans) in visual.enumerated() {
            p.text(spans, x: padX, baseline: padY + Double(i) * lineH + size, font: font)
        }
        return Scene(
            name: "terminal-\(fc.rawValue)-\(Int(size))-\(t.bg.luminance < 0.5 ? "dark" : "light")",
            image: p.image(), scale: scale,
            secrets: [S.anthropic, S.openai, S.github, S.awsKeyID, S.awsSecret, S.stripe, S.dbPassword, S.sessionSecret, S.jwt, S.email1],
            benign: ["cat .env", "NODE_ENV=production", "PORT=8080", "LOG_LEVEL=info", "npm run build", "Build finished in 4.2s", "ANTHROPIC_API_KEY", "GITHUB_TOKEN", "DATABASE_URL"])
    }

    /// A code editor showing a config file (line numbers, syntax colours, private key in a template string).
    public static func editor(theme t: Theme = .dark, font fc: FontChoice = .sfMono, size: Double = 13, scale: Double = 2) -> Scene {
        let lines: [[Span]] = [
            [("import", t.accent), (" { defineConfig } ", t.fg), ("from", t.accent), (" \"./lib/config\";", t.string)],
            [("", t.fg)],
            [("export default", t.accent), (" defineConfig({", t.fg)],
            [("  region: ", t.key), ("\"eu-west-1\",", t.string)],
            [("  stripeKey: ", t.key), ("\"" + S.stripe + "\",", t.string)],
            [("  slackToken: ", t.key), ("\"" + S.slack + "\",", t.string)],
            [("  mapsKey: ", t.key), ("\"" + S.google + "\",", t.string)],
            [("  hfToken: ", t.key), ("\"" + S.hfToken + "\",", t.string)],
            [("  database: ", t.key), ("{ url: ", t.fg), ("\"" + S.databaseURL + "\" },", t.string)],
            [("  adminEmail: ", t.key), ("\"" + S.email2 + "\",", t.string)],
            [("  allowedHosts: ", t.key), ("[\"" + S.ipv4a + "\", \"" + S.ipv6 + "\"],", t.string)],
            [("  retries: ", t.key), ("3,", t.value)],
            [("  deployKey: ", t.key), ("`-----BEGIN OPENSSH PRIVATE KEY-----", t.string)],
            [(S.privateKeyBody[0], t.string)],
            [(S.privateKeyBody[1], t.string)],
            [(S.privateKeyBody[2], t.string)],
            [("-----END OPENSSH PRIVATE KEY-----`,", t.string)],
            [("});", t.fg)],
            [("// TODO: rotate keys before launch", t.dim)],
        ]
        let font = fc.font(size: size)
        let cw = advance(font)
        let lineH = (size * 1.6).rounded()
        let gutter = 4 * cw + 18
        let maxChars = lines.map { $0.reduce(0) { $0 + $1.0.count } }.max() ?? 80
        let W = (gutter + Double(maxChars) * cw + 40).rounded(.up)
        let H = (Double(lines.count) * lineH + 32).rounded(.up)
        let p = Painter(width: W, height: H, scale: scale, background: t.bg)
        let gutterBG = t.bg.luminance < 0.5 ? t.bg.mix(RGBA(0, 0, 0), 0.18) : t.bg.mix(RGBA(0, 0, 0), 0.03)
        p.fill(CGRect(x: 0, y: 0, width: gutter - 8, height: H), gutterBG)
        for (i, spans) in lines.enumerated() {
            let base = 16 + Double(i) * lineH + size
            let num = String(i + 1)
            p.text([(num, t.dim)], x: gutter - 16 - Double(num.count) * cw, baseline: base, font: font)
            p.text(spans, x: gutter, baseline: base, font: font)
        }
        return Scene(
            name: "editor-\(fc.rawValue)-\(Int(size))-\(t.bg.luminance < 0.5 ? "dark" : "light")",
            image: p.image(), scale: scale,
            secrets: [S.stripe, S.slack, S.google, S.hfToken, S.dbPassword, S.email2, S.ipv4a, S.ipv6] + S.privateKeyBody,
            benign: ["defineConfig", "region:", "eu-west-1", "retries:", "TODO: rotate keys before launch", "stripeKey:", "slackToken:"])
    }

    /// A light SaaS admin dashboard: sidebar, stat cards and a customers table with PII.
    public static func dashboard(font fc: FontChoice = .sfPro, scale: Double = 2, dark: Bool = false) -> Scene {
        let bg = dark ? RGBA(hex: "#0F1117")! : RGBA(hex: "#F6F7F9")!
        let card = dark ? RGBA(hex: "#181B23")! : RGBA(1, 1, 1)
        let ink = dark ? RGBA(hex: "#E6E8EE")! : RGBA(hex: "#111827")!
        let sub = dark ? RGBA(hex: "#8B93A7")! : RGBA(hex: "#6B7280")!
        let line = dark ? RGBA(hex: "#262B36")! : RGBA(hex: "#E5E7EB")!
        let accent = RGBA(hex: "#6366F1")!
        let W = 1180.0, H = 590.0
        let p = Painter(width: W, height: H, scale: scale, background: bg)
        let f13 = fc.font(size: 13), f12 = fc.font(size: 12)
        let bold = CTFontCreateCopyWithSymbolicTraits(fc.font(size: 20), 20, nil, .boldTrait, .boldTrait) ?? fc.font(size: 20)
        let bold14 = CTFontCreateCopyWithSymbolicTraits(fc.font(size: 14), 14, nil, .boldTrait, .boldTrait) ?? fc.font(size: 14)

        // Sidebar
        p.fill(CGRect(x: 0, y: 0, width: 200, height: H), card)
        p.fill(CGRect(x: 200, y: 0, width: 1, height: H), line)
        p.fill(CGRect(x: 20, y: 22, width: 26, height: 26), accent, radius: 7)
        p.text([("Acme Console", ink)], x: 56, baseline: 40, font: bold14)
        for (i, item) in ["Overview", "Customers", "Billing", "API Keys", "Settings"].enumerated() {
            let y = 90 + Double(i) * 36
            if i == 1 { p.fill(CGRect(x: 12, y: y - 4, width: 176, height: 30), accent.with(alpha: 0.12), radius: 7) }
            p.text([(item, i == 1 ? accent : sub)], x: 28, baseline: y + 15, font: f13)
        }

        // Header
        p.text([("Customers", ink)], x: 232, baseline: 52, font: bold)
        p.text([("Signed in as " + S.email3, sub)], x: 232, baseline: 76, font: f12)

        // Stat cards
        let stats = [("Active customers", "2,481"), ("MRR", "$48,210"), ("Churn (30d)", "1.8%")]
        for (i, s) in stats.enumerated() {
            let x = 232 + Double(i) * 312
            p.fill(CGRect(x: x, y: 100, width: 296, height: 84), card, radius: 10)
            p.text([(s.0, sub)], x: x + 18, baseline: 128, font: f12)
            p.text([(s.1, ink)], x: x + 18, baseline: 164, font: bold)
        }

        // Table
        let tx = 232.0, ty = 206.0, tw = 920.0
        p.fill(CGRect(x: tx, y: ty, width: tw, height: 362), card, radius: 10)
        let cols: [(String, Double)] = [("Name", 18), ("Email", 168), ("Phone", 388), ("Last login IP", 548), ("Card", 708)]
        for (title, x) in cols { p.text([(title, sub)], x: tx + x, baseline: ty + 30, font: f12) }
        p.fill(CGRect(x: tx, y: ty + 44, width: tw, height: 1), line)
        let rows: [[String]] = [
            ["Jane Doe", S.email1, S.phone, S.ipv4a, S.card],
            ["Marco Rossi", S.email3, "+44 20 7946 0958", S.ipv4b, "5555 5555 5555 4444"],
            ["Ops Team", S.email2, "+1 (555) 010-9921", "192.0.2.15", "4000 0566 5566 5556"],
            ["Ana Lima", "ana.lima@example.com", "+55 11 5555 0134", "203.0.113.99", "3782 822463 10005"],
        ]
        for (r, row) in rows.enumerated() {
            let y = ty + 80 + Double(r) * 78
            for (c, value) in row.enumerated() {
                p.text([(value, c == 0 ? ink : sub)], x: tx + cols[c].1, baseline: y, font: c == 0 ? bold14 : f13)
            }
            p.text([("Plan: Pro · since 2023", sub)], x: tx + 18, baseline: y + 22, font: f12)
            p.fill(CGRect(x: tx, y: y + 40, width: tw, height: 1), line)
        }
        var secrets = rows.flatMap { Array($0.dropFirst()) }
        secrets.append(S.email3)
        return Scene(
            name: "dashboard-\(fc.rawValue)-\(dark ? "dark" : "light")", image: p.image(), scale: scale,
            secrets: secrets,
            benign: ["Acme Console", "Customers", "Overview", "Billing", "Active customers", "2,481", "Jane Doe", "Marco Rossi", "Last login IP"])
    }
}
