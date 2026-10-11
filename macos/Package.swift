// swift-tools-version:6.0
import Foundation
import PackageDescription

// The Rust core (anchoring and accept) is linked as a static library:
//   cargo build --release   ->   <repo>/target/release/libfolio.a
let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let rustLib = repo.appendingPathComponent("target/release").path

let package = Package(
    name: "Folio",
    platforms: [.macOS("13.3")],
    targets: [
        .target(name: "CFolio"),
        .executableTarget(
            name: "Folio",
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
    ]
)
