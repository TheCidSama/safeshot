import CoreGraphics
import Foundation

/// Pixel rectangle, origin at the **top-left** of the image.
public struct Box: Codable, Sendable, Hashable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public init(_ r: CGRect) {
        self.init(x: Double(r.minX), y: Double(r.minY), width: Double(r.width), height: Double(r.height))
    }

    public var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }

    public func offsetBy(dx: Double, dy: Double) -> Box { Box(x: x + dx, y: y + dy, width: width, height: height) }

    public var rounded: Box {
        Box(x: x.rounded(.down), y: y.rounded(.down), width: (x + width).rounded(.up) - x.rounded(.down),
            height: (y + height).rounded(.up) - y.rounded(.down))
    }
}

public struct OCRWord: Codable, Sendable, Hashable {
    public var text: String
    /// UTF-16 offset/length in the line text.
    public var location: Int
    public var length: Int
    public var box: Box
}

public struct OCRLine: Codable, Sendable, Hashable {
    /// Recognised text after look-alike normalisation (`OCRNormalizer.normalize`).
    public var text: String
    public var box: Box
    public var confidence: Float
    public var words: [OCRWord]
    /// One entry per UTF-16 unit of `text`: the glyph box, or nil when unknown (spaces, unaligned glyphs).
    public var chars: [Box?]

    public init(text: String, box: Box, confidence: Float = 1, words: [OCRWord] = [], chars: [Box?] = []) {
        self.text = text
        self.box = box
        self.confidence = confidence
        self.words = words
        self.chars = chars
    }
}

extension OCRLine {
    func offsetBy(dx: Double, dy: Double) -> OCRLine {
        var l = self
        l.box = box.offsetBy(dx: dx, dy: dy)
        l.words = words.map { var w = $0; w.box = w.box.offsetBy(dx: dx, dy: dy); return w }
        l.chars = chars.map { $0?.offsetBy(dx: dx, dy: dy) }
        return l
    }
}

public struct OCRResult: Codable, Sendable, Hashable {
    public var width: Int
    public var height: Int
    public var lines: [OCRLine]
    /// Different readings of text already covered by `lines`, from the extra OCR passes. They are scanned
    /// for secrets too (a pass that misreads a card number doesn't hide it from the pass that reads it).
    public var alternates: [OCRLine]

    public init(width: Int, height: Int, lines: [OCRLine], alternates: [OCRLine] = []) {
        self.width = width
        self.height = height
        self.lines = lines
        self.alternates = alternates
    }

    public var fullText: String { lines.map(\.text).joined(separator: "\n") }
}
