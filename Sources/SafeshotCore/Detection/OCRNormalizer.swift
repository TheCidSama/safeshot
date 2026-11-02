import Foundation

/// OCR output frequently contains look-alike characters (Vision happily returns a Cyrillic `і` in the
/// middle of an API key). `normalize` maps them to ASCII **one UTF-16 unit to one UTF-16 unit**, so
/// ranges found in the normalised string are valid in the original string and its geometry.
public enum OCRNormalizer {
    static let table: [UInt16: UInt16] = {
        let pairs: [(Character, Character)] = [
            // Cyrillic
            ("а", "a"), ("е", "e"), ("о", "o"), ("р", "p"), ("с", "c"), ("у", "y"), ("х", "x"),
            ("і", "i"), ("ј", "j"), ("ѕ", "s"), ("ԁ", "d"), ("һ", "h"), ("ӏ", "l"), ("ԛ", "q"), ("ԝ", "w"),
            ("А", "A"), ("В", "B"), ("Е", "E"), ("К", "K"), ("М", "M"), ("Н", "H"), ("О", "O"),
            ("Р", "P"), ("С", "C"), ("Т", "T"), ("Х", "X"), ("І", "I"), ("Ј", "J"), ("Ѕ", "S"), ("У", "Y"),
            // Greek
            ("α", "a"), ("ο", "o"), ("ι", "i"), ("κ", "k"), ("ν", "v"), ("ρ", "p"), ("τ", "t"), ("υ", "u"),
            ("Α", "A"), ("Β", "B"), ("Ε", "E"), ("Ζ", "Z"), ("Η", "H"), ("Ι", "I"), ("Κ", "K"), ("Μ", "M"),
            ("Ν", "N"), ("Ο", "O"), ("Ρ", "P"), ("Τ", "T"), ("Υ", "Y"), ("Χ", "X"),
            // Punctuation look-alikes
            ("‐", "-"), ("‑", "-"), ("‒", "-"), ("–", "-"), ("—", "-"), ("−", "-"), ("﹣", "-"), ("－", "-"),
            ("‘", "'"), ("’", "'"), ("‚", "'"), ("′", "'"), ("“", "\""), ("”", "\""), ("„", "\""), ("″", "\""),
            ("＝", "="), ("：", ":"), ("．", "."), ("·", "."), ("＿", "_"), ("／", "/"), ("＠", "@"),
            ("ı", "i"), ("ł", "l"), ("Ø", "0"), ("ø", "0"), ("©", "@"),
            ("\u{00A0}", " "), ("\u{2009}", " "), ("\u{202F}", " "), ("\u{3000}", " "),
        ]
        var t: [UInt16: UInt16] = [:]
        for (a, b) in pairs {
            let au = Array(String(a).utf16), bu = Array(String(b).utf16)
            precondition(au.count == 1 && bu.count == 1)
            t[au[0]] = bu[0]
        }
        return t
    }()

    public static func normalize(_ s: String) -> String {
        var units = Array(s.utf16)
        var changed = false
        for i in units.indices {
            if let r = table[units[i]] {
                units[i] = r
                changed = true
            }
        }
        return changed ? String(decoding: units, as: UTF16.self) : s
    }

    /// Collapses characters OCR confuses with each other into one representative. Used for fuzzy
    /// comparisons (alignment, tests), never for the text we report.
    public static func confusableKey(_ u: UInt16) -> UInt16 {
        switch u {
        case 0x4F, 0x6F, 0x30, 0x51, 0x44: return 0x30         // O o 0 Q D -> 0
        case 0x49, 0x6C, 0x31, 0x69, 0x7C, 0x21, 0x4C: return 0x31 // I l 1 i | ! L -> 1
        case 0x53, 0x73, 0x35: return 0x35                     // S s 5 -> 5
        case 0x42, 0x38: return 0x38                           // B 8 -> 8
        case 0x5A, 0x7A, 0x32: return 0x32                     // Z z 2 -> 2
        case 0x47, 0x36: return 0x36                           // G 6
        case 0x41...0x5A: return u + 0x20                      // case-fold the rest
        default: return u
        }
    }

    /// Lowercased, confusables collapsed, whitespace removed. For "is this string recoverable" checks.
    public static func skeleton(_ s: String) -> String {
        let units = normalize(s).utf16.filter { $0 != 0x20 && $0 != 0x09 && $0 != 0x0A }.map(confusableKey)
        return String(decoding: units, as: UTF16.self)
    }
}
