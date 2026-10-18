// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClipboardPlatformTests",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "Packages/ClipboardCore")],
    targets: [
        .target(name: "ClipboardPlatform", dependencies: [.product(name: "ClipboardCore", package: "ClipboardCore")], path: "ClipboardApp", exclude: ["Info.plist", "AppDelegate.swift", "main.swift", "GlobalShortcut.swift"], sources: ["ClipboardMonitor.swift", "PasteCoordinator.swift", "HistoryWindowController.swift", "SettingsStore.swift", "SettingsWindowController.swift", "UIHelpers.swift"]),
        .testTarget(name: "ClipboardPlatformTests", dependencies: ["ClipboardPlatform", .product(name: "ClipboardCore", package: "ClipboardCore")], path: "Tests/PlatformTests")
    ]
)
