// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DockFolderCore",
    platforms: [.macOS(.v13)],
    products: [.library(name: "DockFolderCore", targets: ["DockFolderCore"])],
    targets: [
        .target(name: "DockFolderCore", path: "DockFolder", exclude: ["AboutView.swift", "AppDelegate.swift", "FolderStore.swift", "FolderView.swift", "InstanceManagerView.swift", "FolderSettingsView.swift", "Info.plist", "AppIcon.icns", "DefaultAppIcon.icns"], sources: ["ReleaseUpdate.swift", "Library.swift", "FolderInstance.swift", "InstanceCatalog.swift", "LoginItemSettings.swift", "DockIcon.swift"]),
        .testTarget(name: "DockFolderCoreTests", dependencies: ["DockFolderCore"], path: "Tests")
    ]
)
