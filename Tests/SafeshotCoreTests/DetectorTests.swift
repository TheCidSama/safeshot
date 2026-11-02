import Foundation
import Testing
@testable import SafeshotCore
import SafeshotFixtures

let detector = try! Detector()
typealias F = FakeSecrets

/// Rule ids that fire on `text`, and the matched substrings.
func hits(_ text: String, context: String = "") -> [String: [String]] {
    var out: [String: [String]] = [:]
    for m in detector.scan(text, context: context) { out[m.ruleID, default: []].append(m.text) }
    return out
}

func fires(_ rule: String, _ text: String, value: String? = nil, context: String = "") -> Bool {
    guard let vals = hits(text, context: context)[rule] else { return false }
    guard let value else { return true }
    return vals.contains(value)
}

@Suite("Provider tokens")
struct ProviderTokenTests {
    @Test func aws() {
        #expect(fires("aws-access-key-id", "AWS_ACCESS_KEY_ID=" + F.awsKeyID, value: F.awsKeyID))
        #expect(fires("aws-access-key-id", "key: AK1AIOSFODNN7EXAMPLE")) // OCR: I -> 1
        #expect(!fires("aws-access-key-id", "AKIAIOSFODNN7EXAMPLE123")) // too long
        #expect(!fires("aws-access-key-id", "AKIA-short"))
        #expect(fires("aws-secret-access-key", "aws_secret_access_key = " + F.awsSecret, value: F.awsSecret))
        #expect(fires("aws-secret-access-key", F.awsSecret, context: "AWS_SECRET_ACCESS_KEY:"))
        #expect(!fires("aws-secret-access-key", "some_value = " + F.awsSecret)) // no aws_secret context
    }

    @Test func github() {
        #expect(fires("github-token", "GITHUB_TOKEN=" + F.github, value: F.github))
        for p in ["gho_", "ghs_", "ghu_", "ghr_"] {
            #expect(fires("github-token", p + "FAKE7Kp2Xw9Qm4Rt8Vb3EXAMPLELz5Nc1Hd6"))
        }
        #expect(fires("github-fine-grained-pat", "github_" + "pat_11FAKE0000EXAMPLE_abcdefghijklmnopqrstuvwxyz0123456789"))
        #expect(!fires("github-token", "ghp_short123"))
        #expect(!fires("github-token", "highp_FAKE7Kp2Xw9Qm4Rt8Vb3EXAMPLELz5Nc1Hd6"))
    }

    @Test func openaiAndAnthropic() {
        #expect(fires("anthropic-api-key", "ANTHROPIC_API_KEY=" + F.anthropic, value: F.anthropic))
        #expect(!fires("openai-api-key", F.anthropic)) // sk-ant- is Anthropic, not OpenAI
        #expect(fires("openai-api-key", "OPENAI_API_KEY=" + F.openai, value: F.openai))
        #expect(fires("openai-api-key", "sk-" + "FAKEexample9xQ2mN7vL4kR8tY1wE5z"))
        #expect(!fires("openai-api-key", "task-runner-config-file-name-here"))
        #expect(!fires("openai-api-key", "sk-learn-is-a-python-library-name")) // no digits: not a token
    }

    @Test func stripeSlackGoogle() {
        #expect(fires("stripe-secret-key", F.stripe, value: F.stripe))
        #expect(fires("stripe-secret-key", "rk" + "_live_FAKE51Hx9Lq2Wm7EXAMPLE"))
        #expect(fires("stripe-publishable-key", "pk" + "_live_FAKE51Hx9Lq2Wm7EXAMPLE"))
        #expect(!fires("stripe-secret-key", "sk_live_"))
        #expect(fires("slack-token", "token: " + F.slack, value: F.slack))
        #expect(fires("slack-webhook", "https://hooks." + "slack.com/services/" + "T00000000/B00000000/FAKEEXAMPLEFAKEEXAMPLE00"))
        #expect(fires("google-api-key", "key=" + F.google, value: F.google))
        #expect(fires("google-api-key", "A1za" + "SyFAKE-EXAMPLE_k3Lm9Qx2Vb7Np4Rt8Wc1")) // OCR: I -> 1
        #expect(!fires("google-api-key", "AIza short"))
        #expect(fires("huggingface-token", F.hfToken))
        #expect(fires("npm-token", "npm_" + "FAKEexampleQx2Lm7Vb3Np8Rt4Wc1Hd6Zy9a"))
        #expect(fires("gitlab-token", "glpat-" + "FAKE-EXAMPLE_xQ2mN7vL4kR8"))
        #expect(fires("sendgrid-api-key", "SG." + "FAKEexample0000000000.FAKEexampleQx2Lm7Vb3Np8Rt4Wc1Hd6Zy9abcdefgh"))
    }

    @Test func jwtAndPrivateKeys() {
        #expect(fires("jwt", "Authorization: Bearer " + F.jwt, value: F.jwt))
        #expect(fires("jwt", F.jwt.replacingOccurrences(of: "eyJ", with: "eyj"))) // OCR J/j
        #expect(!fires("jwt", "eyJhbGciOi"))
        #expect(fires("private-key", "-----BEGIN RSA PRIVATE KEY-----"))
        #expect(fires("private-key", "-----BEGIN OPENSSH PRIVATE KEY-----"))
        #expect(fires("private-key", "-BEGIN PRIVATE KEY-")) // OCR collapses dashes
        #expect(!fires("private-key", "-----BEGIN PUBLIC KEY-----"))
        #expect(!fires("private-key", "-----BEGIN CERTIFICATE-----"))
    }
}

@Suite("Generic secrets")
struct GenericSecretTests {
    @Test func assignments() {
        #expect(fires("secret-assignment", "PASSWORD=hunter2-FAKE", value: "hunter2-FAKE"))
        #expect(fires("secret-assignment", "export DB_PASSWORD=\"correct horse FAKE\"", value: "correct horse FAKE"))
        #expect(fires("secret-assignment", "\"api_key\": \"FAKE-0000-EXAMPLE\"", value: "FAKE-0000-EXAMPLE"))
        #expect(fires("secret-assignment", "clientSecret: 'FAKEexample42'", value: "FAKEexample42"))
        #expect(fires("secret-assignment", "-H \"X-Api-Key: FAKEexample42\""))
        #expect(fires("secret-assignment", "SECRET_KEY_BASE=FAKE0123456789"))
        #expect(fires("secret-assignment", "--password=FAKEpass"))
        // Negatives: placeholders, code, types, non-secret names.
        #expect(!fires("secret-assignment", "PASSWORD=********"))
        #expect(!fires("secret-assignment", "API_KEY=${API_KEY}"))
        #expect(!fires("secret-assignment", "api_key = os.environ[\"API_KEY\"]"))
        #expect(!fires("secret-assignment", "const token = getToken()"))
        #expect(!fires("secret-assignment", "apiKey: string;"))
        #expect(!fires("secret-assignment", "password: <your-password>"))
        #expect(!fires("secret-assignment", "keyboard=us-intl"))
        #expect(!fires("secret-assignment", "author: Jane Doe"))
        #expect(!fires("secret-assignment", "TOKEN=your_token_here"))
        #expect(!fires("secret-assignment", "Authorization: Bearer"))
    }

    @Test func bearerAndConnectionStrings() {
        #expect(fires("authorization-header", "Authorization: Bearer FAKEtoken0123456789", value: "FAKEtoken0123456789"))
        #expect(fires("authorization-header", "Authorization: Basic RkFLRTpFWEFNUExFMTIz", value: "RkFLRTpFWEFNUExFMTIz"))
        #expect(!fires("authorization-header", "Use a bearer authentication scheme"))
        #expect(fires("connection-string-password", F.databaseURL, value: F.dbPassword))
        #expect(fires("connection-string-password", "mongodb+srv://app:FAKEpw42@cluster0.example.net/db", value: "FAKEpw42"))
        #expect(fires("connection-string-password", "redis://default:FAKEpw42@cache:6379", value: "FAKEpw42"))
        #expect(!fires("connection-string-password", "https://example.com/path:with@colon"))
        #expect(!fires("email", F.databaseURL)) // the password@host part is not an email
    }

    @Test func highEntropy() {
        #expect(fires("high-entropy-string", "token Xq9vL2mR8tY1wE5zK3bH6nP4"))
        #expect(fires("high-entropy-string", "c2VjcmV0LUZBS0UtRVhBTVBMRS0xMjM0NTY3ODkw"))
        // Hashes in hash contexts, identifiers, paths, UUIDs: not secrets.
        #expect(!fires("high-entropy-string", "commit 3f2a9c1e5b7d4f6a8c0e2b4d6f8a1c3e5b7d9f0a"))
        #expect(!fires("high-entropy-string", "sha256:9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08"))
        #expect(!fires("high-entropy-string", "NSPasteboardTypeFileURL2Representation"))
        #expect(!fires("high-entropy-string", "/usr/local/lib/node_modules/typescript/bin2"))
        #expect(!fires("high-entropy-string", "550e8400-e29b-41d4-a716-446655440000"))
        #expect(!fires("high-entropy-string", "the-quick-brown-fox-jumps-over-2-lazy-dogs-42"))
        // Pure hex counts only next to secret words.
        #expect(fires("high-entropy-string", "secret 3f2a9c1e5b7d4f6a8c0e2b4d6f8a1c3e"))
    }
}

@Suite("PII and network")
struct PIITests {
    @Test func emails() {
        #expect(fires("email", "contact jane.doe@example.com today", value: "jane.doe@example.com"))
        #expect(fires("email", "\"ops-team@example.org\","))
        #expect(fires("email", "first.last+tag@sub.example.co.uk"))
        #expect(!fires("email", "git@github.com:acme/repo.git")) // allowlisted
        #expect(!fires("email", "@mention someone"))
        #expect(!fires("email", "user@localhost"))
        #expect(fires("email", "jane.doe©example.com")) // OCR: @ -> ©
    }

    @Test func phones() {
        #expect(fires("phone-number", "call +1 (555) 010-4477 now"))
        #expect(fires("phone-number", "+44 20 7946 0958"))
        #expect(fires("phone-number", "555-010-4477"))
        #expect(fires("phone-number", "(555) 010-4477"))
        #expect(!fires("phone-number", "2026-11-02 12:28:40"))
        #expect(!fires("phone-number", "192.168.10.200"))
        #expect(!fires("phone-number", "version 1.2.3"))
        #expect(!fires("phone-number", "4242 4242 4242 4242")) // card, not phone
    }

    @Test func ips() {
        #expect(fires("ipv4", "host 203.0.113.42 up", value: "203.0.113.42"))
        #expect(fires("ipv4", "10.0.0.0/8"))
        #expect(fires("ipv4", "192.0.2.15l")) // trailing OCR junk
        #expect(!fires("ipv4", "127.0.0.1"))   // allowlisted
        #expect(!fires("ipv4", "999.1.1.1"))
        #expect(!fires("ipv4", "v1.2.3.4.5"))
        #expect(fires("ipv6", F.ipv6, value: F.ipv6))
        #expect(fires("ipv6", "fe80::1ff:fe23:4567:890a%en0"))
        #expect(fires("ipv6", "2001:0db8:0000:0000:0000:ff00:0042:8329"))
        #expect(!fires("ipv6", "12:28:40"))
        #expect(!fires("ipv6", "std::vector"))
        #expect(!fires("ipv6", "aa:bb:cc:dd:ee:ff")) // MAC address
        #expect(!fires("ipv6", "::1"))
    }

    @Test func cards() {
        #expect(fires("credit-card", "card 4242 4242 4242 4242 exp", value: "4242 4242 4242 4242"))
        #expect(fires("credit-card", "5555-5555-5555-4444"))
        #expect(fires("credit-card", "3782 822463 10005")) // Amex grouping
        #expect(fires("credit-card", "4000 O566 5566 5556")) // OCR: 0 -> O, still Luhn-valid
        #expect(!fires("credit-card", "4242 4242 4242 4241")) // Luhn fails
        #expect(!fires("credit-card", "0000 0000 0000 0000"))
        #expect(!fires("credit-card", "1234 5678"))
    }
}

@Suite("Algorithms")
struct AlgorithmTests {
    @Test func luhn() {
        #expect(Luhn.isValid("4242424242424242"))
        #expect(Luhn.isValid("378282246310005"))
        #expect(Luhn.isValid("79927398713"))
        #expect(!Luhn.isValid("79927398710"))
        #expect(!Luhn.isValid("4242424242424241"))
        #expect(Luhn.ocrDigits("4O0O lI5B") == "40001158")
    }

    @Test func entropy() {
        #expect(Entropy.shannon("") == 0)
        #expect(Entropy.shannon("aaaa") == 0)
        #expect(abs(Entropy.shannon("ab") - 1) < 1e-9)
        #expect(abs(Entropy.shannon("abcd") - 2) < 1e-9)
        #expect(Entropy.threshold(length: 20) < Entropy.threshold(length: 40))
        // Random base62 strings are flagged.
        var rng = SplitMix(seed: 42)
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        var flagged = 0
        for _ in 0..<200 {
            let s = String((0..<32).map { _ in alphabet[Int(rng.next() % UInt64(alphabet.count))] })
            if Entropy.looksLikeSecret(s) { flagged += 1 }
        }
        #expect(flagged >= 190, "only \(flagged)/200 random tokens flagged")
    }

    @Test func normalizer() {
        #expect(OCRNormalizer.normalize("apі03") == "api03") // Cyrillic і
        #expect(OCRNormalizer.normalize("“x”—y") == "\"x\"-y")
        let s = "sk-ant-аpі03"
        #expect((OCRNormalizer.normalize(s) as NSString).length == (s as NSString).length)
        #expect(OCRNormalizer.skeleton("O0 Il1") == OCRNormalizer.skeleton("00 111"))
        // Detection works through look-alikes.
        #expect(fires("anthropic-api-key", F.anthropic.replacingOccurrences(of: "api03", with: "apі03")))
    }

    @Test func mask() {
        #expect(Mask.preview(F.anthropic) == "sk-ant-…a1F")
        #expect(Mask.preview("hunter2") == "h…")
        #expect(Mask.preview("abc") == "•••")
        #expect(!Mask.preview(F.github).contains("Kp2Xw9"))
        #expect(Mask.preview("jane.doe@example.com") == "j…@….com")
    }

    @Test func aligner() {
        let a = Array("API_KEY=sk-Lm9".utf16), b = Array("API KEY=sk-Lrn9".utf16)
        let m = Aligner.align(a, b)
        #expect(m[0] == 0)
        #expect(m[8] == 8) // 's'
        #expect(m.compactMap { $0 }.count >= 11)
    }
}

struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
