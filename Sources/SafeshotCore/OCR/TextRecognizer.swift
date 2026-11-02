import CoreGraphics
import CoreImage
import Foundation
import Vision

/// On-device OCR with Apple's Vision framework. No network access is involved: Vision's text recogniser
/// runs locally on the Neural Engine/CPU.
public enum TextRecognizer {
    public struct Options: Sendable {
        /// Language correction is OFF by default: secrets aren't dictionary words.
        public var languageCorrection = false
        public var languages = ["en-US"]
        /// Run the fast recogniser too, for per-glyph boxes (see `LineGeometry.swift`).
        public var glyphBoxes = true
        /// Vision occasionally skips whole lines (e.g. pastel text on dark terminals). A second pass on a
        /// greyscale (inverted for dark images) copy recovers them; only lines that don't overlap the first
        /// pass are added.
        public var secondPass = true
        public init() {}
    }

    public static func recognize(_ image: CGImage, options: Options = Options()) throws -> OCRResult {
        var result = try recognizeOnce(image, options: options)
        guard options.secondPass else { return result }
        // Vision downsamples large images internally and occasionally drops whole lines (small or
        // low-contrast text). Two cheap extra passes recover them:
        //  * a greyscale copy (inverted for dark UIs)
        //  * overlapping tiles, so text is seen at a higher effective resolution
        // Lines from extra passes are added only where the first pass found nothing.
        if let variant = contrastVariant(image) {
            merge(try recognizeOnce(variant, options: options), into: &result)
        }
        for tile in tiles(width: image.width, height: image.height) {
            guard let crop = image.cropping(to: tile) else { continue }
            var r = try recognizeOnce(crop, options: options)
            r.lines = r.lines.map { $0.offsetBy(dx: Double(tile.minX), dy: Double(tile.minY)) }
            merge(r, into: &result)
        }
        // Gap filling: any band of the image that has "ink" no recognised line covers gets its own OCR pass.
        // Vision reliably reads a line in a short crop that it silently skips in the full frame.
        let bg = BorderAnalysis.borderColor(of: Bitmap(image)) ?? Bitmap(image).pixel(0, 0)
        for band in uncoveredBands(image, lines: result.lines) {
            // Isolate the band on a plain canvas (background colour above and below): Vision reads a
            // lone line far more reliably than a thin strip cut out of a busy screenshot.
            guard let crop = image.cropping(to: band) else { continue }
            // Very wide, short images are ignored by Vision; keep the canvas at least ~1:4.
            let margin = max(Int(band.height) * 2, (crop.width / 4 - crop.height) / 2)
            let ctx = Canvas.make(width: crop.width, height: crop.height + 2 * margin)
            ctx.setFillColor(bg.with(alpha: 1).cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
            ctx.draw(crop, in: CGRect(x: 0, y: margin, width: crop.width, height: crop.height))
            guard let isolated = ctx.makeImage() else { continue }
            var r = try recognizeOnce(isolated, options: options)
            r.lines = r.lines.map { $0.offsetBy(dx: Double(band.minX), dy: Double(band.minY) - Double(margin)) }
            if ProcessInfo.processInfo.environment["SAFESHOT_DEBUG"] != nil {
                FileHandle.standardError.write(Data("band \(band): \(r.lines.map(\.text))\n".utf8))
            }
            merge(r, into: &result)
        }
        result.lines = LineLayout.readingOrder(result.lines)
        return result
    }

    /// Horizontal bands (top-left coords) containing text-like ink outside every recognised line box.
    static func uncoveredBands(_ image: CGImage, lines: [OCRLine], maxBands: Int = 16) -> [CGRect] {
        let bm = Bitmap(image)
        let bg = BorderAnalysis.borderColor(of: bm) ?? bm.pixel(0, 0)
        let boxes = lines.map { $0.box.rect.insetBy(dx: -4, dy: -3) }
        let W = bm.width, H = bm.height
        let step = 2
        var rowInk = [Int](repeating: 0, count: H)
        for y in Swift.stride(from: 0, to: H, by: 1) {
            let rowBoxes = boxes.filter { CGFloat(y) >= $0.minY && CGFloat(y) <= $0.maxY }
            var x = 0
            while x < W {
                if let b = rowBoxes.first(where: { CGFloat(x) >= $0.minX && CGFloat(x) <= $0.maxX }) {
                    x = Int(b.maxX) + 1
                    continue
                }
                if bm.pixel(x, y).distance(bg) > 0.3 { rowInk[y] += 1 }
                x += step
            }
        }
        // Rows with a few glyph-like ink samples; group into segments.
        var segs: [(Int, Int)] = []
        var start: Int? = nil
        for y in 0..<H {
            let inked = rowInk[y] >= 2
            if inked, start == nil { start = y }
            if !inked, let s = start { segs.append((s, y)); start = nil }
        }
        if let s = start { segs.append((s, H)) }
        // Text rows are 6..120 px tall; merge segments separated by small gaps.
        var merged: [(Int, Int)] = []
        for seg in segs where seg.1 - seg.0 >= 5 {
            if let last = merged.last, seg.0 - last.1 < 6 { merged[merged.count - 1].1 = seg.1 } else { merged.append(seg) }
        }
        var out: [CGRect] = []
        for (a, b) in merged where b - a <= 160 {
            let h = b - a
            let pad = 3
            let y0 = max(0, a - pad), y1 = min(H, b + pad)
            out.append(CGRect(x: 0, y: y0, width: W, height: y1 - y0))
            if out.count >= maxBands { break }
        }
        return out
    }

    static func merge(_ extra: OCRResult, into result: inout OCRResult) {
        for line in extra.lines {
            let r = line.box.rect
            let area = r.width * r.height
            guard area > 0 else { continue }
            let covering = result.lines.filter { l in
                let i = l.box.rect.intersection(r)
                return !i.isNull && i.width * i.height > 0.5 * area
            }
            if covering.isEmpty {
                result.lines.append(line)
            } else if !covering.contains(where: { $0.text.contains(line.text) }),
                      !result.alternates.contains(where: { $0.text == line.text && $0.box.rect.intersects(r) }) {
                result.alternates.append(line)
            }
        }
    }

    /// Extra crops: full-height columns for wide images and full-width horizontal bands for tall ones
    /// (each overlapping its neighbour by 30%, so any line shorter than the overlap is seen whole in at
    /// least one crop). Vision reads small text in a band it skips in the full frame.
    static func tiles(width: Int, height: Int) -> [CGRect] {
        func spans(_ total: Int, _ count: Int) -> [(Double, Double)] {
            guard count > 1 else { return [] }
            let overlap = 0.3
            let len = Double(total) / (Double(count) - overlap * Double(count - 1))
            return (0..<count).map { i in
                let start = Double(i) * len * (1 - overlap)
                return (start.rounded(), min(len, Double(total) - start).rounded())
            }
        }
        let cols = width > 1000 ? 2 : 1
        let rows = height > 2000 ? Int((Double(height) / 1200).rounded(.up)) : 1
        var out: [CGRect] = []
        for (x, w) in spans(width, cols) { out.append(CGRect(x: x, y: 0, width: w, height: Double(height))) }
        for (y, h) in spans(height, rows) { out.append(CGRect(x: 0, y: y, width: Double(width), height: h)) }
        return out
    }

    static func contrastVariant(_ image: CGImage) -> CGImage? {
        let dark = BorderAnalysis.borderColor(of: Bitmap(image)).map { $0.luminance < 0.5 }
            ?? (Bitmap(image).pixel(0, 0).luminance < 0.5)
        var ci = CIImage(cgImage: image).applyingFilter("CIColorControls", parameters: ["inputSaturation": 0, "inputContrast": 1.15])
        if dark { ci = ci.applyingFilter("CIColorInvert") }
        let ctx = CIContext(options: [.workingColorSpace: Canvas.srgb, .outputColorSpace: Canvas.srgb])
        return ctx.createCGImage(ci, from: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }

    static func recognizeOnce(_ image: CGImage, options: Options) throws -> OCRResult {
        let W = Double(image.width), H = Double(image.height)

        let accurate = VNRecognizeTextRequest()
        accurate.recognitionLevel = .accurate
        accurate.usesLanguageCorrection = options.languageCorrection
        accurate.recognitionLanguages = options.languages
        accurate.minimumTextHeight = 0

        let fast = VNRecognizeTextRequest()
        fast.recognitionLevel = .fast
        fast.usesLanguageCorrection = false
        fast.recognitionLanguages = options.languages
        fast.minimumTextHeight = 0

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform(options.glyphBoxes ? [accurate, fast] : [accurate])

        func toPixels(_ r: CGRect) -> Box {
            Box(x: Double(r.minX) * W, y: (1 - Double(r.maxY)) * H, width: Double(r.width) * W, height: Double(r.height) * H)
        }

        // Fast pass: glyph boxes.
        struct GlyphLine { var box: Box; var units: [UInt16]; var rects: [Box?] }
        var glyphLines: [GlyphLine] = []
        for obs in fast.results ?? [] {
            guard let cand = obs.topCandidates(1).first else { continue }
            let s = cand.string
            var units: [UInt16] = []
            var rects: [Box?] = []
            var idx = s.startIndex
            while idx < s.endIndex {
                let next = s.index(after: idx)
                let ch = s[idx]
                var r: Box? = nil
                if !ch.isWhitespace, let b = try? cand.boundingBox(for: idx..<next) {
                    let bb = b.boundingBox
                    if bb.width > 0 { r = toPixels(bb) }
                }
                for u in OCRNormalizer.normalize(String(ch)).utf16 { units.append(u); rects.append(r) }
                idx = next
            }
            glyphLines.append(GlyphLine(box: toPixels(obs.boundingBox), units: units, rects: rects))
        }

        // Accurate pass: the text we trust, plus word boxes.
        var lines: [OCRLine] = []
        for obs in accurate.results ?? [] {
            guard let cand = obs.topCandidates(1).first else { continue }
            let original = cand.string
            let text = OCRNormalizer.normalize(original)
            let ns = text as NSString
            let lineBox = toPixels(obs.boundingBox)

            var words: [OCRWord] = []
            var i = 0
            while i < ns.length {
                while i < ns.length, isSpace(ns.character(at: i)) { i += 1 }
                let start = i
                while i < ns.length, !isSpace(ns.character(at: i)) { i += 1 }
                guard i > start else { continue }
                let r = NSRange(location: start, length: i - start)
                var wb = lineBox
                if let sr = Range(r, in: original), let b = try? cand.boundingBox(for: sr) {
                    wb = toPixels(b.boundingBox)
                }
                words.append(OCRWord(text: ns.substring(with: r), location: start, length: i - start, box: wb))
            }

            // Collect fast-pass glyphs on the same row and align them to the accurate transcription.
            let lr = lineBox.rect
            let candidates = glyphLines.filter { g in
                let gr = g.box.rect
                let overlapY = min(gr.maxY, lr.maxY) - max(gr.minY, lr.minY)
                let overlapX = min(gr.maxX, lr.maxX) - max(gr.minX, lr.minX)
                return overlapY > 0.5 * min(gr.height, lr.height) && overlapX > 0
            }.sorted { $0.box.x < $1.box.x }
            var bUnits: [UInt16] = []
            var bRects: [Box?] = []
            for g in candidates {
                if !bUnits.isEmpty { bUnits.append(0x20); bRects.append(nil) }
                bUnits += g.units
                bRects += g.rects
            }
            let aUnits = Array(text.utf16)
            let mapping = Aligner.align(aUnits, bUnits)
            let chars: [Box?] = mapping.map { j in j.flatMap { bRects[$0] } }

            lines.append(OCRLine(text: text, box: lineBox, confidence: cand.confidence, words: words, chars: chars))
        }
        return OCRResult(width: image.width, height: image.height, lines: LineLayout.readingOrder(lines))
    }

    static func isSpace(_ u: unichar) -> Bool { u == 0x20 || u == 0x09 }
}
