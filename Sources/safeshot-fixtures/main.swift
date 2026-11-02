import Foundation
import SafeshotCore
import SafeshotFixtures

// Writes the synthetic demo screenshots (FAKE secrets only) to the given directory.
// Usage: safeshot-fixtures <out-dir>
let args = CommandLine.arguments
guard args.count == 2 else {
    FileHandle.standardError.write(Data("usage: safeshot-fixtures <out-dir>\n".utf8))
    exit(2)
}
let dir = URL(fileURLWithPath: args[1])
try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
let scenes: [Scene] = [
    Scenes.terminal(),
    Scenes.terminal(theme: .light, font: .sfMono, size: 12),
    Scenes.editor(),
    Scenes.editor(theme: .light, font: .menlo, size: 12),
    Scenes.dashboard(),
    Scenes.dashboard(font: .helvetica, dark: true),
]
for s in scenes {
    let url = dir.appendingPathComponent(s.name + ".png")
    try ImageFile.write(s.image, scale: s.scale, to: url)
    print(url.path)
}
