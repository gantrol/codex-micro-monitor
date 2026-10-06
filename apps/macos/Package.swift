// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "CodexMicroMac",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [.library(name: "MicroDesktop", type: .dynamic, targets: ["MicroDesktop"])],
    dependencies: [.package(url: "https://github.com/jaywcjlove/PermissionFlow.git", exact: "2.11.3")],
    targets: [
        .target(name: "MicroCore", dependencies:["MicroShared"]),
        .target(name: "MicroShared"),
        .target(name: "MicroDesktop", dependencies: ["MicroCore", "MicroShared", .product(name: "SystemSettingsKit", package: "PermissionFlow")],
                linkerSettings: [.linkedFramework("AppKit")]),
        .target(name: "MicroPanelModel", dependencies: ["MicroShared"], path: "Sources/CodexMicroMac",
                exclude: ["Resources", "KeycapGlyph.swift", "Entry.swift", "MicroArtwork.generated.swift", "MicroView.swift", "SettingsView.swift", "MicroSurfaces.swift", "ReasoningGlyph.swift", "DesignExport.swift", "SevenSegmentReadout.swift", "DialInput.swift"],
                sources: ["Settings.swift", "ControlModels.swift", "DesktopClient.swift", "MicroModel.swift", "MicroSession.swift", "MicroViewModel.swift", "PanelModels.swift", "ConversationContextStore.swift", "ActivityStore.swift", "ObservationCoordinator.swift", "ServiceConnectionState.swift", "CommandExecutor.swift", "Localization.swift", "DialMapping.swift"]),
        .testTarget(name: "MicroCoreTests", dependencies: ["MicroCore", "MicroDesktop", "MicroPanelModel"])
    ]
)
