import Foundation

public enum Entropy {
    /// Shannon entropy in bits per character.
    public static func shannon(_ s: String) -> Double {
        let units = Array(s.unicodeScalars)
        guard !units.isEmpty else { return 0 }
        var counts: [UnicodeScalar: Int] = [:]
        for u in units { counts[u, default: 0] += 1 }
        let n = Double(units.count)
        return counts.values.reduce(0) { acc, c in
            let p = Double(c) / n
            return acc - p * log2(p)
        }
    }

    /// Entropy needed for a string of `length` characters to count as "random".
    /// A truly random base62 string of length n has entropy close to log2(min(n, 62)); we ask for 85% of
    /// the ideal for short strings and cap the requirement at 4.2 bits/char.
    public static func threshold(length: Int) -> Double {
        min(4.2, log2(Double(max(length, 2))) * 0.85)
    }

    static let hashContextWords = [
        "commit", "sha", "hash", "digest", "checksum", "integrity", "md5", "etag", "merge", "revision",
        "tree", "parent", "blob", "object", "build", "id:", "uuid", "fingerprint", "signature:",
    ]
    static let secretContextWords = [
        "key", "secret", "token", "password", "passwd", "credential", "auth", "bearer", "private", "apikey",
    ]

    /// Heuristic used by the `high-entropy-string` rule.
    ///
    /// * at least 20 characters (ignoring `=` padding)
    /// * pure hex strings (git SHAs, digests, UUID pieces) only count when the line talks about keys/tokens
    ///   and not about commits/hashes/digests
    /// * otherwise: upper + lower + at least two digits, entropy above `threshold(length:)`
    /// * identifiers (`NSPasteboardTypeFileURL2`) and paths (`/usr/local/lib/node_modules`) are skipped by
    ///   looking at the average length of lowercase runs and at slash density
    public static func looksLikeSecret(_ raw: String, context: String = "") -> Bool {
        let s = raw.trimmingCharacters(in: CharacterSet(charactersIn: "="))
        let n = s.count
        guard n >= 20 else { return false }
        let ctx = context.lowercased()

        let isHex = s.allSatisfy { $0.isHexDigit }
        if isHex {
            guard n >= 32 else { return false }
            if hashContextWords.contains(where: { ctx.contains($0) }) { return false }
            guard secretContextWords.contains(where: { ctx.contains($0) }) else { return false }
            return shannon(s) >= 3.0
        }

        var upper = 0, lower = 0, digit = 0, slash = 0
        for ch in s {
            if ch.isUppercase { upper += 1 } else if ch.isLowercase { lower += 1 } else if ch.isNumber { digit += 1 } else if ch == "/" { slash += 1 }
        }
        guard upper > 0, lower > 0, digit >= 2 else { return false }
        if slash >= 3 && slash * 12 > n { return false } // path-like
        if averageLowercaseRun(s) > 3.6 { return false }   // camelCase / kebab-case words
        return shannon(s) >= threshold(length: n)
    }

    static func averageLowercaseRun(_ s: String) -> Double {
        var runs: [Int] = []
        var cur = 0
        for ch in s {
            if ch.isLowercase { cur += 1 } else if cur > 0 { runs.append(cur); cur = 0 }
        }
        if cur > 0 { runs.append(cur) }
        guard !runs.isEmpty else { return 0 }
        return Double(runs.reduce(0, +)) / Double(runs.count)
    }
}

public enum Luhn {
    /// Standard Luhn (mod 10) checksum over the digits of `s`. Non-digits are ignored.
    public static func isValid(_ s: String) -> Bool {
        let digits = s.compactMap { $0.wholeNumberValue }
        guard digits.count >= 2 else { return false }
        var sum = 0
        for (i, d) in digits.reversed().enumerated() {
            if i % 2 == 1 {
                let x = d * 2
                sum += x > 9 ? x - 9 : x
            } else {
                sum += d
            }
        }
        return sum % 10 == 0
    }

    /// Maps characters OCR commonly mistakes for digits (`O`→0, `l`/`I`→1, `S`→5, `B`→8) and strips separators.
    public static func ocrDigits(_ s: String) -> String {
        var out = ""
        for ch in s {
            switch ch {
            case "0"..."9": out.append(ch)
            case "O", "o": out.append("0")
            case "l", "I": out.append("1")
            case "S": out.append("5")
            case "B": out.append("8")
            default: break
            }
        }
        return out
    }
}
