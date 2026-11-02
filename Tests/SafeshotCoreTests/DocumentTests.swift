import CoreGraphics
import Foundation
import Testing
@testable import SafeshotCore
import SafeshotFixtures

@Suite("Document scanning, config, geometry, rendering")
struct DocumentTests {
    let scanner = DocumentScanner(detector: detector)

    @Test func wrappedTokenIsJoined() {
        let jwt = FakeSecrets.jwt as NSString
        let a = "Authorization: Bearer " + jwt.substring(to: 40)
        let b = jwt.substring(from: 40) + " https://api.example.com"
        let found = scanner.scan([ScanLine(a, wrapsToNext: true), ScanLine(b)])
        let f = found.first { $0.ruleID == "jwt" }
        #expect(f != nil)
        #expect(f?.segments.count == 2)
        #expect(f?.segments.last?.line == 1)
        #expect(f?.segments.last?.location == 0)
        #expect(f?.segments.last?.length == jwt.length - 40)
    }

    @Test func noJoinWithoutWrapFlag() {
        let found = scanner.scan([ScanLine("TOKEN_PART=abc"), ScanLine("DB_HOST=db.internal")])
        #expect(found.allSatisfy { $0.segments.count == 1 })
    }

    @Test func overlappingRulesAreClustered() {
        let found = scanner.scan([ScanLine("ANTHROPIC_API_KEY=" + FakeSecrets.anthropic)])
        #expect(found.count == 1)
        #expect(found[0].ruleID == "anthropic-api-key")
        #expect(found[0].alsoMatched.contains("secret-assignment"))
    }

    @Test func privateKeyBlockCoversBody() {
        let lines = ["deployKey: `-----BEGIN OPENSSH PRIVATE KEY-----"] + FakeSecrets.privateKeyBody + ["-----END OPENSSH PRIVATE KEY-----`", "});"]
        // Editor gutter numbers interleaved, as OCR returns them.
        var withGutter: [ScanLine] = []
        for (i, l) in lines.enumerated() { withGutter.append(ScanLine(String(i + 1))); withGutter.append(ScanLine(l)) }
        let found = scanner.scan(withGutter)
        let pk = found.first { $0.ruleID == "private-key" }
        #expect(pk != nil)
        #expect(pk?.segments.count == FakeSecrets.privateKeyBody.count)
    }

    @Test func configTogglesAndCustomRules() throws {
        let json = """
        { "rules": { "email": false },
          "customRules": [ { "id": "acme", "pattern": "acme_[a-z0-9]{8}", "severity": "critical" } ],
          "allowlist": { "strings": ["203.0.113.42"] } }
        """
        let config = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        let d = try config.makeDetector()
        let ids = Set(d.scan("mail jane.doe@example.com token acme_abcd1234 host 203.0.113.42 198.51.100.7").map(\.ruleID))
        #expect(!ids.contains("email"))
        #expect(ids.contains("acme"))
        #expect(ids.contains("ipv4"))
        #expect(d.scan("203.0.113.42").isEmpty)
        #expect(d.scan("127.0.0.1").isEmpty) // default allowlist still active
        #expect(try config.makeDetector(extraDisabled: ["ipv4"]).scan("198.51.100.7").isEmpty)
        let starter = try JSONDecoder().decode(Config.self, from: Data(Config.starterJSON.utf8))
        #expect(starter.defaults.redact == "pixelate")
    }

    @Test func badCustomRegexIsReported() {
        var c = Config()
        c.customRules = [Rule(id: "broken", description: "", severity: .high, category: .custom, pattern: "([unclosed")]
        #expect(throws: DetectorError.self) { try c.makeDetector() }
    }

    @Test func geometryInterpolatesAndPads() {
        // A synthetic monospace line: 10 px per character, no glyph boxes.
        let text = "KEY=SECRETVALUE done"
        let words = [
            OCRWord(text: "KEY=SECRETVALUE", location: 0, length: 15, box: Box(x: 100, y: 50, width: 150, height: 20)),
            OCRWord(text: "done", location: 16, length: 4, box: Box(x: 260, y: 50, width: 40, height: 20)),
        ]
        let line = OCRLine(text: text, box: Box(x: 100, y: 50, width: 200, height: 20), words: words, chars: Array(repeating: nil, count: 20))
        let r = line.rect(for: NSRange(location: 4, length: 11))
        // Secret starts at x=140 and ends at the word edge (250).
        #expect(r.minX <= 140 && r.minX >= 135)
        #expect(r.maxX >= 250)
        #expect(r.maxX < 260) // doesn't touch "done"
    }

    @Test func paddingIsClampedBetweenRows() {
        // Three tightly packed rows (pitch 30 px, text 24 px). The middle row's box must not reach the
        // midpoint between rows, but must always cover its own line box.
        func line(_ y: Double) -> OCRLine {
            OCRLine(text: "KEY=SECRETVALUE", box: Box(x: 0, y: y, width: 150, height: 24))
        }
        let rows = [line(0), line(30), line(60)]
        let r = Pipeline.pad(CGRect(x: 40, y: 28, width: 110, height: 28), line: rows[1], neighbours: rows, imageWidth: 400, imageHeight: 100)
        #expect(r.minY >= 27 && r.minY <= 30)   // midpoint between row 0 bottom (24) and row 1 top (30) is 27
        #expect(r.maxY <= 57 && r.maxY >= 54)   // midpoint between row 1 bottom (54) and row 2 top (60) is 57
        #expect(r.minX >= 37 && r.minX < 40)    // only a quarter glyph (10 px glyphs) of horizontal padding
        // Without neighbours the normal padding applies.
        let lone = Pipeline.pad(CGRect(x: 40, y: 30, width: 110, height: 24), line: rows[1], neighbours: [rows[1]], imageWidth: 400, imageHeight: 100)
        #expect(lone.minY < 28 && lone.maxY > 56)
    }

    @Test func wrapFlagsFromGeometry() {
        func line(_ t: String, x: Double, y: Double, w: Double) -> OCRLine {
            OCRLine(text: t, box: Box(x: x, y: y, width: w, height: 20))
        }
        let lines = [
            line(String(repeating: "a", count: 60), x: 10, y: 10, w: 600),   // reaches image edge (620)
            line(String(repeating: "b", count: 20), x: 10, y: 34, w: 200),
            line("short", x: 10, y: 58, w: 50),
        ]
        #expect(LineLayout.wrapFlags(lines, imageWidth: 620) == [true, false, false])
    }

    @Test func redactionDestroysOriginalPixels() {
        // White image with a black block: after redaction with any style the region must not contain
        // the original pure-black pixels (it is repainted from the surrounding colour first).
        let ctx = Canvas.make(width: 200, height: 100)
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 60, y: 40, width: 80, height: 20))
        let img = ctx.makeImage()!
        for style in [RedactionStyle.pixelate, .blur, .bar] {
            let out = Bitmap(Redactor.apply(img, regions: [RedactionRegion(rect: CGRect(x: 55, y: 35, width: 90, height: 30))], style: style))
            var darkest = 1.0
            for y in 35..<65 { for x in 55..<145 { darkest = min(darkest, out.pixel(x, y).luminance) } }
            #expect(darkest > 0.3, "\(style): darkest pixel \(darkest)")
            #expect(out.pixel(5, 5).luminance > 0.99) // outside untouched
        }
    }

    @Test func beautifySizesAndScale() {
        let ctx = Canvas.make(width: 400, height: 200)
        ctx.setFillColor(CGColor(srgbRed: 0.1, green: 0.1, blue: 0.1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 200))
        let img = ctx.makeImage()!
        var o = BeautifyOptions()
        o.padding = 50
        let out = Beautifier.render(img, scale: 2, options: o)
        #expect(out.width == 400 + 200 && out.height == 200 + 200) // padding is in points (x2)
        o.size = .aspect(16, 9)
        let wide = Beautifier.render(img, scale: 2, options: o)
        #expect(abs(Double(wide.width) / Double(wide.height) - 16.0 / 9.0) < 0.01)
        o.frame = .macos
        o.size = .original
        let framed = Beautifier.render(img, scale: 1, options: o)
        #expect(framed.height == 200 + 28 + 100)
        #expect(Background.parse("#ff0000") == .solid(RGBA(1, 0, 0)))
        #expect(Background.parse("transparent") == .transparent)
        #expect(Background.parse("nonsense-preset") == nil)
        #expect(SizePreset.parse("twitter") == .aspect(16, 9))
    }

    @Test func autoBalanceEvensMargins() {
        let ctx = Canvas.make(width: 300, height: 200)
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 300, height: 200))
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 10, y: 50, width: 100, height: 100)) // 10 px left, 190 px right
        let img = ctx.makeImage()!
        let bm = Bitmap(img)
        let border = BorderAnalysis.borderColor(of: bm)!
        let balanced = Bitmap(BorderAnalysis.balance(img, border: border, scale: 1)!)
        let c = BorderAnalysis.contentBounds(balanced, border: border)!
        #expect(abs(c.minX - (Double(balanced.width) - c.maxX)) <= 1)
        #expect(abs(c.minY - (Double(balanced.height) - c.maxY)) <= 1)
    }
}
