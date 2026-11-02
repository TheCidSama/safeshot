import Foundation

/// How bad it is if this leaks.
public enum Severity: String, Codable, Sendable, CaseIterable, Comparable {
    case low, medium, high, critical

    var rank: Int {
        switch self {
        case .low: 0
        case .medium: 1
        case .high: 2
        case .critical: 3
        }
    }

    public static func < (a: Severity, b: Severity) -> Bool { a.rank < b.rank }
}

public enum RuleCategory: String, Codable, Sendable {
    case secret, pii, network, financial, custom
}

/// Extra checks applied to a regex match before it becomes a finding.
public enum Validator: String, Codable, Sendable {
    /// Credit card numbers: OCR-confusable digits are normalised, then the Luhn checksum must pass.
    case luhn
    /// Shannon entropy + charset heuristics (see `Entropy.looksLikeSecret`).
    case entropy
    /// The captured value must look like a token (has a digit, not a plain English word).
    case tokenish
    /// `identifier = value`: identifier must contain a secret-ish word, value must not be a placeholder or code.
    case assignment
    /// Digit count/shape plausibility for phone numbers.
    case phone
    /// Must parse as an IPv6 address with at least three groups.
    case ipv6
}

/// A single detection rule. Rules are plain data: the built-in list lives in `BuiltinRules.swift`
/// and users can add their own in the config file using exactly the same shape.
public struct Rule: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var description: String
    public var severity: Severity
    public var category: RuleCategory
    /// ICU regular expression (NSRegularExpression syntax).
    public var pattern: String
    /// Capture groups that hold the sensitive part, tried in order; the first one that participated wins.
    /// `[0]` (the default) means the whole match.
    public var groups: [Int]
    public var caseInsensitive: Bool
    /// If set, the line (or the line above it) must contain one of these words for the rule to fire.
    /// Comparison ignores case, spaces, `_` and `-`.
    public var keywords: [String]?
    public var validators: [Validator]
    /// Used to pick the "best" label when several rules hit the same text. Higher wins.
    public var specificity: Int
    /// Whether the match may continue on the next visual line (soft-wrapped terminals/editors).
    public var allowWrap: Bool
    /// Special handling: `-----BEGIN … PRIVATE KEY-----` followed by a body on the next lines.
    public var privateKeyBlock: Bool
    public var enabled: Bool

    public init(
        id: String,
        description: String,
        severity: Severity,
        category: RuleCategory,
        pattern: String,
        groups: [Int] = [0],
        caseInsensitive: Bool = false,
        keywords: [String]? = nil,
        validators: [Validator] = [],
        specificity: Int = 50,
        allowWrap: Bool = true,
        privateKeyBlock: Bool = false,
        enabled: Bool = true
    ) {
        self.id = id
        self.description = description
        self.severity = severity
        self.category = category
        self.pattern = pattern
        self.groups = groups
        self.caseInsensitive = caseInsensitive
        self.keywords = keywords
        self.validators = validators
        self.specificity = specificity
        self.allowWrap = allowWrap
        self.privateKeyBlock = privateKeyBlock
        self.enabled = enabled
    }

    enum CodingKeys: String, CodingKey {
        case id, description, severity, category, pattern, groups, caseInsensitive, keywords, validators
        case specificity, allowWrap, privateKeyBlock, enabled
    }

    /// Lenient decoding so custom rules in the config only need `id` and `pattern`.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        pattern = try c.decode(String.self, forKey: .pattern)
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? "Custom rule \(id)"
        severity = try c.decodeIfPresent(Severity.self, forKey: .severity) ?? .high
        category = try c.decodeIfPresent(RuleCategory.self, forKey: .category) ?? .custom
        groups = try c.decodeIfPresent([Int].self, forKey: .groups) ?? [0]
        caseInsensitive = try c.decodeIfPresent(Bool.self, forKey: .caseInsensitive) ?? false
        keywords = try c.decodeIfPresent([String].self, forKey: .keywords)
        validators = try c.decodeIfPresent([Validator].self, forKey: .validators) ?? []
        specificity = try c.decodeIfPresent(Int.self, forKey: .specificity) ?? 75
        allowWrap = try c.decodeIfPresent(Bool.self, forKey: .allowWrap) ?? true
        privateKeyBlock = try c.decodeIfPresent(Bool.self, forKey: .privateKeyBlock) ?? false
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }
}
