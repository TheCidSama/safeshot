import AppKit
import CoreGraphics
import Foundation
import SafeshotCore

enum Clipboard {
    /// The image currently on the general pasteboard (PNG, TIFF or anything NSImage understands).
    static func read() -> LoadedImage? {
        let pb = NSPasteboard.general
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            if let data = pb.data(forType: type), var loaded = try? ImageFile.load(data: data) {
                // Screenshots copied with ⌘⇧⌃4 carry 144 dpi; NSImage size tells us the point size otherwise.
                if loaded.scale == 1, let rep = NSBitmapImageRep(data: data), rep.size.width > 0 {
                    loaded.scale = max(1, (Double(rep.pixelsWide) / rep.size.width).rounded())
                }
                return loaded
            }
        }
        if let img = NSImage(pasteboard: pb), let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            let scale = img.size.width > 0 ? max(1, (Double(cg.width) / img.size.width).rounded()) : 1
            return LoadedImage(image: cg, scale: scale)
        }
        return nil
    }

    /// Replace the clipboard with the image as PNG (+ TIFF for apps that only read TIFF).
    static func write(_ image: CGImage, scale: Double) throws {
        let png = try ImageFile.data(image, scale: scale, type: .png)
        let tiff = try ImageFile.data(image, scale: scale, type: .tiff)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.declareTypes([.png, .tiff], owner: nil)
        pb.setData(png, forType: .png)
        pb.setData(tiff, forType: .tiff)
    }
}
