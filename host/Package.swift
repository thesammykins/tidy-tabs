// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "TidyTabsHost",
    // FoundationModels (Apple Intelligence's on-device model) needs macOS 26.
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(name: "TidyTabsHost"),
        .testTarget(name: "TidyTabsHostTests", dependencies: ["TidyTabsHost"]),
    ]
)
