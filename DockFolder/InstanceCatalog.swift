import AppKit
import CoreServices

struct ManagedFolder: Identifiable {
    let id: String
    let name: String
    let count: Int?
    let appURL: URL?
    let dataError: String?
    var version: String? = nil
    var build: Int? = nil
    var needsRecovery: Bool { appURL == nil || InstanceCatalog.isInTrash(appURL!) }
    var isOutdated: Bool {
        guard let build, let current = InstanceCatalog.currentBuild else { return false }
        return build < current
    }
}

/// Per-instance registration avoids a shared index that concurrent folders could overwrite.
struct InstanceCatalog {
    var dataRoot = FolderInstance.support
    var applications = FolderInstance.applications

    struct Registration: Codable {
        var path: String
        var bookmark: Data?
    }

    static func isValidID(_ id: String) -> Bool { id == FolderInstance.rootID || UUID(uuidString: id) != nil }
    static func identifier(_ id: String) -> String {
        id == FolderInstance.rootID ? "com.dalong.DockFolder" : "com.dalong.DockFolder.instance.\(id)"
    }
    static func isInTrash(_ url: URL) -> Bool {
        url.pathComponents.contains(".Trash") || url.pathComponents.contains(".Trashes")
    }
    static var currentBuild: Int? { (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String).flatMap { Int($0) } }
    /// 直接读 Info.plist，避免 Bundle 缓存导致更新后仍读到旧版本
    static func bundleVersion(_ url: URL) -> (version: String?, build: Int?) {
        guard let info = try? PropertyListSerialization.propertyList(from: Data(contentsOf: url.appendingPathComponent("Contents/Info.plist")), format: nil) as? [String: Any] else { return (nil, nil) }
        return (info["CFBundleShortVersionString"] as? String, (info["CFBundleVersion"] as? String).flatMap { Int($0) })
    }
    static func owns(_ url: URL, id: String) -> Bool {
        guard isValidID(id), url.pathExtension == "app",
              let info = try? PropertyListSerialization.propertyList(from: Data(contentsOf: url.appendingPathComponent("Contents/Info.plist")), format: nil) as? [String: Any] else { return false }
        return info["CFBundleIdentifier"] as? String == identifier(id)
            && (info["DockFolderInstanceID"] as? String ?? FolderInstance.rootID) == id
    }
    func dataDirectory(_ id: String) throws -> URL {
        guard Self.isValidID(id) else { throw FolderInstance.failure("无效的文件夹标识。") }
        let url = dataRoot.appendingPathComponent("Instances/\(id)")
        guard url.resolvingSymlinksInPath().deletingLastPathComponent() == dataRoot.appendingPathComponent("Instances").resolvingSymlinksInPath() else {
            throw FolderInstance.failure("数据目录不能指向其他位置。")
        }
        return url
    }
    func register(_ url: URL, id: String) throws {
        guard Self.owns(url, id: id) else { throw FolderInstance.failure("应用身份不匹配。") }
        let directory = try dataDirectory(id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let record = Registration(path: url.path, bookmark: try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil))
        try JSONEncoder().encode(record).write(to: directory.appendingPathComponent("app.json"), options: .atomic)
    }
    func candidates(_ id: String, includeSystem: Bool = true) -> [URL] {
        var urls: [URL] = []
        if let directory = try? dataDirectory(id),
           let data = try? Data(contentsOf: directory.appendingPathComponent("app.json")),
           let record = try? JSONDecoder().decode(Registration.self, from: data) {
            urls.append(URL(fileURLWithPath: record.path))
            if let bookmark = record.bookmark {
                var stale = false
                if let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale) { urls.append(url) }
            }
        }
        if includeSystem {
            urls += NSRunningApplication.runningApplications(withBundleIdentifier: Self.identifier(id)).compactMap(\.bundleURL)
            urls += NSWorkspace.shared.urlsForApplications(withBundleIdentifier: Self.identifier(id))
            if FolderInstance.id == id { urls.insert(Bundle.main.bundleURL, at: 0) }
        }
        urls += (try? FileManager.default.contentsOfDirectory(at: applications, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        var seen = Set<String>()
        return urls.filter { Self.owns($0, id: id) && seen.insert($0.standardizedFileURL.path).inserted }
    }
    func list(includeSystem: Bool = true) throws -> [ManagedFolder] {
        let root = dataRoot.appendingPathComponent("Instances")
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            .filter { Self.isValidID($0.lastPathComponent) }
            .map { try record(in: $0, includeSystem: includeSystem) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func record(in directory: URL, includeSystem: Bool) throws -> ManagedFolder {
        let id = directory.lastPathComponent
        _ = try dataDirectory(id)
        let urls = candidates(id, includeSystem: includeSystem)
        let app = urls.first { !Self.isInTrash($0) } ?? urls.first
        var record: ManagedFolder
        do {
            let libraryURL = directory.appendingPathComponent("library.json")
            guard FileManager.default.fileExists(atPath: libraryURL.path) else { throw FolderInstance.failure("应用列表文件缺失") }
            let library = try LibraryStorage(url: libraryURL).load()
            let folder = library.folders[library.selectedIndex]
            record = ManagedFolder(id: id, name: folder.name, count: folder.apps.count, appURL: app, dataError: nil)
        } catch {
            record = ManagedFolder(id: id, name: app?.deletingPathExtension().lastPathComponent ?? "无法读取的文件夹", count: nil, appURL: app,
                                   dataError: error.localizedDescription)
        }
        if let app { (record.version, record.build) = Self.bundleVersion(app) }
        return record
    }

    /// Recreate the executable only. The identity and all saved shortcuts remain unchanged.
    func recover(_ record: ManagedFolder, source: URL = Bundle.main.bundleURL) throws -> URL {
        let directory = try dataDirectory(record.id)
        guard record.dataError == nil else { throw FolderInstance.failure("数据读取失败，请先修复数据，不能用空列表覆盖。") }
        let data = try LibraryStorage(url: directory.appendingPathComponent("library.json")).load()
        let name = try FolderInstance.validatedName(data.folders[data.selectedIndex].name)
        if let available = candidates(record.id).first(where: { !Self.isInTrash($0) }) { return available }
        try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
        var destination = applications.appendingPathComponent(name + ".app")
        var suffix = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = applications.appendingPathComponent("\(name) (\(suffix)).app")
            suffix += 1
        }
        let stage = applications.appendingPathComponent(".restore-\(UUID().uuidString).app")
        do {
            try FileManager.default.copyItem(at: source, to: stage)
            try FolderInstance.configure(stage, name: name, id: record.id, identifier: Self.identifier(record.id))
            try FileManager.default.moveItem(at: stage, to: destination)
            try register(destination, id: record.id)
            LSRegisterURL(destination as CFURL, true)
            return destination
        } catch {
            try? FileManager.default.removeItem(at: stage)
            throw error
        }
    }

    /// Upgrade older independent copies to the version installed by the DMG.
    func upgrade(_ record: ManagedFolder, protecting currentID: String, source: URL = Bundle.main.bundleURL, relaunch: Bool = true) throws {
        guard record.id != currentID else { throw FolderInstance.failure("当前入口正在运行，请从另一个新版入口进行更新。") }
        let selected = record.appURL.flatMap { Self.owns($0, id: record.id) && !Self.isInTrash($0) ? $0 : nil }
        guard let target = selected ?? candidates(record.id).first(where: { !Self.isInTrash($0) }) else {
            throw FolderInstance.failure("入口已丢失，请使用恢复并打开。")
        }
        guard NSRunningApplication.runningApplications(withBundleIdentifier: Self.identifier(record.id)).isEmpty else {
            throw FolderInstance.failure("目标入口尚未退出，无法更新。")
        }
        try install(source, over: target, id: record.id, relaunch: relaunch)
    }

    /// 同一身份在应用安装目录中的其他副本，例如改过名的旧入口与新安装的副本并存。
    /// 只认安装目录：LaunchServices 还会找到改名恢复备份、构建产物和挂载的 DMG，这些不能被改写。
    func otherCopies(of id: String, source: URL = Bundle.main.bundleURL, includeSystem: Bool = true) -> [URL] {
        let sourcePath = source.resolvingSymlinksInPath().path
        return candidates(id, includeSystem: includeSystem).filter {
            $0.resolvingSymlinksInPath().path != sourcePath && isManagedInstall($0)
        }
    }

    /// 位于应用安装目录、未在废纸篓且所在目录可写，才允许更新或移走
    func isManagedInstall(_ url: URL) -> Bool {
        let roots = [URL(fileURLWithPath: "/Applications"), FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"), applications]
            .map { $0.resolvingSymlinksInPath().path + "/" }
        let path = url.resolvingSymlinksInPath().path
        return !Self.isInTrash(url) && roots.contains { path.hasPrefix($0) }
            && !path.hasPrefix(dataRoot.resolvingSymlinksInPath().path + "/")
            && FileManager.default.isWritableFile(atPath: url.deletingLastPathComponent().path)
    }

    func staleCopies(of id: String, source: URL = Bundle.main.bundleURL, includeSystem: Bool = true) -> [URL] {
        guard let current = Self.bundleVersion(source).build else { return [] }
        return otherCopies(of: id, source: source, includeSystem: includeSystem).filter { (Self.bundleVersion($0).build ?? 0) < current }
    }

    /// 只保留 source 这一份入口；其他副本移到废纸篓，应用列表与设置不在 .app 内，不受影响
    func trashOtherCopies(of id: String, source: URL = Bundle.main.bundleURL, includeSystem: Bool = true) throws {
        for copy in otherCopies(of: id, source: source, includeSystem: includeSystem) where Self.owns(copy, id: id) {
            try FileManager.default.trashItem(at: copy, resultingItemURL: nil)
        }
        try register(source, id: id)
    }

    /// 只能由 source 自身所在的入口调用：单实例保证同身份的旧副本此时都未运行
    @discardableResult
    func upgradeStaleCopies(of id: String, source: URL = Bundle.main.bundleURL, includeSystem: Bool = true) throws -> [URL] {
        let copies = staleCopies(of: id, source: source, includeSystem: includeSystem)
        for copy in copies { try install(source, over: copy, id: id, relaunch: false) }
        return copies
    }

    private func install(_ source: URL, over target: URL, id: String, relaunch: Bool) throws {
        let data = try dataDirectory(id).appendingPathComponent("library.json")
        try FolderInstance.waitForIconUpdate(storage: data)
        let library = try LibraryStorage(url: data).load()
        let transaction = dataRoot.appendingPathComponent("Renames/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: transaction, withIntermediateDirectories: true)
        let prepared = transaction.appendingPathComponent("Prepared.app")
        try FileManager.default.copyItem(at: source, to: prepared)
        try FolderInstance.configure(prepared, name: library.folders[library.selectedIndex].name,
                                     id: id, identifier: Self.identifier(id))
        let request = FolderInstance.RenameRequest(parentPID: Int32.max, source: target, destination: target,
            stagedBundle: prepared, storage: data, name: library.folders[library.selectedIndex].name)
        let url = transaction.appendingPathComponent("request.json")
        try JSONEncoder().encode(request).write(to: url, options: .atomic)
        try FolderInstance.finishRename(requestURL: url, relaunch: relaunch)
    }

    /// Caller must confirm and stop the target process before deleting anything.
    func delete(_ record: ManagedFolder, protecting currentID: String, includeSystem: Bool = true) throws {
        guard record.id != currentID, record.id != FolderInstance.rootID else {
            throw FolderInstance.failure("不能在这里删除当前文件夹或主入口。请从主入口管理其他多开。")
        }
        let directory = try dataDirectory(record.id)
        guard NSRunningApplication.runningApplications(withBundleIdentifier: Self.identifier(record.id)).isEmpty else {
            throw FolderInstance.failure("目标文件夹仍在运行，请先退出后再删除。")
        }
        try FolderInstance.waitForIconUpdate(storage: directory.appendingPathComponent("library.json"))
        // Unregister the target's own login item before removing its bundle.
        // Older versions have no login-item code and must not receive the helper argument.
        if includeSystem,
           let target = candidates(record.id).first(where: { !Self.isInTrash($0) }),
           let bundle = Bundle(url: target),
           bundle.object(forInfoDictionaryKey: "DockFolderSupportsLoginItem") as? Bool == true,
           let executable = bundle.executableURL {
            try FolderInstance.run(executable.path, ["--disable-login-item"])
        }
        // Resolve fresh paths and recheck bundle ownership; never use arbitrary paths from the UI.
        for url in candidates(record.id, includeSystem: includeSystem) {
            guard Self.owns(url, id: record.id) else { continue }
            try FileManager.default.removeItem(at: url)
        }
        let renames = dataRoot.appendingPathComponent("Renames")
        for transaction in (try? FileManager.default.contentsOfDirectory(at: renames, includingPropertiesForKeys: nil)) ?? [] {
            guard UUID(uuidString: transaction.lastPathComponent) != nil,
                  let bytes = try? Data(contentsOf: transaction.appendingPathComponent("request.json")),
                  let request = try? JSONDecoder().decode(FolderInstance.RenameRequest.self, from: bytes),
                  request.storage.standardizedFileURL == directory.appendingPathComponent("library.json").standardizedFileURL else { continue }
            try FileManager.default.removeItem(at: transaction)
        }
        if includeSystem {
            let identifier = Self.identifier(record.id)
            UserDefaults.standard.removePersistentDomain(forName: identifier)
            let library = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library")
            for path in ["Caches/\(identifier)", "Saved Application State/\(identifier).savedState"] {
                let url = library.appendingPathComponent(path)
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            }
        }
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }
}
