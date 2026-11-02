import Foundation

/// One line of recognised text, in reading order.
public struct ScanLine: Sendable, Hashable {
    public var text: String
    /// True when the line runs to the right edge of the text block and the next line looks like its
    /// continuation (soft wrap). Computed from geometry by `LineLayout`.
    public var wrapsToNext: Bool

    public init(_ text: String, wrapsToNext: Bool = false) {
        self.text = text
        self.wrapsToNext = wrapsToNext
    }
}

/// A UTF-16 range inside one line.
public struct Segment: Codable, Sendable, Hashable {
    public var line: Int
    public var location: Int
    public var length: Int

    public init(line: Int, location: Int, length: Int) {
        self.line = line
        self.location = location
        self.length = length
    }

    public var range: NSRange { NSRange(location: location, length: length) }
    var end: Int { location + length }
}

/// A detection over a whole document (possibly spanning wrapped lines), before geometry is attached.
public struct DocumentFinding: Sendable, Hashable {
    public var ruleID: String
    public var segments: [Segment]
    /// Normalised matched text (for masking and tests). Never written to reports unmasked.
    public var text: String
    /// Other rules that hit the same text (e.g. `secret-assignment` + `anthropic-api-key`).
    public var alsoMatched: [String]
}

public struct DocumentScanner: Sendable {
    public let detector: Detector

    public init(detector: Detector) { self.detector = detector }

    public func scan(_ lines: [ScanLine]) -> [DocumentFinding] {
        var raw: [DocumentFinding] = []
        let texts = lines.map { OCRNormalizer.normalize($0.text) }

        // 1. Each line on its own (previous line is keyword context).
        for (i, t) in texts.enumerated() {
            let ctx = i > 0 ? texts[i - 1] : ""
            for m in detector.scan(t, context: ctx) {
                if let rule = detector.rule(id: m.ruleID), rule.privateKeyBlock {
                    raw.append(privateKeyFinding(header: m, line: i, texts: texts))
                } else {
                    raw.append(DocumentFinding(ruleID: m.ruleID, segments: [Segment(line: i, location: m.range.location, length: m.range.length)], text: m.text, alsoMatched: []))
                }
            }
        }

        // 2. Soft-wrapped lines: scan the concatenation, keep only matches that cross a line boundary.
        var i = 0
        while i < lines.count {
            guard lines[i].wrapsToNext, i + 1 < lines.count else { i += 1; continue }
            var chain = [i]
            var k = i
            while lines[k].wrapsToNext, k + 1 < lines.count, chain.count < 6 {
                k += 1
                chain.append(k)
            }
            var joined = ""
            var starts: [Int] = []
            for idx in chain {
                starts.append((joined as NSString).length)
                joined += texts[idx]
            }
            let ctx = i > 0 ? texts[i - 1] : ""
            for m in detector.scan(joined, context: ctx, ruleFilter: { $0.allowWrap && !$0.privateKeyBlock }) {
                let mStart = m.range.location, mEnd = m.range.location + m.range.length
                var segs: [Segment] = []
                for (n, idx) in chain.enumerated() {
                    let ls = starts[n], le = ls + (texts[idx] as NSString).length
                    let s = max(ls, mStart), e = min(le, mEnd)
                    if e > s { segs.append(Segment(line: idx, location: s - ls, length: e - s)) }
                }
                if segs.count > 1 {
                    raw.append(DocumentFinding(ruleID: m.ruleID, segments: segs, text: m.text, alsoMatched: []))
                }
            }
            i = k
        }

        // A header seen without its body (e.g. an alternate OCR reading of the header row) is only worth
        // reporting when no reading found the body itself.
        if raw.contains(where: { $0.ruleID == "private-key" && $0.text != DocumentScanner.headerOnlyText }) {
            raw.removeAll { $0.text == DocumentScanner.headerOnlyText }
        }
        return cluster(raw)
    }

    static let headerOnlyText = "PRIVATE KEY (header only)"

    func privateKeyFinding(header m: TextMatch, line i: Int, texts: [String]) -> DocumentFinding {
        var segs: [Segment] = []
        let headerText = texts[i] as NSString
        // `groups: [1, 0]`: group 1 is whatever follows the header on the same line.
        let rest = m.text.trimmingCharacters(in: .whitespaces)
        let isHeaderItself = rest.uppercased().contains("PRIVATE")
        if !isHeaderItself, rest.count >= 4 {
            segs.append(Segment(line: i, location: m.range.location, length: m.range.length))
        }
        var j = i + 1
        while j < texts.count, j - i <= 120 {
            let t = texts[j].trimmingCharacters(in: .whitespaces)
            let up = t.uppercased()
            if up.contains("END") && up.contains("PRIVATE") { break }
            // Editor gutters: line numbers are separate OCR lines interleaved with the key body.
            if t.count <= 5 && !t.isEmpty && t.allSatisfy(\.isNumber) { j += 1; continue }
            guard DocumentScanner.looksLikeKeyBody(t) else { break }
            let full = texts[j] as NSString
            let lead = full.length - (full as String).drop(while: { $0 == " " }).utf16.count
            segs.append(Segment(line: j, location: lead, length: (t as NSString).length))
            j += 1
        }
        let headerOnly = segs.isEmpty
        if segs.isEmpty {
            // Header without a visible body: flag the header so the user sees it in the report.
            let r = (headerText as String).range(of: "PRIVATE").map { NSRange($0, in: headerText as String) } ?? m.range
            segs.append(Segment(line: i, location: r.location, length: r.length))
        }
        if headerOnly { return DocumentFinding(ruleID: m.ruleID, segments: segs, text: DocumentScanner.headerOnlyText, alsoMatched: []) }
        let body = segs.map { (texts[$0.line] as NSString).substring(with: $0.range) }.joined(separator: "\n")
        return DocumentFinding(ruleID: m.ruleID, segments: segs, text: body, alsoMatched: [])
    }

    static func looksLikeKeyBody(_ t: String) -> Bool {
        guard t.count >= 16 else { return false }
        let b64 = t.filter { $0.isLetter || $0.isNumber || $0 == "+" || $0 == "/" || $0 == "=" }.count
        return Double(b64) / Double(t.count) >= 0.95 && !t.contains(" ")
    }

    /// Merge findings that overlap on the same line. The most specific rule names the merged finding;
    /// the redacted area is the union of everything that matched.
    func cluster(_ raw: [DocumentFinding]) -> [DocumentFinding] {
        guard !raw.isEmpty else { return [] }
        var parent = Array(raw.indices)
        func find(_ x: Int) -> Int {
            var x = x
            while parent[x] != x { parent[x] = parent[parent[x]]; x = parent[x] }
            return x
        }
        for a in raw.indices {
            for b in (a + 1)..<raw.count where overlaps(raw[a], raw[b]) {
                parent[find(a)] = find(b)
            }
        }
        var groups: [Int: [Int]] = [:]
        for i in raw.indices { groups[find(i), default: []].append(i) }

        var out: [DocumentFinding] = []
        for members in groups.values {
            let ranked = members.sorted { x, y in
                let rx = detector.rule(id: raw[x].ruleID), ry = detector.rule(id: raw[y].ruleID)
                if (rx?.specificity ?? 0) != (ry?.specificity ?? 0) { return (rx?.specificity ?? 0) > (ry?.specificity ?? 0) }
                return (rx?.severity ?? .low) > (ry?.severity ?? .low)
            }
            let best = raw[ranked[0]]
            var byLine: [Int: [Segment]] = [:]
            for m in members { for s in raw[m].segments { byLine[s.line, default: []].append(s) } }
            var segs: [Segment] = []
            for (line, ss) in byLine {
                let sorted = ss.sorted { $0.location < $1.location }
                var cur = sorted[0]
                for s in sorted.dropFirst() {
                    if s.location <= cur.end {
                        cur.length = max(cur.end, s.end) - cur.location
                    } else {
                        segs.append(cur); cur = s
                    }
                }
                segs.append(cur)
                _ = line
            }
            segs.sort { ($0.line, $0.location) < ($1.line, $1.location) }
            let others = Array(Set(members.map { raw[$0].ruleID }).subtracting([best.ruleID])).sorted()
            out.append(DocumentFinding(ruleID: best.ruleID, segments: segs, text: best.text, alsoMatched: others))
        }
        out.sort { a, b in
            let sa = a.segments[0], sb = b.segments[0]
            return (sa.line, sa.location) < (sb.line, sb.location)
        }
        return out
    }

    func overlaps(_ a: DocumentFinding, _ b: DocumentFinding) -> Bool {
        for x in a.segments {
            for y in b.segments where x.line == y.line {
                if x.location < y.end && y.location < x.end { return true }
            }
        }
        return false
    }
}

public enum Mask {
    /// `sk-ant-api03-FAKE…a1F` -> `sk-ant-…a1F`. Short values reveal at most their first character.
    public static func preview(_ s: String) -> String {
        let chars = Array(s)
        let n = chars.count
        if n <= 4 { return String(repeating: "•", count: max(n, 1)) }
        if n < 12 { return String(chars[0]) + "…" }
        if let at = chars.firstIndex(of: "@"), at > 0 { // email: keep first char and the TLD
            let tld = s.split(separator: ".").last.map(String.init) ?? ""
            return String(chars[0]) + "…@….\(tld)"
        }
        // Keep a recognisable prefix (up to and including the 2nd separator, max 7 chars) and 3 trailing chars.
        var prefixLen = min(4, n / 4)
        var seps = 0
        for (i, c) in chars.prefix(8).enumerated() where c == "-" || c == "_" || c == "." {
            seps += 1
            prefixLen = i + 1
            if seps == 2 { break }
        }
        prefixLen = min(prefixLen, 7, n / 3)
        return String(chars.prefix(prefixLen)) + "…" + String(chars.suffix(3))
    }
}
