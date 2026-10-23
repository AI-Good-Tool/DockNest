import Foundation
import Testing
@testable import DockFolderCore

@Test func recoversTrashedEntryWithoutChangingShortcutsOrIdentity() throws {
    let (temp, source) = try fixture()
    defer { try? FileManager.default.removeItem(at: temp) }
    let catalog = InstanceCatalog(dataRoot: temp.appendingPathComponent("Data"), applications: temp.appendingPathComponent("Apps"))
    let entry = AppEntry(name: "保留的应用", path: "/Applications/Keep.app")
    let original = try FolderInstance.create(name: "浏览器", apps: [entry], source: source, directory: catalog.applications, dataRoot: catalog.dataRoot)
    let before = try #require(catalog.list(includeSystem: false).first)
    let storageURL = try catalog.dataDirectory(before.id).appendingPathComponent("library.json")
    let saved = try Data(contentsOf: storageURL)
    let trash = temp.appendingPathComponent(".Trash")
    try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
    try FileManager.default.moveItem(at: original, to: trash.appendingPathComponent(original.lastPathComponent))
    let missing = try #require(catalog.list(includeSystem: false).first)
    #expect(missing.needsRecovery)
    // A different folder may already be using the original name. Never overwrite it.
    let other = try FolderInstance.create(name: "浏览器", source: source, directory: catalog.applications, dataRoot: catalog.dataRoot)
    let otherBytes = try Data(contentsOf: other.appendingPathComponent("Contents/Info.plist"))
    let recovered = try catalog.recover(missing, source: source)
    #expect(recovered != other)
    #expect(InstanceCatalog.owns(recovered, id: before.id))
    #expect(try Data(contentsOf: storageURL) == saved)
    #expect(try Data(contentsOf: other.appendingPathComponent("Contents/Info.plist")) == otherBytes)
    #expect(try LibraryStorage(url: storageURL).load().folders[0].apps == [entry])
}

@Test func deletesOnlySelectedInstanceIncludingRenameBackups() throws {
    let (temp, source) = try fixture()
    defer { try? FileManager.default.removeItem(at: temp) }
    let catalog = InstanceCatalog(dataRoot: temp.appendingPathComponent("Data"), applications: temp.appendingPathComponent("Apps"))
    _ = try FolderInstance.create(name: "删除目标", source: source, directory: catalog.applications, dataRoot: catalog.dataRoot)
    let keepURL = try FolderInstance.create(name: "保留目标", source: source, directory: catalog.applications, dataRoot: catalog.dataRoot)
    let records = try catalog.list(includeSystem: false)
    let target = try #require(records.first { $0.name == "删除目标" })
    let keep = try #require(records.first { $0.name == "保留目标" })
    let backup = catalog.dataRoot.appendingPathComponent("Renames/\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
    let request = FolderInstance.RenameRequest(parentPID: Int32.max, source: source, destination: source, stagedBundle: source,
        storage: try catalog.dataDirectory(target.id).appendingPathComponent("library.json"), name: target.name)
    try JSONEncoder().encode(request).write(to: backup.appendingPathComponent("request.json"))
    #expect(throws: (any Error).self) { try catalog.delete(target, protecting: target.id, includeSystem: false) }
    try catalog.delete(target, protecting: keep.id, includeSystem: false)
    #expect(!FileManager.default.fileExists(atPath: try catalog.dataDirectory(target.id).path))
    #expect(!FileManager.default.fileExists(atPath: backup.path))
    #expect(FileManager.default.fileExists(atPath: keepURL.path))
    #expect(try catalog.list(includeSystem: false).map(\.id) == [keep.id])
}

@Test func corruptDataRemainsVisibleAndCannotBeSilentlyRestored() throws {
    let (temp, source) = try fixture()
    defer { try? FileManager.default.removeItem(at: temp) }
    let catalog = InstanceCatalog(dataRoot: temp.appendingPathComponent("Data"), applications: temp.appendingPathComponent("Apps"))
    _ = try FolderInstance.create(name: "损坏列表", source: source, directory: catalog.applications, dataRoot: catalog.dataRoot)
    let record = try #require(catalog.list(includeSystem: false).first)
    let url = try catalog.dataDirectory(record.id).appendingPathComponent("library.json")
    let corrupt = Data("not-json".utf8)
    try corrupt.write(to: url)
    let damaged = try #require(catalog.list(includeSystem: false).first)
    #expect(damaged.dataError != nil)
    #expect(throws: (any Error).self) { try catalog.recover(damaged, source: source) }
    #expect(try Data(contentsOf: url) == corrupt)
}

@Test func rejectsTraversalAndForeignBundleDeletion() throws {
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: temp) }
    let catalog = InstanceCatalog(dataRoot: temp)
    #expect(throws: (any Error).self) { try catalog.dataDirectory("../../Applications") }
    let id = UUID().uuidString
    #expect(!InstanceCatalog.owns(URL(fileURLWithPath: "/Applications/Safari.app"), id: id))
    let protected = ManagedFolder(id: "default", name: "主入口", count: 0, appURL: nil, dataError: nil)
    #expect(throws: (any Error).self) { try catalog.delete(protected, protecting: id, includeSystem: false) }
}

@Test func upgradesStaleCopiesOfTheSameIdentityInPlace() throws {
    let (temp, source) = try fixture()
    defer { try? FileManager.default.removeItem(at: temp) }
    let catalog = InstanceCatalog(dataRoot: temp.appendingPathComponent("Data"), applications: temp.appendingPathComponent("Apps"))
    let entry = AppEntry(name: "原应用", path: "/Applications/Keep.app")
    let old = try FolderInstance.create(name: "远程工具", apps: [entry], source: source, directory: catalog.applications, dataRoot: catalog.dataRoot)
    let record = try #require(catalog.list(includeSystem: false).first)
    let fresh = temp.appendingPathComponent("Installed/DockFolder.app")
    try FileManager.default.createDirectory(at: fresh.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: old, to: fresh)
    let infoURL = fresh.appendingPathComponent("Contents/Info.plist")
    var info = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: infoURL), format: nil) as? [String: Any])
    info["CFBundleVersion"] = "999"
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: infoURL)
    let stale = catalog.staleCopies(of: record.id, source: fresh, includeSystem: false)
    #expect(stale.map { $0.resolvingSymlinksInPath().path } == [old.resolvingSymlinksInPath().path])
    try catalog.upgradeStaleCopies(of: record.id, source: fresh, includeSystem: false)
    #expect(InstanceCatalog.bundleVersion(old).build == 999)
    #expect(InstanceCatalog.owns(old, id: record.id))
    #expect(catalog.staleCopies(of: record.id, source: fresh, includeSystem: false).isEmpty)
    let library = try LibraryStorage(url: catalog.dataDirectory(record.id).appendingPathComponent("library.json")).load()
    #expect(library.folders[0].apps == [entry])
    #expect(library.folders[0].name == "远程工具")
    #expect(catalog.otherCopies(of: record.id, source: fresh, includeSystem: false).count == 1)
    // 只保留 old；fresh 不在安装目录内，不会被移走
    try catalog.trashOtherCopies(of: record.id, source: old, includeSystem: false)
    #expect(FileManager.default.fileExists(atPath: old.path))
    #expect(FileManager.default.fileExists(atPath: fresh.path))
    let keep = try catalog.dataDirectory(record.id).appendingPathComponent("library.json")
    #expect(try LibraryStorage(url: keep).load().folders[0].apps == [entry])
}

@Test func upgradesOldEntryPreservingItsDataAndIdentity() throws {
    let (temp, source) = try fixture()
    defer { try? FileManager.default.removeItem(at: temp) }
    let catalog = InstanceCatalog(dataRoot: temp.appendingPathComponent("Data"), applications: temp.appendingPathComponent("Apps"))
    let entry = AppEntry(name: "原应用", path: "/Applications/Keep.app")
    let target = try FolderInstance.create(name: "原文件夹", apps: [entry], source: source, directory: catalog.applications, dataRoot: catalog.dataRoot)
    let record = try #require(catalog.list(includeSystem: false).first)
    let infoURL = source.appendingPathComponent("Contents/Info.plist")
    var info = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: infoURL), format: nil) as? [String: Any])
    info["CFBundleVersion"] = "999"
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: infoURL)
    #expect(throws: (any Error).self) { try catalog.upgrade(record, protecting: record.id, source: source, relaunch: false) }
    let duplicate = catalog.applications.appendingPathComponent("另一份副本.app")
    try FileManager.default.copyItem(at: target, to: duplicate)
    try catalog.register(duplicate, id: record.id)
    try catalog.upgrade(record, protecting: "default", source: source, relaunch: false)
    let duplicateInfo = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: duplicate.appendingPathComponent("Contents/Info.plist")), format: nil) as? [String: Any])
    #expect(duplicateInfo["CFBundleVersion"] == nil)
    let updated = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: target.appendingPathComponent("Contents/Info.plist")), format: nil) as? [String: Any])
    #expect(updated["CFBundleVersion"] as? String == "999")
    #expect(updated["DockFolderInstanceID"] as? String == record.id)
    let library = try LibraryStorage(url: catalog.dataDirectory(record.id).appendingPathComponent("library.json")).load()
    #expect(library.folders[0].apps == [entry])
    #expect(library.folders[0].name == "原文件夹")
}
