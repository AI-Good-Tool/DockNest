import AppKit
import CoreServices
import CryptoKit

/// Each generated bundle has a stable identity independent of its editable name.
struct FolderInstance {
    static let rootID = "default"
    static var id: String { Bundle.main.object(forInfoDictionaryKey: "DockFolderInstanceID") as? String ?? rootID }
    static var support: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("DockFolder")
    }
    static func storageURL(for id: String) -> URL {
        support.appendingPathComponent("Instances/\(id)/library.json")
    }
    static var applications: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/DockFolders")
    }

    static func validatedName(_ value: String) throws -> String {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 40,
              !name.contains("/"), !name.contains(":"),
              name.rangeOfCharacter(from: .controlCharacters) == nil,
              name != ".", name != "..", !name.hasPrefix(".") else {
            throw failure("名称需为 1–40 个字符，不能以点开头，不能包含 /、: 或控制字符。")
        }
        return name
    }

    static func failure(_ message: String) -> NSError {
        NSError(domain: "DockFolder", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
    }

    static func run(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        process.standardError = output
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw failure(String(data: data, encoding: .utf8) ?? "操作失败：\(executable)")
        }
    }

    static func configure(_ bundle: URL, name: String, id: String, identifier: String) throws {
        let cache = storageURL(for: id).deletingLastPathComponent().appendingPathComponent("FolderIcon.icns")
        let fallback = bundle.appendingPathComponent("Contents/Resources/DefaultAppIcon.icns")
        var generatedIconName: String?
        if let icon = try? Data(contentsOf: FileManager.default.fileExists(atPath: cache.path) ? cache : fallback) {
            let resources = bundle.appendingPathComponent("Contents/Resources")
            let digest = SHA256.hash(data: icon).prefix(8).map { String(format: "%02x", $0) }.joined()
            let name = "DFGeneratedIcon-\(digest).icns"
            for old in (try? FileManager.default.contentsOfDirectory(at: resources, includingPropertiesForKeys: nil)) ?? []
                where old.lastPathComponent.hasPrefix("DFGeneratedIcon-") && old.pathExtension == "icns" {
                try FileManager.default.removeItem(at: old)
            }
            try icon.write(to: resources.appendingPathComponent("AppIcon.icns"), options: .atomic)
            try icon.write(to: resources.appendingPathComponent(name), options: .atomic)
            generatedIconName = name
        }
        let plist = bundle.appendingPathComponent("Contents/Info.plist")
        var info = try PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as! [String: Any]
        if let generatedIconName { info["CFBundleIconFile"] = generatedIconName }
        info["CFBundleName"] = name
        info["CFBundleDisplayName"] = name
        info["CFBundleIdentifier"] = identifier
        info["DockFolderInstanceID"] = id
        // Each folder accepts drops, but should not compete to open .app files by default.
        info["CFBundleDocumentTypes"] = [["CFBundleTypeName": "macOS 应用", "CFBundleTypeRole": "Viewer",
                                         "LSHandlerRank": "None", "LSItemContentTypes": ["com.apple.application-bundle"]]]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: plist, options: .atomic)
        // Each clone's Dock plug-in must read its own cache, even when several
        // plug-ins are loaded into the same system host process.
        let plugin = bundle.appendingPathComponent("Contents/PlugIns/DockFolderTile.docktileplugin")
        let pluginPlist = plugin.appendingPathComponent("Contents/Info.plist")
        if FileManager.default.fileExists(atPath: pluginPlist.path) {
            var pluginInfo = try PropertyListSerialization.propertyList(from: Data(contentsOf: pluginPlist), format: nil) as! [String: Any]
            pluginInfo["DockFolderInstanceID"] = id
            pluginInfo["NSPrincipalClass"] = "DFDockTile_" + id.replacingOccurrences(of: "-", with: "_")
            pluginInfo["CFBundleIdentifier"] = identifier + ".tile"
            try PropertyListSerialization.data(fromPropertyList: pluginInfo, format: .xml, options: 0)
                .write(to: pluginPlist, options: .atomic)
            try run("/usr/bin/codesign", ["--force", "--sign", "-", "--options", "runtime", plugin.path])
        }
        try run("/usr/bin/codesign", ["--force", "--sign", "-", "--options", "runtime", bundle.path])
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", bundle.path])
    }

    static func create(name value: String, apps: [AppEntry] = [], source: URL = Bundle.main.bundleURL,
                       directory: URL = applications, dataRoot: URL = support) throws -> URL {
        let name = try validatedName(value)
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(name + ".app")
        guard !fm.fileExists(atPath: destination.path) else { throw failure("已有同名文件夹应用，请使用其他名称。") }
        let id = UUID().uuidString
        let staging = directory.appendingPathComponent(".creating-\(id).app")
        let dataDirectory = dataRoot.appendingPathComponent("Instances/\(id)")
        do {
            try fm.copyItem(at: source, to: staging)
            try configure(staging, name: name, id: id, identifier: "com.dalong.DockFolder.instance.\(id)")
            let folder = AppFolder(name: name, apps: apps)
            try LibraryStorage(url: dataDirectory.appendingPathComponent("library.json"))
                .save(FolderLibrary(folders: [folder], selectedFolderID: folder.id))
            try fm.moveItem(at: staging, to: destination)
            try InstanceCatalog(dataRoot: dataRoot, applications: directory).register(destination, id: id)
            LSRegisterURL(destination as CFURL, true)
            return destination
        } catch {
            try? fm.removeItem(at: staging)
            try? fm.removeItem(at: dataDirectory)
            throw error
        }
    }

    struct RenameRequest: Codable {
        var parentPID: Int32
        var source: URL
        var destination: URL
        var stagedBundle: URL
        var storage: URL
        var name: String
        var iconOnly: Bool? = nil
    }

    static func waitForIconUpdate(storage: URL) throws {
        let marker = storage.deletingLastPathComponent().appendingPathComponent("icon-update.pending")
        for _ in 0..<100 {
            if !FileManager.default.fileExists(atPath: marker.path) { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw failure("上一次图标更新尚未完成，请稍后重试。")
    }

    static func prepareIconUpdate(storage: URL) throws {
        let cache = storage.deletingLastPathComponent().appendingPathComponent("FolderIcon.icns")
        guard let data = try? Data(contentsOf: cache) else { return }
        let source = Bundle.main.bundleURL
        let destinationIcon = source.appendingPathComponent("Contents/Resources/AppIcon.icns")
        if (try? Data(contentsOf: destinationIcon)) == data { return }
        try waitForIconUpdate(storage: storage)
        let transaction = support.appendingPathComponent("Renames/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: transaction, withIntermediateDirectories: true)
        let staged = transaction.appendingPathComponent("Prepared.app")
        try FileManager.default.copyItem(at: source, to: staged)
        try configure(staged, name: Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? source.deletingPathExtension().lastPathComponent,
                      id: id, identifier: Bundle.main.bundleIdentifier!)
        let helper = transaction.appendingPathComponent("IconHelper")
        try FileManager.default.copyItem(at: Bundle.main.executableURL!, to: helper)
        let library = try LibraryStorage(url: storage).load()
        let request = RenameRequest(parentPID: ProcessInfo.processInfo.processIdentifier, source: source, destination: source,
            stagedBundle: staged, storage: storage, name: library.folders[library.selectedIndex].name, iconOnly: true)
        let requestURL = transaction.appendingPathComponent("request.json")
        try JSONEncoder().encode(request).write(to: requestURL, options: .atomic)
        let marker = storage.deletingLastPathComponent().appendingPathComponent("icon-update.pending")
        try Data(requestURL.path.utf8).write(to: marker, options: .atomic)
        do {
            let process = Process()
            process.executableURL = helper
            process.arguments = ["--finish-rename", requestURL.path]
            try process.run()
        } catch {
            try? FileManager.default.removeItem(at: marker)
            throw error
        }
    }

    static func prepareRename(name value: String, storage: URL) throws -> URL {
        let name = try validatedName(value)
        let source = Bundle.main.bundleURL
        let destination = source.deletingLastPathComponent().appendingPathComponent(name + ".app")
        let fm = FileManager.default
        guard fm.isWritableFile(atPath: source.deletingLastPathComponent().path) else {
            throw failure("应用所在目录不可写，请先将应用复制到自己的「应用程序」目录。")
        }
        guard source == destination || !fm.fileExists(atPath: destination.path) else {
            throw failure("此位置已有同名应用，请使用其他名称。")
        }
        let transaction = support.appendingPathComponent("Renames/\(UUID().uuidString)")
        try fm.createDirectory(at: transaction, withIntermediateDirectories: true)
        let staged = transaction.appendingPathComponent("Prepared.app")
        try fm.copyItem(at: source, to: staged)
        try configure(staged, name: name, id: id, identifier: Bundle.main.bundleIdentifier!)
        let helper = transaction.appendingPathComponent("RenameHelper")
        try fm.copyItem(at: Bundle.main.executableURL!, to: helper)
        let request = RenameRequest(parentPID: ProcessInfo.processInfo.processIdentifier, source: source,
                                    destination: destination, stagedBundle: staged, storage: storage, name: name)
        let requestURL = transaction.appendingPathComponent("request.json")
        try JSONEncoder().encode(request).write(to: requestURL, options: .atomic)
        let process = Process()
        process.executableURL = helper
        process.arguments = ["--finish-rename", requestURL.path]
        try process.run()
        return requestURL
    }

    /// Runs from a separate executable so the running application's signed code is never modified.
    static func finishRename(requestURL: URL, relaunch: Bool = true) throws {
        let request = try JSONDecoder().decode(RenameRequest.self, from: Data(contentsOf: requestURL))
        let shouldRelaunch = request.iconOnly == true ? false : relaunch
        defer {
            if request.iconOnly == true {
                let marker = request.storage.deletingLastPathComponent().appendingPathComponent("icon-update.pending")
                if (try? String(contentsOf: marker, encoding: .utf8)) == requestURL.path {
                    try? FileManager.default.removeItem(at: marker)
                }
            }
        }
        for _ in 0..<300 {
            if kill(request.parentPID, 0) != 0 { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        guard kill(request.parentPID, 0) != 0 else { throw failure("原应用未退出，改名已取消。") }
        let fm = FileManager.default
        let backup = requestURL.deletingLastPathComponent().appendingPathComponent("OriginalContents")
        let originalData = try Data(contentsOf: request.storage)
        var movedBundle = false
        var backedUp = false
        var installed = false
        do {
            if request.source != request.destination {
                try fm.moveItem(at: request.source, to: request.destination)
                movedBundle = true
            }
            // Keep the outer bundle inode: Finder/Dock bookmarks can follow the rename.
            try fm.moveItem(at: request.destination.appendingPathComponent("Contents"), to: backup)
            backedUp = true
            try fm.moveItem(at: request.stagedBundle.appendingPathComponent("Contents"), to: request.destination.appendingPathComponent("Contents"))
            installed = true
            try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", request.destination.path])
            let storage = LibraryStorage(url: request.storage)
            var library = try storage.load()
            if request.iconOnly != true {
                library.folders[library.selectedIndex].name = request.name
                try storage.save(library)
            }
            try? InstanceCatalog(dataRoot: request.storage.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()).register(request.destination, id: request.storage.deletingLastPathComponent().lastPathComponent)
            LSRegisterURL(request.destination as CFURL, true)
            if shouldRelaunch { try run("/usr/bin/open", [request.destination.path]) }
            // OriginalContents is deliberately retained as a recovery backup.
        } catch {
            if installed {
                try? fm.moveItem(at: request.destination.appendingPathComponent("Contents"),
                                 to: requestURL.deletingLastPathComponent().appendingPathComponent("FailedContents"))
            }
            if backedUp { try? fm.moveItem(at: backup, to: request.destination.appendingPathComponent("Contents")) }
            if movedBundle { try? fm.moveItem(at: request.destination, to: request.source) }
            try? originalData.write(to: request.storage, options: .atomic)
            try? Data(error.localizedDescription.utf8).write(to: request.storage.deletingLastPathComponent().appendingPathComponent("rename-error.txt"))
            LSRegisterURL(request.source as CFURL, true)
            if shouldRelaunch { try? run("/usr/bin/open", [request.source.path]) }
            throw error
        }
    }
}
