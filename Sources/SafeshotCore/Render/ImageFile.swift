import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct LoadedImage: @unchecked Sendable {
    public var image: CGImage
    /// Pixels per point (2 for Retina screenshots).
    public var scale: Double

    public init(image: CGImage, scale: Double) {
        self.image = image
        self.scale = scale
    }
}

public enum ImageFileError: Error, CustomStringConvertible {
    case unreadable(String)
    case unwritable(String)

    public var description: String {
        switch self {
        case let .unreadable(p): "cannot read image: \(p)"
        case let .unwritable(p): "cannot write image: \(p)"
        }
    }
}

public enum ImageFile {
    public static func load(_ url: URL) throws -> LoadedImage {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw ImageFileError.unreadable(url.path) }
        return try load(source: src, name: url.path)
    }

    public static func load(data: Data) throws -> LoadedImage {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { throw ImageFileError.unreadable("<data>") }
        return try load(source: src, name: "<data>")
    }

    static func load(source src: CGImageSource, name: String) throws -> LoadedImage {
        guard let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { throw ImageFileError.unreadable(name) }
        var scale = 1.0
        if let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
           let dpi = (props[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue, dpi > 72 {
            scale = (dpi / 72).rounded()
        }
        return LoadedImage(image: img, scale: max(1, min(scale, 4)))
    }

    public static func data(_ image: CGImage, scale: Double, type: UTType = .png) throws -> Data {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil) else {
            throw ImageFileError.unwritable("<memory>")
        }
        var props: [CFString: Any] = [
            kCGImagePropertyDPIWidth: 72 * scale,
            kCGImagePropertyDPIHeight: 72 * scale,
        ]
        if type == .jpeg { props[kCGImageDestinationLossyCompressionQuality] = 0.92 }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ImageFileError.unwritable("<memory>") }
        return out as Data
    }

    public static func write(_ image: CGImage, scale: Double, to url: URL) throws {
        let ext = url.pathExtension.lowercased()
        let type: UTType = (ext == "jpg" || ext == "jpeg") ? .jpeg : (ext == "tiff" || ext == "tif") ? .tiff : .png
        let d = try data(image, scale: scale, type: type)
        do { try d.write(to: url, options: .atomic) } catch { throw ImageFileError.unwritable(url.path) }
    }
}
