// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CodexTop",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CodexTopCore", targets: ["CodexTopCore"]),
        .executable(name: "codex-top-inspect", targets: ["CodexTopInspect"])
    ],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "CodexTopCore", dependencies: ["CSQLite"]),
        .executableTarget(name: "CodexTopInspect", dependencies: ["CodexTopCore"]),
        .testTarget(name: "CodexTopCoreTests", dependencies: ["CodexTopCore", "CSQLite"])
    ]
)
