// swift-tools-version:6.0
import Foundation
import PackageDescription

// The Rust core (anchoring and accept) is linked into FolioKit as a static library:
//   cargo build --release   ->   <repo>/target/release/libfolio.a
let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let rustLib = repo.appendingPathComponent("target/release").path

// Info.plist is also embedded in the binary, so `swift run` (no .app around it) has the
// same bundle identity and document types as the packaged app.
let infoPlist = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Info.plist").path

let package = Package(
    name: "Folio",
    platforms: [.macOS("13.3")],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-markdown.git", from: "0.5.0"),
    ],
    targets: [
        .target(name: "CFolio"),
        // The app's logic: values in and out, no views (CLAUDE.md, "How the app is built").
        .target(
            name: "FolioKit",
            dependencies: ["CFolio"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .unsafeFlags(["-L", rustLib]),
                .linkedLibrary("folio"),
                // Pulled in by the file-watching and networking crates inside libfolio.
                .linkedFramework("CoreServices"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("Security"),
                .linkedLibrary("iconv"),
            ]
        ),
        .executableTarget(
            name: "Folio",
            dependencies: ["FolioKit", .product(name: "Markdown", package: "swift-markdown")],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", infoPlist]),
            ]
        ),
        .testTarget(name: "FolioKitTests", dependencies: ["FolioKit"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
