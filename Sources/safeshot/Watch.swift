import Foundation
import SafeshotCore

/// `safeshot watch <dir>`: poll the folder once a second and process new images (e.g. macOS screenshots
/// landing on the Desktop) into an output folder. Polling keeps this dependency-free and robust on
/// network/iCloud folders; files are only processed once their size has been stable for one interval.
func cmdWatch(_ ctx: Context) throws -> Int32 {
    guard let dirArg = ctx.opts.positional.first else { throw UsageError("usage: safeshot watch <dir> [--out <dir>] [--once]") }
    let dir = URL(fileURLWithPath: (dirArg as NSString).expandingTildeInPath).standardizedFileURL
    let outArg = ctx.opts.outDir ?? ctx.config.defaults.watchOutput ?? "~/Desktop/safeshot"
    let outDir = URL(fileURLWithPath: (outArg as NSString).expandingTildeInPath).standardizedFileURL
    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

    let exts: Set<String> = ["png", "jpg", "jpeg", "tiff", "tif", "heic"]
    func listing() -> [URL: Int] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])) ?? []
        var out: [URL: Int] = [:]
        for u in urls where exts.contains(u.pathExtension.lowercased()) && !u.lastPathComponent.contains(".safeshot") {
            if u.deletingLastPathComponent().standardizedFileURL == outDir { continue }
            out[u.standardizedFileURL] = (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        return out
    }

    func process(_ url: URL) {
        let out = outDir.appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".png")
        do {
            let loaded = try ImageFile.load(url)
            let (img, report) = try ctx.run(loaded, inputName: url.path, outputName: out.path)
            try ImageFile.write(img, scale: ctx.opts.scale ?? loaded.scale, to: out)
            if ctx.opts.copy { try Clipboard.write(img, scale: ctx.opts.scale ?? loaded.scale) }
            try ctx.emit(report)
        } catch {
            eprint("safeshot: \(url.lastPathComponent): \(error)")
        }
    }

    if ctx.opts.once {
        for url in listing().keys.sorted(by: { $0.path < $1.path }) { process(url) }
        return 0
    }

    var seen = listing()          // existing files are ignored
    var pending: [URL: Int] = [:] // new files waiting for their size to settle
    if !ctx.opts.quiet { eprint("safeshot: watching \(dir.path) -> \(outDir.path) (Ctrl-C to stop)") }
    setvbuf(stdout, nil, _IOLBF, 0)
    while true {
        Thread.sleep(forTimeInterval: 1)
        let now = listing()
        for (url, size) in now where seen[url] == nil {
            if let prev = pending[url], prev == size, size > 0 {
                pending[url] = nil
                seen[url] = size
                process(url)
            } else {
                pending[url] = size
            }
        }
        for url in seen.keys where now[url] == nil { seen[url] = nil }
    }
}
