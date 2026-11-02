// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "safeshot",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "safeshot", targets: ["safeshot"]),
        .library(name: "SafeshotCore", targets: ["SafeshotCore"]),
    ],
    targets: [
        // Detection, OCR, redaction, beautification, report. No third-party dependencies.
        .target(name: "SafeshotCore"),
        // The command-line tool, clipboard/watch workflows and the SwiftUI review window + menu bar item.
        .executableTarget(name: "safeshot", dependencies: ["SafeshotCore"]),
    ]
)
