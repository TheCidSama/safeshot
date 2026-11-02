import Foundation

/// `~/.config/safeshot/config.json` (or `--config path`). Every key is optional.
///
/// ```json
/// {
///   "rules": { "ipv4": false, "phone-number": false },
///   "minimumSeverity": "low",
///   "customRules": [
///     { "id": "acme-token", "pattern": "acme_[A-Za-z0-9]{32}", "severity": "critical" }
///   ],
///   "allowlist": { "strings": ["me@example.com"], "patterns": ["^10\\.0\\.0\\.\\d+$"] },
///   "defaults": { "redact": "pixelate", "style": "ocean", "padding": 64, "frame": "none" }
/// }
/// ```
public struct Config: Codable, Sendable {
    /// Rule id -> enabled. Unlisted rules keep their default.
    public var rules: [String: Bool]
    public var minimumSeverity: Severity
    public var customRules: [Rule]
    /// Replaces the built-in allowlist when present; set `useDefaultAllowlist` to keep it as well.
    public var allowlist: Allowlist
    public var useDefaultAllowlist: Bool
    public var defaults: Defaults

    public struct Defaults: Codable, Sendable {
        public var redact: String?
        public var style: String?
        public var padding: Double?
        public var radius: Double?
        public var shadow: String?
        public var frame: String?
        public var size: String?
        public var balance: Bool?
        public var watchOutput: String?

        public init() {}
    }

    public init() {
        rules = [:]
        minimumSeverity = .low
        customRules = []
        allowlist = Allowlist()
        useDefaultAllowlist = true
        defaults = Defaults()
    }

    enum CodingKeys: String, CodingKey { case rules, minimumSeverity, customRules, allowlist, useDefaultAllowlist, defaults }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rules = try c.decodeIfPresent([String: Bool].self, forKey: .rules) ?? [:]
        minimumSeverity = try c.decodeIfPresent(Severity.self, forKey: .minimumSeverity) ?? .low
        customRules = try c.decodeIfPresent([Rule].self, forKey: .customRules) ?? []
        allowlist = try c.decodeIfPresent(Allowlist.self, forKey: .allowlist) ?? Allowlist()
        useDefaultAllowlist = try c.decodeIfPresent(Bool.self, forKey: .useDefaultAllowlist) ?? true
        defaults = try c.decodeIfPresent(Defaults.self, forKey: .defaults) ?? Defaults()
    }

    public static var defaultPath: URL {
        let env = ProcessInfo.processInfo.environment
        if let xdg = env["XDG_CONFIG_HOME"], !xdg.isEmpty {
            return URL(fileURLWithPath: xdg).appendingPathComponent("safeshot/config.json")
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/safeshot/config.json")
    }

    /// Loads `path`, or the default path if it exists, or returns the built-in defaults.
    public static func load(path: String?) throws -> Config {
        let url: URL
        if let path {
            url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw ConfigError.notFound(url.path)
            }
        } else {
            url = defaultPath
            guard FileManager.default.fileExists(atPath: url.path) else { return Config() }
        }
        do {
            return try JSONDecoder().decode(Config.self, from: Data(contentsOf: url))
        } catch let e as DecodingError {
            throw ConfigError.invalid(url.path, "\(e)")
        }
    }

    /// The effective rule list: built-ins with toggles applied, then custom rules, filtered by severity.
    public func effectiveRules(extraDisabled: Set<String> = [], extraEnabled: Set<String> = []) -> [Rule] {
        var out: [Rule] = []
        for var r in BuiltinRules.all + customRules {
            if let on = rules[r.id] { r.enabled = on }
            if extraDisabled.contains(r.id) { r.enabled = false }
            if extraEnabled.contains(r.id) { r.enabled = true }
            if r.severity < minimumSeverity { r.enabled = false }
            out.append(r)
        }
        return out
    }

    public var effectiveAllowlist: Allowlist {
        guard useDefaultAllowlist else { return allowlist }
        return Allowlist(strings: Allowlist.defaults.strings + allowlist.strings,
                         patterns: Allowlist.defaults.patterns + allowlist.patterns)
    }

    public func makeDetector(extraDisabled: Set<String> = [], extraEnabled: Set<String> = []) throws -> Detector {
        try Detector(rules: effectiveRules(extraDisabled: extraDisabled, extraEnabled: extraEnabled), allowlist: effectiveAllowlist)
    }

    /// A commented-by-example starter config written by `safeshot config init`.
    public static let starterJSON = """
    {
      "rules": {
        "ipv4": true,
        "ipv6": true,
        "phone-number": true,
        "email": true,
        "high-entropy-string": true
      },
      "minimumSeverity": "low",
      "customRules": [
        {
          "id": "example-internal-token",
          "description": "Example: internal tokens that look like acme_<32 chars>",
          "pattern": "acme_[A-Za-z0-9]{32}",
          "severity": "critical",
          "enabled": false
        }
      ],
      "allowlist": {
        "strings": [],
        "patterns": []
      },
      "useDefaultAllowlist": true,
      "defaults": {
        "redact": "pixelate",
        "style": "ocean",
        "padding": 64,
        "radius": 12,
        "shadow": "soft",
        "frame": "none",
        "size": "original",
        "balance": true,
        "watchOutput": "~/Desktop/safeshot"
      }
    }

    """
}

public enum ConfigError: Error, CustomStringConvertible {
    case notFound(String)
    case invalid(String, String)

    public var description: String {
        switch self {
        case let .notFound(p): "config file not found: \(p)"
        case let .invalid(p, why): "invalid config \(p): \(why)"
        }
    }
}
