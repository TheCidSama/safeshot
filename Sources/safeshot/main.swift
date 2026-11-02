import Foundation
import SafeshotCore

do {
    let opts = try CLIOptions.parse(Array(CommandLine.arguments.dropFirst()))
    let status: Int32
    switch opts.command {
    case "help": print(usageText); status = 0
    case "version": print("safeshot \(safeshotVersion)"); status = 0
    case "ocr": status = try cmdOCR(opts)
    case "rules": status = try cmdRules(opts)
    case "config": status = try cmdConfig(opts)
    case "watch": status = try cmdWatch(try Context(opts))
    case "review": status = try cmdReview(try Context(opts))
    case "menubar": status = try cmdMenuBar(try Context(opts))
    default:
        if opts.positional.isEmpty && !opts.clipboard { print(usageText); status = 2 } else { status = try cmdProcess(try Context(opts)) }
    }
    exit(status)
} catch let e as UsageError {
    eprint("safeshot: \(e.description)")
    exit(2)
} catch {
    eprint("safeshot: \(error)")
    exit(1)
}
