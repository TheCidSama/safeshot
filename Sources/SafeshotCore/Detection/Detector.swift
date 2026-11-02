import Foundation

/// A rule hit inside one string. `range` is a UTF-16 range (NSRange) into the scanned string.
public struct TextMatch: Sendable, Hashable {
    public var ruleID: String
    public var range: NSRange
    public var text: String
}

/// Strings/patterns that must never be reported (e.g. `127.0.0.1`, your own public email).
public struct Allowlist: Codable, Sendable, Hashable {
    public var strings: [String]
    public var patterns: [String]

    public init(strings: [String] = [], patterns: [String] = []) {
        self.strings = strings
        self.patterns = patterns
    }

    public static let defaults = Allowlist(
        strings: ["127.0.0.1", "0.0.0.0", "255.255.255.255", "255.255.255.0", "::1", "git@github.com", "git@gitlab.com"],
        patterns: [])

    enum CodingKeys: String, CodingKey { case strings, patterns }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        strings = try c.decodeIfPresent([String].self, forKey: .strings) ?? []
        patterns = try c.decodeIfPresent([String].self, forKey: .patterns) ?? []
    }
}

public enum DetectorError: Error, CustomStringConvertible {
    case badPattern(rule: String, message: String)

    public var description: String {
        switch self {
        case let .badPattern(rule, message): "invalid regular expression in rule '\(rule)': \(message)"
        }
    }
}

/// Runs a list of `Rule`s over single strings. Thread-safe and immutable after construction.
public final class Detector: @unchecked Sendable {
    struct Compiled {
        let rule: Rule
        let regex: NSRegularExpression
        let keywords: [String]?
    }

    let compiled: [Compiled]
    public let rules: [Rule]
    let allowStrings: Set<String>
    let allowPatterns: [NSRegularExpression]

    public init(rules: [Rule] = BuiltinRules.all, allowlist: Allowlist = .defaults) throws {
        var out: [Compiled] = []
        for rule in rules where rule.enabled {
            do {
                let re = try NSRegularExpression(
                    pattern: rule.pattern,
                    options: rule.caseInsensitive ? [.caseInsensitive] : [])
                out.append(Compiled(rule: rule, regex: re, keywords: rule.keywords?.map(Detector.squash)))
            } catch {
                throw DetectorError.badPattern(rule: rule.id, message: "\(error.localizedDescription)")
            }
        }
        compiled = out
        self.rules = rules
        allowStrings = Set(allowlist.strings.map { $0.lowercased() })
        allowPatterns = try allowlist.patterns.map { p in
            do { return try NSRegularExpression(pattern: p, options: [.caseInsensitive]) } catch {
                throw DetectorError.badPattern(rule: "allowlist", message: "\(p): \(error.localizedDescription)")
            }
        }
    }

    public func rule(id: String) -> Rule? { rules.first { $0.id == id } }

    static func squash(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter { $0 != " " && $0 != "_" && $0 != "-" })
    }

    /// Scan a single line. `context` is extra text used only for keyword checks (usually the previous line).
    public func scan(_ input: String, context: String = "", ruleFilter: ((Rule) -> Bool)? = nil) -> [TextMatch] {
        let text = OCRNormalizer.normalize(input)
        let ns = text as NSString
        let squashedContext = Detector.squash(context + " " + text)
        var results: [TextMatch] = []
        for c in compiled {
            if let f = ruleFilter, !f(c.rule) { continue }
            if let kws = c.keywords, !kws.contains(where: { squashedContext.contains($0) }) { continue }
            var start = 0
            while start < ns.length,
                  let m = c.regex.firstMatch(in: text, options: [], range: NSRange(location: start, length: ns.length - start)) {
                let target = Detector.targetRange(m, groups: c.rule.groups)
                if target.length > 0,
                   validate(c.rule, match: m, target: target, in: ns, context: context + " " + text),
                   !isAllowlisted(ns.substring(with: target)) {
                    results.append(TextMatch(ruleID: c.rule.id, range: target, text: ns.substring(with: target)))
                    start = max(m.range.location + max(m.range.length, 1), start + 1)
                } else {
                    // Retry one character later so a rejected candidate cannot hide an overlapping real one.
                    start = m.range.location + 1
                }
            }
        }
        return results
    }

    static func targetRange(_ m: NSTextCheckingResult, groups: [Int]) -> NSRange {
        for g in groups where g < m.numberOfRanges {
            let r = m.range(at: g)
            if r.location != NSNotFound && r.length > 0 { return r }
        }
        return NSRange(location: NSNotFound, length: 0)
    }

    func isAllowlisted(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        if allowStrings.contains(t.lowercased()) { return true }
        let ns = t as NSString
        for re in allowPatterns {
            if let m = re.firstMatch(in: t, range: NSRange(location: 0, length: ns.length)),
               m.range.location == 0, m.range.length == ns.length { return true }
        }
        return false
    }

    // MARK: Validators

    func validate(_ rule: Rule, match: NSTextCheckingResult, target: NSRange, in ns: NSString, context: String) -> Bool {
        let value = ns.substring(with: target)
        for v in rule.validators {
            switch v {
            case .luhn:
                let digits = Luhn.ocrDigits(value)
                let realDigits = value.filter(\.isNumber).count
                guard (13...19).contains(digits.count), realDigits >= 10, Luhn.isValid(digits),
                      Set(digits).count > 1 else { return false }
            case .entropy:
                guard Entropy.looksLikeSecret(value, context: context) else { return false }
            case .tokenish:
                guard Detector.isTokenish(value) else { return false }
            case .assignment:
                guard match.numberOfRanges > 1, match.range(at: 1).location != NSNotFound else { return false }
                let ident = ns.substring(with: match.range(at: 1))
                guard Detector.identifierLooksSecret(ident), Detector.valueLooksReal(value) else { return false }
            case .phone:
                guard Detector.isPlausiblePhone(value) else { return false }
            case .ipv6:
                guard Detector.isIPv6(value) else { return false }
            }
        }
        return true
    }

    static func isTokenish(_ v: String) -> Bool {
        let hasDigit = v.contains(where: \.isNumber)
        let hasUpper = v.contains(where: \.isUppercase)
        let hasLower = v.contains(where: \.isLowercase)
        if hasDigit && (hasUpper || hasLower) { return true }
        // Long mixed-case strings without digits are rare but possible.
        return v.count >= 16 && hasUpper && hasLower && Entropy.averageLowercaseRun(v) < 3.0
    }

    static let secretWords: Set<String> = [
        "key", "apikey", "token", "secret", "password", "passwd", "pwd", "pass", "passphrase", "passcode",
        "credential", "credentials", "auth", "authorization", "pat", "pin", "privatekey", "accesskey",
        "secretkey", "clientsecret", "sessionid", "cookie", "dsn", "signature", "salt",
    ]

    /// Splits `OPENAI_API_KEY`, `apiKey`, `x-api-key`, `db.password` into words and looks for a secret word.
    static func identifierLooksSecret(_ ident: String) -> Bool {
        var words: [String] = []
        var cur = ""
        var prevLower = false
        for ch in ident {
            if ch == "_" || ch == "-" || ch == "." {
                if !cur.isEmpty { words.append(cur) }
                cur = ""; prevLower = false
                continue
            }
            if ch.isUppercase && prevLower {
                words.append(cur); cur = ""
            }
            cur.append(ch)
            prevLower = ch.isLowercase || ch.isNumber
        }
        if !cur.isEmpty { words.append(cur) }
        let lower = words.map { $0.lowercased() }
        if lower.contains(where: { secretWords.contains($0) }) { return true }
        // apikey / secretkey / accesstoken written as one lowercase word.
        let joined = lower.joined()
        return ["apikey", "secretkey", "accesstoken", "authtoken", "privatekey", "accesskey", "password", "passwd"]
            .contains(where: { joined.hasSuffix($0) || joined == $0 })
    }

    static let placeholderValues: Set<String> = [
        "null", "nil", "none", "true", "false", "undefined", "string", "str", "number", "int", "bool",
        "boolean", "any", "object", "required", "optional", "secret", "token", "password", "redacted",
        "hidden", "changeme", "example", "bearer", "basic", "env", "process", "default", "value", "self",
    ]

    static func valueLooksReal(_ raw: String) -> Bool {
        let v = raw.trimmingCharacters(in: .whitespaces)
        guard v.count >= 3 else { return false }
        let lower = v.lowercased()
        if placeholderValues.contains(lower) { return false }
        if Set(v).count == 1 { return false }                                // ******** / xxxxxxx
        if v.allSatisfy({ "*•x.·-_<>[]{}".contains($0) }) { return false }
        if v.hasPrefix("$") || v.hasPrefix("<") || v.hasPrefix("{{") || v.hasPrefix("%") { return false }
        if v.contains("(") || v.contains(")") { return false }               // function calls
        for p in ["process.env", "os.environ", "os.getenv", "env.", "env[", "self.", "this.", "config.", "settings.", "secrets.", "vault:", "your_", "your-", "<your"] where lower.hasPrefix(p) {
            return false
        }
        if lower.hasSuffix("_here") || lower.contains("placeholder") { return false }
        return true
    }

    static func isPlausiblePhone(_ v: String) -> Bool {
        let digits = v.filter(\.isNumber)
        // IPv4-shaped dotted quads and dates are not phone numbers.
        if v.split(separator: ".").count == 4 && !v.contains(" ") && !v.contains("-") { return false }
        // Dates/times ("2026-11-02 12:28") are not phone numbers.
        if v.range(of: #"(?:19|20)\d\d[-/.]\d\d?[-/.]\d\d?"#, options: .regularExpression) != nil { return false }
        if v.hasPrefix("+") { return (8...15).contains(digits.count) }
        // Without a country code the last group must be a real subscriber block (3-4 digits).
        let groups = v.split(whereSeparator: { !$0.isNumber })
        if let last = groups.last, last.count < 3 { return false }
        if v.hasPrefix("(") { return (10...11).contains(digits.count) }
        return (10...11).contains(digits.count)
    }

    static func isIPv6(_ raw: String) -> Bool {
        var v = raw
        if let slash = v.firstIndex(of: "/") { v = String(v[..<slash]) }
        if let pct = v.firstIndex(of: "%") { v = String(v[..<pct]) }
        let groups = v.split(separator: ":", omittingEmptySubsequences: true)
        guard groups.count >= 3 else { return false }
        guard v.contains("::") || groups.count == 8 else { return false }
        var addr = in6_addr()
        return v.withCString { inet_pton(AF_INET6, $0, &addr) } == 1
    }
}
