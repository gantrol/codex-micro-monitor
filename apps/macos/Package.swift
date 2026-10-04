// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "CodexMicroMac",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [.library(name: "MicroDesktop", type: .dynamic, targets: ["MicroDesktop"])],
    targets: [
        .target(name: "MicroCore"),
        .target(name: "MicroShared"),
        .target(name: "MicroDesktop", dependencies: ["MicroCore", "MicroShared"],
                linkerSettings: [.linkedFramework("AppKit")])
    ]
)
