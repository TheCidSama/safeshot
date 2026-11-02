import Foundation

/// The built-in rule list. Everything here is data; the engine in `Detector.swift` is generic.
///
/// Notes on OCR tolerance:
/// * Text is first passed through `OCRNormalizer` (Cyrillic/Greek look-alikes -> Latin, smart quotes, dashes).
/// * Fixed prefixes accept the classic OCR confusions where it matters (`I`/`l`/`1`, `O`/`0`, `J`/`j`).
/// * Token bodies use ranges (`{30,40}` instead of `{36}`) because OCR occasionally drops or doubles a glyph.
public enum BuiltinRules {
    public static let all: [Rule] = [
        // MARK: Provider-specific API keys and tokens
        Rule(
            id: "aws-access-key-id",
            description: "AWS access key ID",
            severity: .critical, category: .secret,
            pattern: #"(?<![A-Za-z0-9])(?:A[KS][I1l]A|ABIA|ACCA|A3T[A-Z0-9])[A-Z0-9]{16}(?![A-Za-z0-9])"#,
            specificity: 100),
        Rule(
            id: "aws-secret-access-key",
            description: "AWS secret access key (40 chars next to an aws_secret/SecretAccessKey label)",
            severity: .critical, category: .secret,
            pattern: #"(?<![A-Za-z0-9/+])[A-Za-z0-9/+]{38,42}(?![A-Za-z0-9/+])"#,
            keywords: ["aws_secret", "secret_access_key", "secretaccesskey", "aws secret"],
            specificity: 95),
        Rule(
            id: "github-token",
            description: "GitHub token (ghp_/gho_/ghu_/ghs_/ghr_)",
            severity: .critical, category: .secret,
            pattern: #"(?<![A-Za-z0-9])gh[pousr]_[A-Za-z0-9]{30,40}(?![A-Za-z0-9])"#,
            specificity: 100),
        Rule(
            id: "github-fine-grained-pat",
            description: "GitHub fine-grained personal access token (github_pat_)",
            severity: .critical, category: .secret,
            pattern: #"(?<![A-Za-z0-9])github_pat_[A-Za-z0-9_]{30,}"#,
            specificity: 100),
        Rule(
            id: "gitlab-token",
            description: "GitLab personal access token (glpat-)",
            severity: .critical, category: .secret,
            pattern: #"(?<![A-Za-z0-9])glpat-[A-Za-z0-9_\-]{20,}"#,
            specificity: 100),
        Rule(
            id: "anthropic-api-key",
            description: "Anthropic API key (sk-ant-)",
            severity: .critical, category: .secret,
            pattern: #"(?<![A-Za-z0-9])sk-ant-[A-Za-z0-9_\-]{20,}"#,
            specificity: 100),
        Rule(
            id: "openai-api-key",
            description: "OpenAI API key (sk-, sk-proj-, sk-svcacct-)",
            severity: .critical, category: .secret,
            pattern: #"(?<![A-Za-z0-9_\-])sk-(?!ant-)(?:proj-|svcacct-|admin-)?[A-Za-z0-9_\-]{20,}"#,
            validators: [.tokenish],
            specificity: 98),
        Rule(
            id: "stripe-secret-key",
            description: "Stripe secret or restricted key (sk_live_/rk_live_/sk_test_)",
            severity: .critical, category: .secret,
            pattern: #"(?<![A-Za-z0-9])(?:sk|rk)_(?:live|test)_[A-Za-z0-9]{10,}"#,
            specificity: 100),
        Rule(
            id: "stripe-publishable-key",
            description: "Stripe publishable key (pk_live_/pk_test_) - public, but identifies your account",
            severity: .low, category: .secret,
            pattern: #"(?<![A-Za-z0-9])pk_(?:live|test)_[A-Za-z0-9]{10,}"#,
            specificity: 100),
        Rule(
            id: "slack-token",
            description: "Slack token (xoxb-/xoxp-/xoxa-/xoxr-/xoxs-)",
            severity: .critical, category: .secret,
            pattern: #"(?<![A-Za-z0-9])xox[abposr]-[A-Za-z0-9\-]{10,}"#,
            specificity: 100),
        Rule(
            id: "slack-webhook",
            description: "Slack incoming-webhook URL",
            severity: .high, category: .secret,
            pattern: #"hooks\.slack\.com/services/([A-Za-z0-9/_\-]{20,})"#,
            groups: [1], specificity: 100),
        Rule(
            id: "google-api-key",
            description: "Google API key (AIza)",
            severity: .critical, category: .secret,
            pattern: #"(?<![A-Za-z0-9])A[I1l]za[0-9A-Za-z_\-]{30,40}(?![A-Za-z0-9_\-])"#,
            specificity: 100),
        Rule(
            id: "npm-token",
            description: "npm access token (npm_)",
            severity: .critical, category: .secret,
            pattern: #"(?<![A-Za-z0-9])npm_[A-Za-z0-9]{30,40}(?![A-Za-z0-9])"#,
            specificity: 100),
        Rule(
            id: "huggingface-token",
            description: "Hugging Face token (hf_)",
            severity: .high, category: .secret,
            pattern: #"(?<![A-Za-z0-9])hf_[A-Za-z0-9]{30,40}(?![A-Za-z0-9])"#,
            specificity: 100),
        Rule(
            id: "sendgrid-api-key",
            description: "SendGrid API key (SG.)",
            severity: .critical, category: .secret,
            pattern: #"(?<![A-Za-z0-9])SG\.[A-Za-z0-9_\-]{16,32}\.[A-Za-z0-9_\-]{30,50}"#,
            specificity: 100),
        Rule(
            id: "jwt",
            description: "JSON Web Token (eyJ….eyJ….…)",
            severity: .high, category: .secret,
            pattern: #"(?<![A-Za-z0-9_\-])ey[JjI][A-Za-z0-9_\-]{5,}\.ey[JjI][A-Za-z0-9_\-]{5,}\.[A-Za-z0-9_\-]{5,}"#,
            specificity: 95),
        Rule(
            id: "private-key",
            description: "Private key block (-----BEGIN … PRIVATE KEY-----)",
            severity: .critical, category: .secret,
            pattern: #"-+\s*BEGIN\s+(?:[A-Z0-9]+\s+)*PRIVATE\s+KEY(?:\s+BLOCK)?[\s_.\-]*(.*)"#,
            groups: [1, 0], specificity: 100, allowWrap: false, privateKeyBlock: true),

        // MARK: Generic secrets
        Rule(
            id: "connection-string-password",
            description: "Password inside a URL / connection string (scheme://user:password@host)",
            severity: .critical, category: .secret,
            pattern: #"\b[A-Za-z][A-Za-z0-9+.\-]{1,20}://[^\s:/@]+:([^\s@/]{1,})@"#,
            groups: [1], specificity: 85),
        Rule(
            id: "authorization-header",
            description: "Bearer/Basic/Token credential in an Authorization header",
            severity: .critical, category: .secret,
            pattern: #"\b(?:bearer|basic|token)\s+([A-Za-z0-9._~+/\-]{12,}=*)"#,
            groups: [1], caseInsensitive: true,
            validators: [.tokenish], specificity: 80),
        Rule(
            id: "secret-assignment",
            description: "Assignment to a KEY/TOKEN/SECRET/PASSWORD-like name (KEY=…, \"token\": \"…\", password: …)",
            severity: .high, category: .secret,
            pattern: #"(?<![A-Za-z0-9_])["']?([A-Za-z_][A-Za-z0-9_.\-]{0,60})["']?\s*(?::=|=>|[:=])\s*(?:"([^"\n]{3,})"|'([^'\n]{3,})'|`([^`\n]{3,})`|([^\s"'`,;]{3,}))"#,
            groups: [2, 3, 4, 5],
            validators: [.assignment], specificity: 60),
        Rule(
            id: "high-entropy-string",
            description: "High-entropy string that looks like a random secret",
            severity: .medium, category: .secret,
            pattern: #"(?<![A-Za-z0-9+/_\-])[A-Za-z0-9+/_\-]{20,}={0,2}(?![A-Za-z0-9+/=_\-])"#,
            validators: [.entropy], specificity: 10),

        // MARK: Personal data
        Rule(
            id: "email",
            description: "Email address",
            severity: .medium, category: .pii,
            pattern: #"(?<![A-Za-z0-9._%+\-:/])[A-Za-z0-9][A-Za-z0-9._%+\-]*@[A-Za-z0-9](?:[A-Za-z0-9\-]*[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9\-]*[A-Za-z0-9])?)*\.[A-Za-z]{2,}"#,
            specificity: 50, allowWrap: false),
        Rule(
            id: "phone-number",
            description: "Phone number",
            severity: .medium, category: .pii,
            pattern: #"(?<![\w+.\-/])(?:\+\d{1,3}[\s.\-]?)?(?:\(\d{1,4}\)[\s.\-]?|\d{1,4}[\s.\-])(?:\d{2,4}[\s.\-]){1,3}\d{2,4}(?![\w.\-/])"#,
            validators: [.phone], specificity: 40, allowWrap: false),
        Rule(
            id: "credit-card",
            description: "Credit card number (Luhn-validated)",
            severity: .critical, category: .financial,
            pattern: #"(?<![\w\-])(?:[0-9OolISB][ \-]?){12,18}[0-9OolISB](?![\w\-])"#,
            validators: [.luhn], specificity: 90, allowWrap: false),

        // MARK: Network
        Rule(
            id: "ipv4",
            description: "IPv4 address",
            severity: .low, category: .network,
            pattern: #"(?<![\w.])(?:(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(?:/\d{1,2})?(?![0-9]|\.\d)"#,
            specificity: 45, allowWrap: false),
        Rule(
            id: "ipv6",
            description: "IPv6 address",
            severity: .low, category: .network,
            pattern: #"(?<![\w:.])(?:[0-9A-Fa-f]{0,4}:){2,7}[0-9A-Fa-f]{0,4}(?:%[A-Za-z0-9]+)?(?:/\d{1,3})?(?![\w:])"#,
            validators: [.ipv6], specificity: 45, allowWrap: false),
    ]
}
