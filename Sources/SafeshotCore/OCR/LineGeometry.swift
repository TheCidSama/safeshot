import CoreGraphics
import Foundation

/// Turning "UTF-16 range in a recognised line" into "pixels to cover".
///
/// Vision's accurate recogniser (the one that gets the text right) only reports **word**-level boxes, even
/// for single-character ranges. Its fast recogniser reports real per-glyph boxes but gets more characters
/// wrong. `TextRecognizer` aligns the two transcriptions and stores the fast glyph boxes in `OCRLine.chars`;
/// this file uses them, falling back to proportional interpolation inside the accurate word box.
///
/// Safety rules (we would rather cover a few extra pixels than leak a glyph):
/// * a range that starts/ends at a word boundary always extends to the accurate word box edge
/// * glyph boxes that fall outside their word box are ignored
/// * when fewer than 80% of the characters have glyph boxes the interpolated estimate is unioned in
public extension OCRLine {
    var averageCharWidth: Double {
        let n = max(1, (text as NSString).length)
        return box.width / Double(n)
    }

    func rect(for range: NSRange) -> CGRect {
        let lineRect = box.rect
        let ns = text as NSString
        let lo = max(0, range.location), hi = min(ns.length, range.location + range.length)
        guard hi > lo else { return .null }

        var cw = averageCharWidth
        let glyphWidths = chars.compactMap { $0?.width }.filter { $0 > 0 }.sorted()
        if !glyphWidths.isEmpty { cw = max(cw * 0.5, glyphWidths[glyphWidths.count / 2]) }

        var x0 = Double.infinity, x1 = -Double.infinity
        var y0 = lineRect.minY, y1 = lineRect.maxY
        var mappedCount = 0, wordChars = 0
        var interp0 = Double.infinity, interp1 = -Double.infinity

        for w in words {
            let ws = w.location, we = w.location + w.length
            let s = max(ws, lo), e = min(we, hi)
            guard e > s else { continue }
            let wr = w.box.rect
            let per = wr.width / Double(max(1, w.length))
            // Interpolated estimate for this slice of the word.
            let ia = wr.minX + Double(s - ws) * per
            let ib = wr.minX + Double(e - ws) * per
            interp0 = min(interp0, ia); interp1 = max(interp1, ib)

            for i in s..<e {
                wordChars += 1
                if i < chars.count, let g = chars[i] {
                    let gr = g.rect
                    if gr.minX >= wr.minX - cw && gr.maxX <= wr.maxX + cw && gr.width > 0 {
                        mappedCount += 1
                        x0 = min(x0, gr.minX); x1 = max(x1, gr.maxX)
                        y0 = min(y0, gr.minY); y1 = max(y1, gr.maxY)
                        continue
                    }
                }
                let a = wr.minX + Double(i - ws) * per
                x0 = min(x0, a); x1 = max(x1, a + per)
            }
            // Word edges are reliable; mid-word edges rely on glyph boxes + the interpolated estimate below.
            if s == ws { x0 = min(x0, wr.minX) }
            if e == we { x1 = max(x1, wr.maxX) }
            y0 = min(y0, wr.minY); y1 = max(y1, wr.maxY)
        }

        if wordChars == 0 {
            // No word boxes (e.g. hand-built lines in tests): interpolate across the line.
            let per = lineRect.width / Double(max(1, ns.length))
            x0 = lineRect.minX + Double(lo) * per
            x1 = lineRect.minX + Double(hi) * per
        } else {
            // Glyph boxes come from a second, less accurate transcription; if one is misaligned it
            // could shrink the box. The proportional estimate is unioned in so a single bad glyph
            // never uncovers part of a secret (costs at most a sliver of over-redaction).
            _ = mappedCount
            x0 = min(x0, interp0); x1 = max(x1, interp1)
        }
        guard x1 > x0 else { return .null }
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
}

/// Line-level layout heuristics.
public enum LineLayout {
    /// Sort Vision observations into reading order: top-to-bottom rows, left-to-right inside a row.
    public static func readingOrder(_ lines: [OCRLine]) -> [OCRLine] {
        let sorted = lines.sorted { $0.box.y < $1.box.y }
        var rows: [[OCRLine]] = []
        for l in sorted {
            if var last = rows.last, let ref = last.first {
                let c1 = ref.box.y + ref.box.height / 2, c2 = l.box.y + l.box.height / 2
                if abs(c1 - c2) < min(ref.box.height, l.box.height) * 0.5 {
                    last.append(l)
                    rows[rows.count - 1] = last
                    continue
                }
            }
            rows.append([l])
        }
        return rows.flatMap { $0.sorted { $0.box.x < $1.box.x } }
    }

    /// Decide which lines are soft-wrapped into the following line.
    ///
    /// A line wraps when it ends at the right edge of the text area — either within ~4 characters of the
    /// image edge, or at a right margin shared with at least one other line — doesn't end in a space, and
    /// the next row starts at the left margin directly below it with a similar text height.
    public static func wrapFlags(_ lines: [OCRLine], imageWidth: Double) -> [Bool] {
        guard lines.count > 1 else { return Array(repeating: false, count: lines.count) }
        let rightEdge = lines.map { $0.box.x + $0.box.width }.max() ?? 0
        let leftEdge = lines.map(\.box.x).min() ?? 0
        var flags = Array(repeating: false, count: lines.count)
        for i in 0..<(lines.count - 1) {
            let a = lines[i], b = lines[i + 1]
            let cw = max(1, a.averageCharWidth)
            let aMax = a.box.x + a.box.width
            let atImageEdge = aMax >= imageWidth - max(4 * cw, imageWidth * 0.015)
            let sharedMargin = rightEdge > imageWidth * 0.5
                && aMax >= rightEdge - 1.5 * cw
                && lines.enumerated().contains { j, l in j != i && l.box.x + l.box.width >= rightEdge - 1.5 * cw && abs(l.box.height - a.box.height) < a.box.height * 0.3 }
            guard atImageEdge || sharedMargin else { continue }
            guard !a.text.hasSuffix(" "), let last = a.text.last, !last.isWhitespace else { continue }
            let gap = b.box.y - (a.box.y + a.box.height)
            guard gap > -a.box.height * 0.5, gap < a.box.height * 1.0 else { continue }
            guard abs(b.box.height - a.box.height) < a.box.height * 0.35 else { continue }
            guard b.box.x <= leftEdge + 2.5 * cw || abs(b.box.x - a.box.x) <= 2.5 * cw else { continue }
            flags[i] = true
        }
        return flags
    }
}

/// Semi-global alignment of two transcriptions of the same line (accurate vs fast OCR).
public enum Aligner {
    /// Returns, for each unit of `a`, the index in `b` it aligns to (or nil).
    /// `b` may contain extra text before/after (free end gaps).
    public static func align(_ a: [UInt16], _ b: [UInt16]) -> [Int?] {
        let n = a.count, m = b.count
        guard n > 0, m > 0 else { return Array(repeating: nil, count: n) }
        let ka = a.map(OCRNormalizer.confusableKey), kb = b.map(OCRNormalizer.confusableKey)
        let w = m + 1
        var d = [Float](repeating: 0, count: (n + 1) * w)
        var back = [UInt8](repeating: 0, count: (n + 1) * w) // 0 diag, 1 up (gap in b), 2 left (gap in a)
        for i in 1...n { d[i * w] = Float(i); back[i * w] = 1 }
        for j in 0...m { d[j] = 0; back[j] = 2 } // free leading gaps in b
        for i in 1...n {
            for j in 1...m {
                let sub: Float
                if a[i - 1] == b[j - 1] { sub = 0 }
                else if ka[i - 1] == kb[j - 1] { sub = 0.25 }
                else if a[i - 1] == 0x20 || b[j - 1] == 0x20 { sub = 1.6 }
                else { sub = 1 }
                let diag = d[(i - 1) * w + j - 1] + sub
                let up = d[(i - 1) * w + j] + 1
                let left = d[i * w + j - 1] + (b[j - 1] == 0x20 ? 0.6 : 1)
                if diag <= up && diag <= left { d[i * w + j] = diag; back[i * w + j] = 0 }
                else if up <= left { d[i * w + j] = up; back[i * w + j] = 1 }
                else { d[i * w + j] = left; back[i * w + j] = 2 }
            }
        }
        var bestJ = 0
        var best = Float.infinity
        for j in 0...m where d[n * w + j] < best { best = d[n * w + j]; bestJ = j } // free trailing gaps
        var out = [Int?](repeating: nil, count: n)
        var i = n, j = bestJ
        while i > 0 {
            switch back[i * w + j] {
            case 0:
                if a[i - 1] != 0x20 && b[j - 1] != 0x20 { out[i - 1] = j - 1 }
                i -= 1; j -= 1
            case 1:
                i -= 1
            default:
                if j == 0 { i -= 1 } else { j -= 1 }
            }
        }
        return out
    }
}
