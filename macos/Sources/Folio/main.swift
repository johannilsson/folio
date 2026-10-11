import AppKit

// folio-app [--dist <dir>] [--self-test] <file.md>
var args = Array(CommandLine.arguments.dropFirst())
var distDir: URL?
var selfTest = false
var filePath: String?

while !args.isEmpty {
    let arg = args.removeFirst()
    switch arg {
    case "--dist": distDir = URL(fileURLWithPath: args.removeFirst())
    case "--self-test": selfTest = true
    default: filePath = arg
    }
}

// Development default: the frontend build of the checkout this was compiled from.
let defaultDist = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("frontend/dist")

guard let filePath else {
    FileHandle.standardError.write(Data("usage: Folio [--dist dir] [--self-test] <file.md>\n".utf8))
    exit(64)
}

let app = NSApplication.shared
let delegate = AppDelegate(
    file: URL(fileURLWithPath: filePath).standardizedFileURL,
    dist: distDir ?? defaultDist,
    selfTest: selfTest
)
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
