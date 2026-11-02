import CoreGraphics
import Foundation
import Testing
@testable import SafeshotCore
import SafeshotFixtures

/// Render synthetic screenshots with known FAKE secrets, run the whole pipeline (OCR -> detect -> redact ->
/// beautify), then OCR the OUTPUT again and check that
///   1. no secret can be recovered from it, and
///   2. the non-secret text is still readable.
/// Also reports detection recall over every planted secret.
@Suite("End-to-end (Vision OCR)", .serialized)
struct EndToEndTests {
    struct Case: Sendable, CustomStringConvertible {
        let make: @Sendable () -> Scene
        let redaction: RedactionStyle
        let beautify: Bool
        let label: String
        var description: String { label }
    }

    static let cases: [Case] = [
        Case(make: { Scenes.terminal(theme: .dark, font: .menlo, size: 13) }, redaction: .pixelate, beautify: true, label: "terminal menlo 13 dark"),
        Case(make: { Scenes.terminal(theme: .light, font: .sfMono, size: 12) }, redaction: .bar, beautify: false, label: "terminal sf-mono 12 light"),
        Case(make: { Scenes.terminal(theme: .dark, font: .monaco, size: 14, columns: 84) }, redaction: .blur, beautify: true, label: "terminal monaco 14 dark (narrow, wraps)"),
        Case(make: { Scenes.terminal(theme: .light, font: .courier, size: 14) }, redaction: .pixelate, beautify: false, label: "terminal courier 14 light"),
        Case(make: { Scenes.terminal(theme: .dark, font: .sfMono, size: 11, scale: 1) }, redaction: .bar, beautify: false, label: "terminal sf-mono 11 dark @1x"),
        Case(make: { Scenes.editor(theme: .dark, font: .sfMono, size: 13) }, redaction: .pixelate, beautify: true, label: "editor sf-mono 13 dark"),
        Case(make: { Scenes.editor(theme: .light, font: .menlo, size: 12) }, redaction: .blur, beautify: false, label: "editor menlo 12 light"),
        Case(make: { Scenes.dashboard(font: .sfPro) }, redaction: .blur, beautify: true, label: "dashboard sf-pro light"),
        Case(make: { Scenes.dashboard(font: .helvetica, dark: true) }, redaction: .pixelate, beautify: false, label: "dashboard helvetica dark"),
    ]

    /// Distinctive 8-character windows of a secret, excluding windows that also occur in text that is
    /// legitimately visible (e.g. `example.com` in a URL elsewhere in the screenshot).
    static func windows(_ secret: String, publicText: String) -> [String] {
        let sk = Array(OCRNormalizer.skeleton(secret))
        if sk.count < 12 { return [String(sk)] }
        var out: [String] = []
        for i in 0...(sk.count - 8) {
            let w = String(sk[i..<(i + 8)])
            if !publicText.contains(w) { out.append(w) }
        }
        return out
    }

    @Test func secretsAreNotRecoverableAndTextStaysReadable() throws {
        let pipeline = try Pipeline(config: Config())
        var planted = 0, detected = 0, leaked: [String] = [], missed: [String] = []
        var benignTotal = 0, benignReadable = 0
        var table: [String] = []

        for c in Self.cases {
            let scene = c.make()
            let analysis = try pipeline.analyze(scene.image)
            var opts = RenderOptions()
            opts.redaction = c.redaction
            opts.beautify = c.beautify ? BeautifyOptions() : nil
            let out = Pipeline.render(scene.image, scale: scene.scale, findings: analysis.findings, options: opts)
            let after = try TextRecognizer.recognize(out)

            let inputSkeleton = OCRNormalizer.skeleton(analysis.ocr.fullText)
            var publicText = inputSkeleton
            for s in scene.secrets { publicText = publicText.replacingOccurrences(of: OCRNormalizer.skeleton(s), with: "#") }
            let outputSkeleton = OCRNormalizer.skeleton((after.lines + after.alternates).map(\.text).joined(separator: "\n"))
            let foundSkeletons = analysis.documentFindings.map { OCRNormalizer.skeleton($0.text) }

            var sceneDetected = 0
            for s in scene.secrets {
                planted += 1
                let ws = Self.windows(s, publicText: publicText)
                // Detected: some finding shares a distinctive window with the secret.
                if ws.contains(where: { w in foundSkeletons.contains { $0.contains(w) || w.contains($0) && $0.count >= 6 } }) {
                    detected += 1; sceneDetected += 1
                } else {
                    missed.append("\(c.label): \(Mask.preview(s))")
                }
                if let w = ws.first(where: { outputSkeleton.contains($0) }) {
                    leaked.append("\(c.label): \(Mask.preview(s)) (window '\(w)')")
                }
            }
            var sceneBenign = 0
            for b in scene.benign {
                benignTotal += 1
                if outputSkeleton.contains(OCRNormalizer.skeleton(b)) { benignReadable += 1; sceneBenign += 1 }
            }
            table.append(String(format: "  %-42@ secrets %2d/%2d detected, benign text %2d/%2d readable after redaction",
                                c.label as NSString, sceneDetected, scene.secrets.count, sceneBenign, scene.benign.count))
        }

        let recall = Double(detected) / Double(planted)
        print("safeshot end-to-end:\n" + table.joined(separator: "\n"))
        print(String(format: "safeshot end-to-end: recall %d/%d = %.1f%%, leaks %d, benign readable %d/%d = %.1f%%",
                     detected, planted, recall * 100, leaked.count, benignReadable, benignTotal,
                     Double(benignReadable) / Double(benignTotal) * 100))
        if !missed.isEmpty { print("safeshot end-to-end: not detected (but checked for leaks above): \(missed)") }
        #expect(leaked.isEmpty, "recoverable secrets: \(leaked)")
        #expect(recall >= 0.97)
        #expect(Double(benignReadable) / Double(benignTotal) >= 0.9)
    }
}
