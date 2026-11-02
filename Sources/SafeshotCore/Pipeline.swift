import CoreGraphics
import Foundation

/// A detection with geometry, as shown in reports and the review window.
public struct Finding: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var rule: String
    public var description: String
    public var severity: Severity
    public var category: RuleCategory
    /// Masked preview, e.g. `sk-ant-…a1F`. The full value is never stored in a Finding.
    public var preview: String
    /// Pixel boxes (top-left origin) that will be covered, already padded.
    public var boxes: [Box]
    public var alsoMatched: [String]
    /// Toggled off in the review window -> not redacted.
    public var enabled: Bool = true
}

public struct Analysis: Sendable {
    public var ocr: OCRResult
    public var findings: [Finding]
    /// Raw document findings (contain the unmasked text; used by tests, never serialised).
    public var documentFindings: [DocumentFinding]
}

public struct RenderOptions: Sendable {
    public var redaction: RedactionStyle = .pixelate
    /// Outline boxes instead of redacting.
    public var dryRun = false
    /// nil = no beautification (redacted screenshot only).
    public var beautify: BeautifyOptions? = BeautifyOptions()
    public init() {}
}

public final class Pipeline: Sendable {
    public let detector: Detector
    public init(detector: Detector) { self.detector = detector }

    public convenience init(config: Config = Config()) throws {
        self.init(detector: try config.makeDetector())
    }

    public func analyze(_ image: CGImage) throws -> Analysis {
        let ocr = try TextRecognizer.recognize(image)
        return analyze(ocr: ocr)
    }

    public func analyze(ocr: OCRResult) -> Analysis {
        let flags = LineLayout.wrapFlags(ocr.lines, imageWidth: Double(ocr.width))
        let allLines = ocr.lines + ocr.alternates
        let scanLines = zip(ocr.lines, flags).map { ScanLine($0.text, wrapsToNext: $1) }
            + ocr.alternates.map { ScanLine($0.text) }
        let docs = DocumentScanner(detector: detector).scan(scanLines)
        var findings: [Finding] = []
        for (n, d) in docs.enumerated() {
            let rule = detector.rule(id: d.ruleID)
            var boxes: [Box] = []
            for seg in d.segments {
                let line = allLines[seg.line]
                let r = line.rect(for: seg.range)
                guard !r.isNull else { continue }
                boxes.append(Box(Pipeline.pad(r, line: line, neighbours: allLines, imageWidth: ocr.width, imageHeight: ocr.height)).rounded)
            }
            findings.append(Finding(
                id: "F\(n + 1)", rule: d.ruleID, description: rule?.description ?? d.ruleID,
                severity: rule?.severity ?? .high, category: rule?.category ?? .custom,
                preview: rule?.privateKeyBlock == true ? "PRIVATE KEY…" : Mask.preview(d.text),
                boxes: boxes, alsoMatched: d.alsoMatched))
        }
        return Analysis(ocr: ocr, findings: Pipeline.dedupe(findings), documentFindings: docs)
    }

    /// Extra OCR passes can read the same text twice (overlapping lines). Fold a finding into another one
    /// when most of its area is already covered; its boxes are kept so nothing is lost.
    static func dedupe(_ findings: [Finding]) -> [Finding] {
        func area(_ b: Box) -> Double { b.width * b.height }
        func overlap(_ a: Box, _ b: Box) -> Double {
            let i = a.rect.intersection(b.rect)
            return i.isNull ? 0 : Double(i.width * i.height)
        }
        let order = findings.indices.sorted {
            let a = findings[$0].boxes.map(area).reduce(0, +), b = findings[$1].boxes.map(area).reduce(0, +)
            return a > b
        }
        var kept: [Finding] = []
        for i in order {
            let f = findings[i]
            let total = f.boxes.map(area).reduce(0, +)
            var bestIdx: Int?
            var best = 0.0
            for (k, g) in kept.enumerated() {
                let o = f.boxes.reduce(0.0) { acc, b in acc + g.boxes.map { overlap(b, $0) }.reduce(0, +) }
                if o > best { best = o; bestIdx = k }
            }
            if let k = bestIdx, total > 0, best >= 0.6 * total {
                kept[k].boxes += f.boxes
                if f.rule != kept[k].rule && !kept[k].alsoMatched.contains(f.rule) { kept[k].alsoMatched.append(f.rule) }
            } else {
                kept.append(f)
            }
        }
        kept.sort { a, b in
            let ba = a.boxes.first ?? Box(x: 0, y: 0, width: 0, height: 0), bb = b.boxes.first ?? Box(x: 0, y: 0, width: 0, height: 0)
            return (ba.y, ba.x) < (bb.y, bb.x)
        }
        for i in kept.indices { kept[i].id = "F\(i + 1)" }
        return kept
    }

    /// Padding that never spills onto neighbouring text.
    ///
    /// * horizontally: a quarter glyph on each side (the separator before a secret, like `=`, stays visible)
    /// * vertically: the line's own box plus 10% of its height, but never past the midpoint between this
    ///   line and the line above/below it (so bars on consecutive rows don't overlap or clip glyphs), and
    ///   never inside the line's own box (so nothing of the secret is uncovered).
    public static func pad(_ r: CGRect, line: OCRLine, neighbours: [OCRLine], imageWidth: Int, imageHeight: Int) -> CGRect {
        let cw = max(2, line.averageCharWidth)
        let lb = line.box.rect
        let dx = max(1.5, cw * 0.25)
        let dy = max(2, lb.height * 0.10)
        var x0 = r.minX - dx, x1 = r.maxX + dx
        var y0 = min(r.minY, lb.minY) - dy, y1 = max(r.maxY, lb.maxY) + dy
        let center = lb.midY
        for m in neighbours {
            let mb = m.box.rect
            guard mb != lb, mb.maxX > x0, mb.minX < x1 else { continue }
            guard abs(mb.midY - center) > 0.5 * min(mb.height, lb.height) else { continue } // same row
            if mb.midY < center {
                y0 = max(y0, (mb.maxY + lb.minY) / 2)
            } else {
                y1 = min(y1, (lb.maxY + mb.minY) / 2)
            }
        }
        y0 = min(y0, lb.minY); y1 = max(y1, lb.maxY)
        x0 = max(0, x0); x1 = min(Double(imageWidth), x1)
        y0 = max(0, y0); y1 = min(Double(imageHeight), y1)
        return CGRect(x: x0, y: y0, width: max(0, x1 - x0), height: max(0, y1 - y0))
    }

    public static func regions(_ findings: [Finding]) -> [RedactionRegion] {
        findings.filter(\.enabled).flatMap { f in
            f.boxes.map { RedactionRegion(rect: $0.rect, severity: f.severity, label: f.rule) }
        }
    }

    public static func render(_ image: CGImage, scale: Double, findings: [Finding], options: RenderOptions) -> CGImage {
        let regions = regions(findings)
        let redacted = options.dryRun
            ? Redactor.outline(image, regions: regions, scale: scale)
            : Redactor.apply(image, regions: regions, style: options.redaction)
        guard let b = options.beautify else { return redacted }
        return Beautifier.render(redacted, scale: scale, options: b)
    }
}
