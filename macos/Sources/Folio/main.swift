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

var fileURL = URL(fileURLWithPath: filePath).standardizedFileURL
if selfTest {
    // Work on a throwaway copy inside its own "repo", so the sidecar lands next to it
    // and the CLI can be run from there.
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("folio-selftest-\(UUID().uuidString)").resolvingSymlinksInPath()
    let copy = dir.appendingPathComponent(fileURL.lastPathComponent)
    try FileManager.default.createDirectory(at: dir.appendingPathComponent(".git"), withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: fileURL, to: copy)
    fileURL = copy
}

let document: Document
do {
    document = try Document(file: fileURL)
} catch {
    FileHandle.standardError.write(Data("cannot open \(filePath): \(error)\n".utf8))
    exit(66)
}

let app = NSApplication.shared
let delegate = AppDelegate(document: document, dist: distDir ?? defaultDist, selfTest: selfTest)
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
