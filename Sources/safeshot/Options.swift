import Foundation
import SafeshotCore

struct UsageError: Error, CustomStringConvertible {
    var description: String
    init(_ s: String) { description = s }
}

enum ReportFormat: String { case text, json }

/// Raw command-line flags. `nil` means "not given" so config-file defaults can fill in.
struct CLIOptions {
    var command = "process"
    var positional: [String] = []
    var output: String?
    var outDir: String?
    var clipboard = false
    var copy = false
    var redact: String?
    var dryRun = false
    var report: ReportFormat?
    var reportFile: String?
    var configPath: String?
    var style: String?
    var padding: Double?
    var radius: Double?
    var shadow: String?
    var frame: String?
    var title: String?
    var size: String?
    var balance: Bool?
    var scale: Double?
    var disable: Set<String> = []
    var enable: Set<String> = []
    var quiet = false
    var failOnFindings = false
    var once = false
    var chars = false
    var force = false

    static func parse(_ argv: [String]) throws -> CLIOptions {
        var o = CLIOptions()
        var args = argv[...]
        if let first = args.first, ["watch", "ocr", "rules", "config", "review", "menubar", "help", "version"].contains(first) {
            o.command = first
            args = args.dropFirst()
        }
        func value(_ flag: String) throws -> String {
            guard let v = args.popFirst() else { throw UsageError("\(flag) needs a value") }
            return v
        }
        func number(_ flag: String) throws -> Double {
            let v = try value(flag)
            guard let d = Double(v), d >= 0 else { throw UsageError("\(flag) expects a non-negative number, got '\(v)'") }
            return d
        }
        while let a = args.popFirst() {
            var arg = a
            // Support --flag=value.
            if arg.hasPrefix("--"), let eq = arg.firstIndex(of: "=") {
                args.insert(contentsOf: [String(arg[arg.index(after: eq)...])], at: args.startIndex)
                arg = String(arg[..<eq])
            }
            switch arg {
            case "-h", "--help": o.command = "help"
            case "-V", "--version": o.command = "version"
            case "-o", "--output": o.output = try value(arg)
            case "--out", "--out-dir": o.outDir = try value(arg)
            case "-c", "--clipboard": o.clipboard = true
            case "--copy": o.copy = true
            case "-r", "--redact": o.redact = try value(arg)
            case "-n", "--dry-run": o.dryRun = true
            case "--report":
                if let next = args.first, let f = ReportFormat(rawValue: next) { o.report = f; args.removeFirst() } else { o.report = .text }
            case "--json": o.report = .json
            case "--report-file": o.reportFile = try value(arg)
            case "--config": o.configPath = try value(arg)
            case "-s", "--style", "--background", "--bg": o.style = try value(arg)
            case "--no-style", "--no-beautify", "--raw": o.style = "none"
            case "-p", "--padding": o.padding = try number(arg)
            case "--radius": o.radius = try number(arg)
            case "--shadow": o.shadow = try value(arg)
            case "--frame": o.frame = try value(arg)
            case "--title": o.title = try value(arg)
            case "--size": o.size = try value(arg)
            case "--balance": o.balance = true
            case "--no-balance": o.balance = false
            case "--scale": o.scale = try number(arg)
            case "--disable": o.disable.formUnion(try value(arg).split(separator: ",").map(String.init))
            case "--enable": o.enable.formUnion(try value(arg).split(separator: ",").map(String.init))
            case "-q", "--quiet": o.quiet = true
            case "--fail-on-findings": o.failOnFindings = true
            case "--once": o.once = true
            case "--chars": o.chars = true
            case "--force": o.force = true
            default:
                if arg.hasPrefix("-") && arg != "-" { throw UsageError("unknown option \(arg)") }
                o.positional.append(arg)
            }
        }
        return o
    }

    /// Resolve flags + config defaults into render options.
    func renderOptions(config: Config) throws -> RenderOptions {
        let d = config.defaults
        var r = RenderOptions()
        let redactName = redact ?? d.redact ?? "pixelate"
        guard let style = RedactionStyle(rawValue: redactName) else {
            throw UsageError("--redact must be one of: \(RedactionStyle.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        r.redaction = style
        r.dryRun = dryRun

        let styleName = self.style ?? d.style ?? "ocean"
        if styleName == "none" || styleName == "off" {
            r.beautify = nil
            return r
        }
        var b = BeautifyOptions()
        guard let bg = Background.parse(styleName) else {
            throw UsageError("unknown --style '\(styleName)'. Use a preset (\(GradientPreset.allCases.map(\.rawValue).joined(separator: ", "))), #hex, transparent, image:<path> or none")
        }
        b.background = bg
        b.padding = padding ?? d.padding ?? 64
        b.cornerRadius = radius ?? d.radius ?? 12
        let shadowName = shadow ?? d.shadow ?? "soft"
        guard let sh = ShadowStyle(rawValue: shadowName) else { throw UsageError("--shadow must be none, soft or strong") }
        b.shadow = sh
        let frameName = frame ?? d.frame ?? "none"
        guard let fr = WindowFrame(rawValue: frameName) else { throw UsageError("--frame must be none, macos, macos-light or macos-dark") }
        b.frame = fr
        b.title = title
        let sizeName = size ?? d.size ?? "original"
        guard let sz = SizePreset.parse(sizeName) else { throw UsageError("--size must be original, 16:9 (twitter), square, 4:3, 3:2, 4:5 or W:H") }
        b.size = sz
        b.autoBalance = balance ?? d.balance ?? true
        r.beautify = b
        return r
    }
}

let usageText = """
safeshot \(safeshotVersion) - beautiful screenshots that never leak your secrets. 100% on-device.

USAGE
  safeshot <image> [-o out.png] [options]      redact + beautify an image file
  safeshot --clipboard [options]               process the image on the clipboard, put the result back
  safeshot watch <dir> [--out <dir>] [--once]  auto-process new screenshots appearing in <dir>
  safeshot review <image> | --clipboard        open the review window (toggle each redaction, Copy/Save)
  safeshot menubar                             run as a menu bar item (process/review clipboard)
  safeshot ocr <image> [--chars]               print the OCR result (lines, word and glyph boxes) as JSON
  safeshot rules                               list detection rules and whether they are enabled
  safeshot config init|path|print              create / locate / show the config file

REDACTION
  -r, --redact <pixelate|blur|bar|off>  how to hide findings (default: pixelate). All styles first paint
                                        over the original pixels; nothing of the secret survives.
  -n, --dry-run                         outline findings instead of redacting (writes *.safeshot-preview.png)
      --report [text|json]              print what was found (masked previews + pixel boxes)
      --json                            same as --report json
      --report-file <path>              also write the JSON report to a file
      --disable <id,id>  --enable <id,id>   toggle rules for this run (see `safeshot rules`)
      --fail-on-findings                exit with status 3 if anything was found
      --config <path>                   config file (default: ~/.config/safeshot/config.json)

BEAUTIFY
  -s, --style <name|#hex|transparent|image:path|none>
        presets: ocean (default), sunset, candy, aurora, forest, peach, midnight, graphite, paper, lavender
        `none` = redact only, keep the original framing
  -p, --padding <pt>          padding around the window (default 64)
      --radius <pt>           corner radius (default 12)
      --shadow <none|soft|strong>
      --frame <none|macos|macos-light|macos-dark>   add macOS window chrome
      --title <text>          title shown in the window chrome
      --size <original|16:9|twitter|square|4:3|3:2|4:5|W:H>
      --no-balance            don't even out the screenshot's own margins
      --scale <n>             pixels per point (auto-detected from DPI; Retina = 2)

OUTPUT
  -o, --output <path>         output file (default: <name>.safeshot.png next to the input)
      --out <dir>             output directory (watch mode; default ~/Desktop/safeshot)
      --copy                  also copy the result to the clipboard
  -q, --quiet

EXIT STATUS: 0 ok, 1 error, 2 usage error, 3 findings present (with --fail-on-findings)
"""
