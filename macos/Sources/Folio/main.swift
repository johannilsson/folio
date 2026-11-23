import AppKit
import FolioKit

// Folio --mcp: the MCP server Claude desktop starts (src/mcp.rs). No windows, and nothing on stdout but the protocol.
if CommandLine.arguments.dropFirst().first == "--mcp" { exit(Rust.mcpServe()) }

// Folio [--dist <dir>] [--self-test [--only <areas>]] [--set <name> [--screenshot <png> [--appearance light|dark]]] [file.md ...]
// Finder and `open -a Folio file.md` open files through AppKit; naming them here is
// for running from a terminal.
var args = Array(CommandLine.arguments.dropFirst())
var files: [URL] = []

while !args.isEmpty {
    let arg = args.removeFirst()
    switch arg {
    case "--dist": AppConfig.dist = URL(fileURLWithPath: args.removeFirst())
    case "--self-test": AppConfig.selfTest = true
    case "--only": AppConfig.selfTestOnly = args.removeFirst()
    case "--set": AppConfig.openSet = args.removeFirst()
    case "--screenshot": AppConfig.screenshot = args.removeFirst()
    case "--appearance": AppConfig.appearance = args.removeFirst()
    // AppKit's own flags (and their values), e.g. -NSDocumentRevisionsDebugMode YES.
    case let flag where flag.hasPrefix("-"): _ = args.isEmpty ? nil : args.removeFirst()
    default: files.append(URL(fileURLWithPath: arg).standardizedFileURL)
    }
}

if AppConfig.selfTest && files.count != 1 {
    FileHandle.standardError.write(Data("usage: Folio --self-test [--only <areas>] <file.md>\n".utf8))
    exit(64)
}
if let only = AppConfig.selfTestOnly {
    let names = only.split(separator: ",").map(String.init)
    let unknown = names.filter { SelfTest.Area(rawValue: $0) == nil }
    if !unknown.isEmpty {
        let known = SelfTest.Area.allCases.map(\.rawValue).joined(separator: ", ")
        FileHandle.standardError.write(Data("unknown area \(unknown.joined(separator: ", ")); areas: \(known)\n".utf8))
        exit(64)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate(initialFiles: files)
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
