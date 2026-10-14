// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "macfan",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "macfan",
            path: "Sources/macfan",
            linkerSettings: [.linkedFramework("IOKit")]
        )
    ]
)
