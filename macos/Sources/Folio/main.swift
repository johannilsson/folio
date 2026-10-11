import AppKit

// Folio [--dist <dir>] [--self-test] [--set <name> [--screenshot <png> [--appearance light|dark]]] [file.md ...]
// Finder and `open -a Folio file.md` open files through AppKit; naming them here is
// for running from a terminal.
var args = Array(CommandLine.arguments.dropFirst())
var files: [URL] = []

while !args.isEmpty {
    let arg = args.removeFirst()
    switch arg {
    case "--dist": AppConfig.dist = URL(fileURLWithPath: args.removeFirst())
    case "--self-test": AppConfig.selfTest = true
    case "--set": AppConfig.openSet = args.removeFirst()
    case "--screenshot": AppConfig.screenshot = args.removeFirst()
    case "--appearance": AppConfig.appearance = args.removeFirst()
    // AppKit's own flags (and their values), e.g. -NSDocumentRevisionsDebugMode YES.
    case let flag where flag.hasPrefix("-"): _ = args.isEmpty ? nil : args.removeFirst()
    default: files.append(URL(fileURLWithPath: arg).standardizedFileURL)
    }
}

if AppConfig.selfTest && files.count != 1 {
    FileHandle.standardError.write(Data("usage: Folio --self-test <file.md>\n".utf8))
    exit(64)
}

let app = NSApplication.shared
let delegate = AppDelegate(initialFiles: files)
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
