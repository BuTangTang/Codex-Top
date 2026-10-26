// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CodexTop",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "CodexTop", targets: ["CodexTop"]),
        .library(name: "CodexTopCore", targets: ["CodexTopCore"]),
        .executable(name: "codex-top-inspect", targets: ["CodexTopInspect"])
    ],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "CZstd", exclude: ["PROVENANCE.md", "vendor/LICENSE", "vendor/COPYING"], sources: ["CZstd.c", "vendor/lib/common", "vendor/lib/decompress"], publicHeadersPath: "include", cSettings: [.define("ZSTD_DISABLE_ASM")]),
        .target(name: "CodexTopCore", dependencies: ["CSQLite", "CZstd"]),
        .executableTarget(name: "CodexTop", dependencies: ["CodexTopCore"]),
        .executableTarget(name: "CodexTopInspect", dependencies: ["CodexTopCore"]),
        .testTarget(name: "CodexTopCoreTests", dependencies: ["CodexTopCore", "CSQLite"]),
        .testTarget(name: "CodexTopTests", dependencies: ["CodexTop", "CodexTopCore", "CSQLite"])
    ]
)
