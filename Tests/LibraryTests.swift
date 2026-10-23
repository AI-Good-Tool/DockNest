import Foundation
import Testing
@testable import DockFolderCore

@Test func duplicateAppsAreIgnoredWithinEachFolder() {
    var library = FolderLibrary()
    let id = library.folders[0].id
    let app = AppEntry(name: "Safari", path: "/Applications/Safari.app")
    let firstAdded = library.add(app, to: id)
    let duplicateAdded = library.add(AppEntry(name: "Safari", path: app.path), to: id)
    #expect(firstAdded)
    #expect(!duplicateAdded)
    #expect(library.folders[0].apps.count == 1)
    library.folders.append(AppFolder(name: "工作"))
    let otherFolderAdded = library.add(app, to: library.folders[1].id)
    #expect(otherFolderAdded)
}

@Test func movingIntoFolderWithSameAppDoesNotDuplicate() {
    var library = FolderLibrary()
    library.folders.append(AppFolder(name: "工作"))
    let app = AppEntry(name: "Safari", path: "/Applications/Safari.app")
    let source = library.folders[0].id
    let target = library.folders[1].id
    library.add(app, to: source)
    library.add(AppEntry(name: app.name, path: app.path), to: target)
    library.move(app.id, from: source, to: target)
    #expect(library.folders[0].apps.isEmpty)
    #expect(library.folders[1].apps.count == 1)
}

@Test func invalidMovePreservesSource() {
    var library = FolderLibrary()
    let app = AppEntry(name: "Safari", path: "/Applications/Safari.app")
    library.add(app, to: library.folders[0].id)
    library.move(app.id, from: library.folders[0].id, to: UUID())
    #expect(library.folders[0].apps == [app])
}

@Test func reorderFollowsGivenOrderAndKeepsUnlistedApps() {
    var library = FolderLibrary()
    let id = library.folders[0].id
    let apps = ["A", "B", "C", "D"].map { AppEntry(name: $0, path: "/Applications/\($0).app") }
    apps.forEach { library.add($0, to: id) }
    library.reorder([apps[2].id, UUID(), apps[0].id], in: id)
    #expect(library.folders[0].apps.map(\.name) == ["C", "A", "B", "D"])
    library.reorder([apps[3].id], in: UUID())
    #expect(library.folders[0].apps.map(\.name) == ["C", "A", "B", "D"])
}

@Test func backupRoundTripAndLibraryFileImport() throws {
    let apps = [AppEntry(name: "中文应用", path: "/Applications/中文应用.app", bundleIdentifier: "com.example.cn", bookmark: Data([1, 2]))]
    let backup = FolderBackup(exportedAt: Date(timeIntervalSince1970: 1_700_000_000), name: "AI编辑器", apps: apps)
    #expect(try FolderBackup.decode(backup.encoded()) == backup)
    let library = FolderLibrary(folders: [AppFolder(name: "远程工具", apps: apps)])
    let fromLibrary = try FolderBackup.decode(JSONEncoder().encode(library))
    #expect(fromLibrary.name == "远程工具")
    #expect(fromLibrary.apps == apps)
    #expect(throws: (any Error).self) { try FolderBackup.decode(Data("{\"format\":\"Other\"}".utf8)) }
    var future = backup
    future.version = 2
    #expect(throws: (any Error).self) { try FolderBackup.decode(future.encoded()) }
}

@Test func importMergesWithoutDuplicatesOrReplacesInBackupOrder() {
    var library = FolderLibrary()
    let id = library.folders[0].id
    let a = AppEntry(name: "A", path: "/Applications/A.app")
    let b = AppEntry(name: "B", path: "/Applications/B.app")
    let c = AppEntry(name: "C", path: "/Applications/C.app")
    library.add(a, to: id)
    library.add(b, to: id)
    let backup = [c, AppEntry(name: "A", path: a.path)]
    #expect(library.importApps(backup, into: id, replacing: false) == 1)
    #expect(library.folders[0].apps.map(\.name) == ["A", "B", "C"])
    #expect(library.importApps(backup, into: id, replacing: true) == 2)
    #expect(library.folders[0].apps.map(\.name) == ["C", "A"])
}

@Test func removingSelectedFolderSelectsSurvivorAndKeepsLastFolder() {
    var library = FolderLibrary()
    let folder = AppFolder(name: "工作")
    library.folders.append(folder)
    library.selectedFolderID = folder.id
    library.removeFolder(folder.id)
    #expect(library.selectedFolderID == library.folders[0].id)
    library.removeFolder(library.folders[0].id)
    #expect(library.folders.count == 1)
}

@Test func emptyLibraryRecovers() {
    var library = FolderLibrary(folders: [], selectedFolderID: UUID())
    library.normalize()
    #expect(library.folders.count == 1)
    #expect(library.selectedFolderID == library.folders[0].id)
}

@Test func persistenceRoundTripAndCorruptionPreservation() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let storage = LibraryStorage(url: directory.appendingPathComponent("library.json"))
    var library = try storage.load()
    library.add(AppEntry(name: "中文应用", path: "/Applications/中文应用.app", bookmark: Data([1, 2, 3])), to: library.folders[0].id)
    try storage.save(library)
    #expect(try storage.load() == library)
    let broken = Data("broken-json".utf8)
    try broken.write(to: storage.url)
    #expect(throws: (any Error).self) { try storage.load() }
    #expect(try Data(contentsOf: storage.url) == broken)
}
