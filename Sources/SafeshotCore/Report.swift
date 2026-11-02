import Foundation

public struct Report: Codable, Sendable {
    public var input: String
    public var output: String?
    public var width: Int
    public var height: Int
    public var redaction: String
    public var dryRun: Bool
    public var findings: [Finding]
    public var summary: [String: Int]

    public init(input: String, output: String?, width: Int, height: Int, redaction: String, dryRun: Bool, findings: [Finding]) {
        self.input = input
        self.output = output
        self.width = width
        self.height = height
        self.redaction = redaction
        self.dryRun = dryRun
        self.findings = findings
        var s: [String: Int] = ["total": findings.count]
        for f in findings { s[f.severity.rawValue, default: 0] += 1 }
        summary = s
    }

    public func json() -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? String(data: enc.encode(self), encoding: .utf8)) ?? "{}"
    }

    public func text() -> String {
        var out = "\(input): \(findings.count) finding\(findings.count == 1 ? "" : "s")"
        if let output { out += " -> \(output)\(dryRun ? " (dry run: outlined, not redacted)" : "")" }
        out += "\n"
        if findings.isEmpty { return out }
        let ruleW = min(28, findings.map(\.rule.count).max() ?? 4)
        for f in findings {
            let b = f.boxes.first.map { "x=\(Int($0.x)) y=\(Int($0.y)) \(Int($0.width))x\(Int($0.height))" } ?? "-"
            let more = f.boxes.count > 1 ? " (+\(f.boxes.count - 1) box\(f.boxes.count > 2 ? "es" : ""))" : ""
            out += "  \(f.id.padding(toLength: 4, withPad: " ", startingAt: 0)) \(f.severity.rawValue.padding(toLength: 8, withPad: " ", startingAt: 0)) \(f.rule.padding(toLength: ruleW, withPad: " ", startingAt: 0))  \(f.preview.padding(toLength: 18, withPad: " ", startingAt: 0))  \(b)\(more)\n"
        }
        return out
    }
}
