import Foundation
import Testing
@testable import DockFolderCore

@Test func folderNamesRejectPathsAndKeepChinese() throws {
    #expect(try FolderInstance.validatedName("  开发工具  ") == "开发工具")
    for name in ["", "  ", "../Other", "a/b", "a:b", ".hidden", "bad\nname", String(repeating: "猫", count: 41)] {
        #expect(throws: (any Error).self) { try FolderInstance.validatedName(name) }
    }
}

func fixture() throws -> (URL, URL) {
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent("DockFolderTests-\(UUID().uuidString)")
    let source = temp.appendingPathComponent("Source.app")
    try FileManager.default.createDirectory(at: source.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/echo"), to: source.appendingPathComponent("Contents/MacOS/Fixture"))
    let info: [String: Any] = ["CFBundleExecutable": "Fixture", "CFBundleName": "Fixture", "CFBundleIdentifier": "com.dalong.DockFolder.test", "CFBundlePackageType": "APPL"]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: source.appendingPathComponent("Contents/Info.plist"))
    return (temp, source)
}

@Test func independentAppsHaveDistinctIdentityAndPersistentData() throws {
    let (temp, source) = try fixture()
    defer { try? FileManager.default.removeItem(at: temp) }
    let apps = temp.appendingPathComponent("Applications")
    let data = temp.appendingPathComponent("Data")
    let entry = AppEntry(name: "Safari", path: "/Applications/Safari.app")
    let a = try FolderInstance.create(name: "工作", apps: [entry], source: source, directory: apps, dataRoot: data)
    let b = try FolderInstance.create(name: "生活", source: source, directory: apps, dataRoot: data)
    let ba = try #require(Bundle(url: a))
    let bb = try #require(Bundle(url: b))
    #expect(ba.bundleIdentifier != bb.bundleIdentifier)
    let aID = try #require(ba.object(forInfoDictionaryKey: "DockFolderInstanceID") as? String)
    let bID = try #require(bb.object(forInfoDictionaryKey: "DockFolderInstanceID") as? String)
    let aStorage = LibraryStorage(url: data.appendingPathComponent("Instances/\(aID)/library.json"))
    let bStorage = LibraryStorage(url: data.appendingPathComponent("Instances/\(bID)/library.json"))
    #expect(try aStorage.load().folders[0].apps == [entry])
    #expect(try bStorage.load().folders[0].apps.isEmpty)
    #expect(throws: (any Error).self) { try FolderInstance.create(name: "工作", source: source, directory: apps, dataRoot: data) }
    #expect(try aStorage.load().folders[0].apps == [entry])
}

@Test func renamePreservesBundleIdentityDataAndDirectoryInode() throws {
    let (temp, source) = try fixture()
    defer { try? FileManager.default.removeItem(at: temp) }
    let app = try FolderInstance.create(name: "旧名字", source: source, directory: temp.appendingPathComponent("Apps"), dataRoot: temp)
    let bundle = try #require(Bundle(url: app))
    let id = try #require(bundle.object(forInfoDictionaryKey: "DockFolderInstanceID") as? String)
    let identifier = try #require(bundle.bundleIdentifier)
    let staged = temp.appendingPathComponent("Prepared.app")
    try FileManager.default.copyItem(at: app, to: staged)
    try FolderInstance.configure(staged, name: "新名字", id: id, identifier: identifier)
    let newURL = app.deletingLastPathComponent().appendingPathComponent("新名字.app")
    let storage = FolderInstance.RenameRequest(parentPID: Int32.max, source: app, destination: newURL, stagedBundle: staged,
                                              storage: temp.appendingPathComponent("Instances/\(id)/library.json"), name: "新名字")
    let inode = try FileManager.default.attributesOfItem(atPath: app.path)[.systemFileNumber] as? NSNumber
    let request = temp.appendingPathComponent("request.json")
    try JSONEncoder().encode(storage).write(to: request)
    try FolderInstance.finishRename(requestURL: request, relaunch: false)
    #expect(try FileManager.default.attributesOfItem(atPath: newURL.path)[.systemFileNumber] as? NSNumber == inode)
    #expect(Bundle(url: newURL)?.bundleIdentifier == identifier)
    #expect(try LibraryStorage(url: storage.storage).load().folders[0].name == "新名字")
    try FolderInstance.run("/usr/bin/codesign", ["--verify", "--strict", newURL.path])
}

@Test func failedRenameRestoresOriginalBundleAndData() throws {
    let (temp, source) = try fixture()
    defer { try? FileManager.default.removeItem(at: temp) }
    let app = try FolderInstance.create(name: "保留原名", source: source, directory: temp.appendingPathComponent("Apps"), dataRoot: temp)
    let id = try #require(Bundle(url: app)?.object(forInfoDictionaryKey: "DockFolderInstanceID") as? String)
    let dataURL = temp.appendingPathComponent("Instances/\(id)/library.json")
    let before = try Data(contentsOf: dataURL)
    let request = FolderInstance.RenameRequest(parentPID: Int32.max, source: app,
        destination: app.deletingLastPathComponent().appendingPathComponent("不可用.app"),
        stagedBundle: temp.appendingPathComponent("Missing.app"), storage: dataURL, name: "不可用")
    let url = temp.appendingPathComponent("request.json")
    try JSONEncoder().encode(request).write(to: url)
    #expect(throws: (any Error).self) { try FolderInstance.finishRename(requestURL: url, relaunch: false) }
    #expect(FileManager.default.fileExists(atPath: app.appendingPathComponent("Contents/Info.plist").path))
    #expect(try Data(contentsOf: dataURL) == before)
    try FolderInstance.run("/usr/bin/codesign", ["--verify", "--strict", app.path])
}
