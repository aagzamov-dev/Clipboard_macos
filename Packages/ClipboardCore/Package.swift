// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClipboardCore",
    platforms: [.macOS(.v14)],
    products: [.library(name: "ClipboardCore", targets: ["ClipboardCore"])],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "ClipboardCore", dependencies: ["CSQLite"]),
        .testTarget(name: "ClipboardCoreTests", dependencies: ["ClipboardCore", "CSQLite"])
    ]
)
