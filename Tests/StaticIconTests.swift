import AppKit
import Testing
@testable import DockFolderCore

@Test @MainActor func icnsContainsReadableMultiResolutionComposite() throws {
    let icon = DockIcon.render(icons: [NSWorkspace.shared.icon(forFile: "/Applications/Safari.app")])
    let data = try DockIcon.icnsData(for: icon)
    #expect(data.prefix(4) == Data("icns".utf8))
    #expect(NSImage(data: data) != nil)
    var offset = 8
    var chunks: [String] = []
    while offset + 8 <= data.count {
        chunks.append(String(data: data[offset..<(offset + 4)], encoding: .ascii)!)
        let length = data[(offset + 4)..<(offset + 8)].reduce(0) { ($0 << 8) | Int($1) }
        #expect(length > 8)
        #expect(NSBitmapImageRep(data: data[(offset + 8)..<(offset + length)]) != nil)
        offset += length
    }
    #expect(offset == data.count)
    #expect(chunks == ["icp4", "icp5", "icp6", "ic07", "ic08", "ic09", "ic10"])
}

@Test @MainActor func staticIconUpdatePreservesLibraryIdentityAndValidSignature() throws {
    let (temp, source) = try fixture()
    defer { try? FileManager.default.removeItem(at: temp) }
    let app = try FolderInstance.create(name: "静态图标", apps: [AppEntry(name: "保留应用", path: "/Keep.app")],
        source: source, directory: temp.appendingPathComponent("Apps"), dataRoot: temp)
    let id = try #require(Bundle(url: app)?.object(forInfoDictionaryKey: "DockFolderInstanceID") as? String)
    let storage = temp.appendingPathComponent("Instances/\(id)/library.json")
    let before = try Data(contentsOf: storage)
    let staged = temp.appendingPathComponent("Prepared.app")
    try FileManager.default.copyItem(at: app, to: staged)
    let resources = staged.appendingPathComponent("Contents/Resources")
    try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
    let icon = try DockIcon.icnsData(for: DockIcon.render())
    try icon.write(to: resources.appendingPathComponent("AppIcon.icns"))
    try FolderInstance.run("/usr/bin/codesign", ["--force", "--sign", "-", staged.path])
    let request = FolderInstance.RenameRequest(parentPID: Int32.max, source: app, destination: app,
        stagedBundle: staged, storage: storage, name: "不应修改名称", iconOnly: true)
    let requestURL = temp.appendingPathComponent("request.json")
    try JSONEncoder().encode(request).write(to: requestURL)
    let marker = storage.deletingLastPathComponent().appendingPathComponent("icon-update.pending")
    try Data(requestURL.path.utf8).write(to: marker)
    try FolderInstance.finishRename(requestURL: requestURL)
    #expect(try Data(contentsOf: app.appendingPathComponent("Contents/Resources/AppIcon.icns")) == icon)
    #expect(try Data(contentsOf: storage) == before)
    #expect(!FileManager.default.fileExists(atPath: marker.path))
    #expect(InstanceCatalog.owns(app, id: id))
    try FolderInstance.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
}
