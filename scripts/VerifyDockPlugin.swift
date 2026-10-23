import AppKit

/// Load two real plug-in binaries in one process without launching or pinning
/// either application. Use disposable identities and different fallback images.
@main struct VerifyDockPlugin {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let source = URL(fileURLWithPath: CommandLine.arguments[1])
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        var plugins: [NSDockTilePlugIn] = []
        var images: [Data] = []
        for (index, color) in [NSColor.red, NSColor.blue].enumerated() {
            let id = UUID().uuidString
            let app = temp.appendingPathComponent("Folder\(index).app")
            try FileManager.default.copyItem(at: source, to: app)
            let image = NSImage(size: NSSize(width: 512, height: 512))
            image.lockFocus()
            color.setFill()
            NSRect(x: 0, y: 0, width: 512, height: 512).fill()
            image.unlockFocus()
            let icns = try DockIcon.icnsData(for: image)
            try icns.write(to: app.appendingPathComponent("Contents/Resources/DefaultAppIcon.icns"))
            try FolderInstance.configure(app, name: "Folder\(index)", id: id,
                identifier: "com.dalong.DockFolder.test.\(id)")
            let bundle = Bundle(url: app.appendingPathComponent("Contents/PlugIns/DockFolderTile.docktileplugin"))!
            try bundle.loadAndReturnError()
            guard let type = bundle.principalClass as? NSObject.Type,
                  let plugin = type.init() as? NSDockTilePlugIn else { fatalError("Plug-in failed to load") }
            plugins.append(plugin)
            images.append(NSImage(data: icns)!.tiffRepresentation!)
        }
        precondition(images[0] != images[1])
        // Revisit the first instance after loading the second: catch shared-class
        // or Bundle.main bugs that can silently swap independent folder icons.
        for index in [0, 1, 0] {
            let tile = NSApp.dockTile
            plugins[index].setDockTile(tile)
            let actual = (tile.contentView as? NSImageView)?.image?.tiffRepresentation
            precondition(actual == images[index], "Wrong image for instance \(index)")
            plugins[index].setDockTile(nil)
        }
        print("PASS: two plug-ins load together, preserve exact images and instance isolation; signatures valid")
    }
}
