import AppKit
import SafeshotCore
import SwiftUI

// MARK: - Review window

@MainActor
final class ReviewModel: ObservableObject {
    let source: LoadedImage
    let sourceName: String
    @Published var findings: [Finding]
    @Published var redaction: RedactionStyle { didSet { rerender() } }
    @Published var styleName: String { didSet { rerender() } }
    @Published var frame: WindowFrame { didSet { rerender() } }
    @Published var size: String { didSet { rerender() } }
    @Published var preview: NSImage
    @Published var status = ""
    var base: BeautifyOptions

    init(source: LoadedImage, name: String, findings: [Finding], render: RenderOptions) {
        self.source = source
        sourceName = name
        self.findings = findings
        redaction = render.redaction == .off ? .pixelate : render.redaction
        base = render.beautify ?? BeautifyOptions()
        if render.beautify == nil {
            styleName = "none"
        } else if case let .gradient(p) = base.background {
            styleName = p.rawValue
        } else {
            styleName = "ocean"
        }
        frame = base.frame
        size = "original"
        preview = NSImage(size: NSSize(width: 1, height: 1))
        rerender()
    }

    func toggle(_ id: String) {
        guard let i = findings.firstIndex(where: { $0.id == id }) else { return }
        findings[i].enabled.toggle()
        rerender()
    }

    var output: CGImage {
        var o = RenderOptions()
        o.redaction = redaction
        if styleName == "none" {
            o.beautify = nil
        } else {
            var b = base
            b.background = Background.parse(styleName) ?? .gradient(.ocean)
            b.frame = frame
            b.size = SizePreset.parse(size) ?? .original
            o.beautify = b
        }
        return Pipeline.render(source.image, scale: source.scale, findings: findings, options: o)
    }

    func rerender() {
        let img = output
        preview = NSImage(cgImage: img, size: NSSize(width: Double(img.width) / source.scale, height: Double(img.height) / source.scale))
    }

    func copy() {
        do {
            try Clipboard.write(output, scale: source.scale)
            status = "Copied to clipboard"
        } catch { status = "Copy failed: \(error)" }
    }

    func save() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = (sourceName as NSString).deletingPathExtension.components(separatedBy: "/").last.map { $0 + ".safeshot.png" } ?? "safeshot.png"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try ImageFile.write(output, scale: source.scale, to: url)
                status = "Saved \(url.lastPathComponent)"
            } catch { status = "Save failed: \(error)" }
        }
    }
}

struct ReviewView: View {
    @ObservedObject var model: ReviewModel
    var onDone: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            ZStack {
                Color(nsColor: .underPageBackgroundColor)
                Image(nsImage: model.preview)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .padding(20)
            }
            .frame(minWidth: 520, minHeight: 380)

            Divider()

            VStack(alignment: .leading, spacing: 14) {
                Text("Findings (\(model.findings.filter(\.enabled).count)/\(model.findings.count) redacted)")
                    .font(.headline)
                List {
                    ForEach(model.findings) { f in
                        Toggle(isOn: Binding(get: { f.enabled }, set: { _ in model.toggle(f.id) })) {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Circle().fill(color(f.severity)).frame(width: 8, height: 8)
                                    Text(f.rule).font(.system(.body, design: .monospaced))
                                }
                                Text(f.preview).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .frame(minHeight: 180)

                Picker("Redaction", selection: $model.redaction) {
                    ForEach([RedactionStyle.pixelate, .blur, .bar], id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
                Picker("Background", selection: $model.styleName) {
                    Text("None (redact only)").tag("none")
                    ForEach(GradientPreset.allCases, id: \.rawValue) { Text($0.rawValue.capitalized).tag($0.rawValue) }
                    Text("Transparent").tag("transparent")
                }
                Picker("Window", selection: $model.frame) {
                    Text("No chrome").tag(WindowFrame.none)
                    Text("macOS (auto)").tag(WindowFrame.macos)
                    Text("macOS light").tag(WindowFrame.macosLight)
                    Text("macOS dark").tag(WindowFrame.macosDark)
                }
                Picker("Size", selection: $model.size) {
                    Text("Original").tag("original")
                    Text("16:9 (X/Twitter)").tag("16:9")
                    Text("Square").tag("square")
                    Text("4:3").tag("4:3")
                }

                Spacer()
                Text(model.status).font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Save…") { model.save() }
                    Spacer()
                    Button("Done") { onDone() }
                    Button("Copy") { model.copy() }.keyboardShortcut("c", modifiers: .command).buttonStyle(.borderedProminent)
                }
            }
            .padding(16)
            .frame(width: 320)
        }
    }

    func color(_ s: Severity) -> Color {
        switch s {
        case .critical: .red
        case .high: .orange
        case .medium: .yellow
        case .low: .blue
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@MainActor
func openReviewWindow(source: LoadedImage, name: String, ctx: Context, terminateOnClose: Bool) throws {
    let analysis = try ctx.pipeline.analyze(source.image)
    let model = ReviewModel(source: source, name: name, findings: analysis.findings, render: ctx.render)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
    window.title = "safeshot — \(URL(fileURLWithPath: name).lastPathComponent)"
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(rootView: ReviewView(model: model) { [weak window] in
        window?.close()
        if terminateOnClose { NSApp.terminate(nil) }
    })
    window.center()
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    reviewWindows.append(window)
}

@MainActor var reviewWindows: [NSWindow] = []
@MainActor let appDelegate = AppDelegate()

func cmdReview(_ ctx: Context) throws -> Int32 {
    let source: LoadedImage
    let name: String
    if ctx.opts.clipboard {
        guard let l = Clipboard.read() else { throw UsageError("the clipboard does not contain an image") }
        source = l; name = "clipboard"
    } else {
        guard let input = ctx.opts.positional.first else { throw UsageError("usage: safeshot review <image> | --clipboard") }
        source = try ImageFile.load(URL(fileURLWithPath: (input as NSString).expandingTildeInPath))
        name = input
    }
    return try MainActor.assumeIsolated {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.delegate = appDelegate
        try openReviewWindow(source: source, name: name, ctx: ctx, terminateOnClose: true)
        app.run()
        return 0
    }
}

// MARK: - Menu bar item

@MainActor
final class MenuBarController: NSObject {
    let ctx: Context
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

    init(ctx: Context) {
        self.ctx = ctx
        super.init()
        item.button?.image = NSImage(systemSymbolName: "eye.slash", accessibilityDescription: "safeshot")
        let menu = NSMenu()
        menu.addItem(withTitle: "Redact & Beautify Clipboard", action: #selector(processClipboard), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Review Clipboard…", action: #selector(reviewClipboard), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit safeshot", action: #selector(quit), keyEquivalent: "q").target = self
        item.menu = menu
    }

    @objc func processClipboard() {
        guard let loaded = Clipboard.read() else { notify("No image on the clipboard"); return }
        do {
            let (img, report) = try ctx.run(loaded, inputName: "<clipboard>", outputName: "<clipboard>")
            try Clipboard.write(img, scale: ctx.opts.scale ?? loaded.scale)
            notify("Done — \(report.findings.count) finding(s) redacted. Result is on the clipboard.")
        } catch { notify("Failed: \(error)") }
    }

    @objc func reviewClipboard() {
        guard let loaded = Clipboard.read() else { notify("No image on the clipboard"); return }
        do { try openReviewWindow(source: loaded, name: "clipboard", ctx: ctx, terminateOnClose: false) } catch { notify("Failed: \(error)") }
    }

    @objc func quit() { NSApp.terminate(nil) }

    func notify(_ s: String) {
        let alert = NSAlert()
        alert.messageText = "safeshot"
        alert.informativeText = s
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

@MainActor var menuBarController: MenuBarController?

func cmdMenuBar(_ ctx: Context) throws -> Int32 {
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        menuBarController = MenuBarController(ctx: ctx)
        app.run()
    }
    return 0
}
