// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Folio",
    platforms: [.macOS("13.3")],
    targets: [
        .executableTarget(
            name: "Folio",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
