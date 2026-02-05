// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "StashMacOSApp",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "StashMacOSApp", targets: ["StashMacOSApp"])
    ],
    targets: [
        .executableTarget(
            name: "StashMacOSApp",
            path: "Sources/StashMacOSApp"
        )
    ]
)
