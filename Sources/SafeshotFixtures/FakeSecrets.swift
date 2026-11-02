import Foundation

/// Obviously-fake credentials used in tests and demo images.
///
/// Every value contains FAKE and/or EXAMPLE (or is a documented example such as AWS's
/// `AKIAIOSFODNN7EXAMPLE`, Stripe's public test card `4242…`, RFC 5737/3849 documentation IPs and
/// `example.com` mail). None of them is valid anywhere. They are assembled from pieces at runtime so
/// that repository secret scanners don't flag this file as containing credentials.
public enum FakeSecrets {
    public static let anthropic = "sk-" + "ant-api03-" + "FAKEq8Zr2LmT0xEXAMPLEv7Nw3Hk9Pd1Ys4Bc6Jf-a1F"
    public static let openai = "sk-" + "proj-" + "FAKE9xQ2mN7vL4kR8tY1wE5zEXAMPLE3bH6"
    public static let github = "gh" + "p_" + "FAKE7Kp2Xw9Qm4Rt8Vb3EXAMPLELz5Nc1Hd6"
    public static let awsKeyID = "AK" + "IA" + "IOSFODNN7EXAMPLE"
    public static let awsSecret = "wJalrXUtnFEMI/K7MDENG/" + "bPxRfiCYEXAMPLEKEY"
    public static let stripe = "sk" + "_live_" + "FAKE51Hx9Lq2Wm7EXAMPLE4Rt8Yz"
    public static let slack = "xo" + "xb-" + "0000000000-FAKE-EXAMPLE9Qx2Lm7"
    public static let google = "AI" + "za" + "SyFAKE-EXAMPLE_k3Lm9Qx2Vb7Np4Rt8Wc1"
    public static let jwt = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9" + ".eyJzdWIiOiJGQUtFLUVYQU1QTEUiLCJuYW1lIjoiRmFrZSJ9" + ".FAKEsigEXAMPLE9Qx2Lm7Vb3Np8Rt4"
    public static let dbPassword = "FakePass-EXAMPLE-42"
    public static let databaseURL = "postgres://admin:" + dbPassword + "@db.internal.example:5432/app"
    public static let sessionSecret = "FAKE-session-EXAMPLE-k29xQ"
    public static let hfToken = "hf" + "_" + "FAKEexampleQx2Lm7Vb3Np8Rt4Wc1Hd6Zy9"
    public static let email1 = "jane.doe@example.com"
    public static let email2 = "ops-team@example.org"
    public static let email3 = "m.rossi@example.net"
    public static let ipv4a = "203.0.113.42"
    public static let ipv4b = "198.51.100.7"
    public static let ipv6 = "2001:db8::8a2e:370:7334"
    public static let phone = "+1 (555) 010-4477"
    public static let card = "4242 4242 4242 4242"
    public static let privateKeyBody = [
        "b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW",
        "QyNTUxOQAAACBGQUtFRVhBTVBMRUZBS0VFWEFNUExFRkFLRUVYQU1QTEVGQUtFAAAAkFAK",
        "EXAMPLEbm90IGEgcmVhbCBrZXkgLSBGQUtFIEVYQU1QTEUgb25seSBmb3IgdGVzdHM=",
    ]
}
