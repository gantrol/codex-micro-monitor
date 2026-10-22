// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "MicroRemote",
    platforms: [
        .iOS(.v17),
        .macOS(.v13),
    ],
    products: [
        .library(name: "MicroRemote", targets: ["MicroRemote"]),
    ],
    targets: [
        .target(
            name: "MicroRemote",
            path: "Sources/MicroRemote",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
    ]
)
