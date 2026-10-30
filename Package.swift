// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Mixo",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "Mixo",
            path: "Sources/Mixo",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
