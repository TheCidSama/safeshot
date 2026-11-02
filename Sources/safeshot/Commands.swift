import AppKit
import CoreGraphics
import Foundation
import SafeshotCore

let safeshotVersion = "0.1.0"

func eprint(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

struct Context {
    var opts: CLIOptions
    var config: Config
    var pipeline: Pipeline
    var render: RenderOptions

    init(_ opts: CLIOptions) throws {
        self.opts = opts
        config = try Config.load(path: opts.configPath)
        pipeline = Pipeline(detector: try config.makeDetector(extraDisabled: opts.disable, extraEnabled: opts.enable))
        render = try opts.renderOptions(config: config)
    }

    /// Analyse + render one image. Returns the output image and the report.
    func run(_ loaded: LoadedImage, inputName: String, outputName: String?) throws -> (CGImage, Report) {
        let scale = opts.scale ?? loaded.scale
        let analysis = try pipeline.analyze(loaded.image)
        let out = Pipeline.render(loaded.image, scale: scale, findings: analysis.findings, options: render)
        let report = Report(input: inputName, output: outputName, width: loaded.image.width, height: loaded.image.height,
                            redaction: render.dryRun ? "outline" : render.redaction.rawValue, dryRun: render.dryRun,
                            findings: analysis.findings)
        return (out, report)
    }

    func emit(_ report: Report) throws {
        if let f = opts.reportFile {
            try report.json().write(toFile: (f as NSString).expandingTildeInPath, atomically: true, encoding: .utf8)
        }
        switch opts.report {
        case .json: print(report.json())
        case .text: print(report.text(), terminator: "")
        case nil:
            if !opts.quiet {
                let n = report.findings.count
                let crit = report.findings.filter { $0.severity >= .high }.count
                eprint("safeshot: \(n) finding\(n == 1 ? "" : "s")\(n > 0 ? " (\(crit) high/critical)" : "")\(render.dryRun ? ", outlined" : n > 0 && render.redaction != .off ? ", redacted (\(render.redaction.rawValue))" : "")\(report.output.map { " -> \($0)" } ?? "")")
            }
        }
    }
}

func defaultOutput(for input: String, dryRun: Bool) -> String {
    let url = URL(fileURLWithPath: input)
    let base = url.deletingPathExtension().lastPathComponent
    return url.deletingLastPathComponent().appendingPathComponent(base + (dryRun ? ".safeshot-preview.png" : ".safeshot.png")).path
}

// MARK: - Commands

func cmdProcess(_ ctx: Context) throws -> Int32 {
    if ctx.opts.clipboard { return try cmdClipboard(ctx) }
    guard !ctx.opts.positional.isEmpty else { throw UsageError("no input image (try `safeshot --help`)") }
    if ctx.opts.output != nil && ctx.opts.positional.count > 1 { throw UsageError("-o can only be used with a single input") }
    var anyFindings = false
    for input in ctx.opts.positional {
        let path = (input as NSString).expandingTildeInPath
        let outPath = ctx.opts.output.map { ($0 as NSString).expandingTildeInPath } ?? defaultOutput(for: path, dryRun: ctx.opts.dryRun)
        guard URL(fileURLWithPath: outPath).standardizedFileURL != URL(fileURLWithPath: path).standardizedFileURL else {
            throw UsageError("refusing to overwrite the input image \(path)")
        }
        let loaded = try ImageFile.load(URL(fileURLWithPath: path))
        let (img, report) = try ctx.run(loaded, inputName: input, outputName: outPath)
        try ImageFile.write(img, scale: ctx.opts.scale ?? loaded.scale, to: URL(fileURLWithPath: outPath))
        if ctx.opts.copy { try Clipboard.write(img, scale: ctx.opts.scale ?? loaded.scale) }
        try ctx.emit(report)
        anyFindings = anyFindings || !report.findings.isEmpty
    }
    return ctx.opts.failOnFindings && anyFindings ? 3 : 0
}

func cmdClipboard(_ ctx: Context) throws -> Int32 {
    guard let loaded = Clipboard.read() else { throw UsageError("the clipboard does not contain an image") }
    let (img, report) = try ctx.run(loaded, inputName: "<clipboard>", outputName: ctx.opts.output ?? "<clipboard>")
    let scale = ctx.opts.scale ?? loaded.scale
    if let o = ctx.opts.output {
        try ImageFile.write(img, scale: scale, to: URL(fileURLWithPath: (o as NSString).expandingTildeInPath))
    }
    try Clipboard.write(img, scale: scale)
    try ctx.emit(report)
    return ctx.opts.failOnFindings && !report.findings.isEmpty ? 3 : 0
}

func cmdOCR(_ opts: CLIOptions) throws -> Int32 {
    guard let input = opts.positional.first else { throw UsageError("usage: safeshot ocr <image> [--chars]") }
    let loaded = try ImageFile.load(URL(fileURLWithPath: (input as NSString).expandingTildeInPath))
    var result = try TextRecognizer.recognize(loaded.image)
    if !opts.chars { for i in result.lines.indices { result.lines[i].chars = [] } }
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    print(String(data: try enc.encode(result), encoding: .utf8)!)
    return 0
}

func cmdRules(_ opts: CLIOptions) throws -> Int32 {
    let config = try Config.load(path: opts.configPath)
    let rules = config.effectiveRules(extraDisabled: opts.disable, extraEnabled: opts.enable)
    if opts.report == .json {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        print(String(data: try enc.encode(rules), encoding: .utf8)!)
        return 0
    }
    let w = rules.map(\.id.count).max() ?? 10
    for r in rules {
        print("\(r.enabled ? "on " : "off") \(r.id.padding(toLength: w, withPad: " ", startingAt: 0))  \(r.severity.rawValue.padding(toLength: 8, withPad: " ", startingAt: 0))  \(r.description)")
    }
    return 0
}

func cmdConfig(_ opts: CLIOptions) throws -> Int32 {
    let sub = opts.positional.first ?? "path"
    let path = opts.configPath.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } ?? Config.defaultPath
    switch sub {
    case "path":
        print(path.path)
    case "init":
        if FileManager.default.fileExists(atPath: path.path) && !opts.force {
            throw UsageError("\(path.path) already exists (use --force to overwrite)")
        }
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Config.starterJSON.write(to: path, atomically: true, encoding: .utf8)
        print("wrote \(path.path)")
    case "print":
        if FileManager.default.fileExists(atPath: path.path) {
            print(try String(contentsOf: path, encoding: .utf8))
        } else {
            print(Config.starterJSON)
        }
    default:
        throw UsageError("usage: safeshot config init|path|print")
    }
    return 0
}
