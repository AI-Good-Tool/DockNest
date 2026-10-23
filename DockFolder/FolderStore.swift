import AppKit
import Combine
import UniformTypeIdentifiers

@MainActor
final class FolderStore: ObservableObject {
    @Published private(set) var library: FolderLibrary
    @Published var errorMessage: String?
    @Published var isWorking = false
    @Published var notice: String?
    var onChange: (() -> Void)?
    private let storage: LibraryStorage
    private var canSave = true
    private(set) var isReplacingBundle = false
    var canCacheIcon: Bool { canSave }
    private var icons: [String: NSImage] = [:]

    var displayName: String {
        NSRunningApplication.current.localizedName
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? current.name
    }

    var current: AppFolder { library.folders[library.selectedIndex] }

    init() {
        storage = LibraryStorage(url: FolderInstance.storageURL(for: FolderInstance.id))
        do {
            if !FileManager.default.fileExists(atPath: storage.url.path), FolderInstance.id == FolderInstance.rootID {
                // Leave all old groups intact in library.json; migrate only the selected folder.
                let legacy = try LibraryStorage(url: FolderInstance.support.appendingPathComponent("library.json")).load()
                let folder = legacy.folders[legacy.selectedIndex]
                try storage.save(FolderLibrary(folders: [folder], selectedFolderID: folder.id))
            }
            library = try storage.load()
            try? InstanceCatalog().register(Bundle.main.bundleURL, id: FolderInstance.id)
            let errorURL = storage.url.deletingLastPathComponent().appendingPathComponent("rename-error.txt")
            if let message = try? String(contentsOf: errorURL, encoding: .utf8) {
                errorMessage = "改名失败，已恢复原应用：\(message)"
                try? FileManager.default.removeItem(at: errorURL)
            }
        } catch {
            library = FolderLibrary()
            library.normalize()
            canSave = false
            errorMessage = "无法读取应用列表，已保留原始文件。请检查 \(storage.url.path)。\n\(error.localizedDescription)"
        }
    }

    private func update(_ change: (inout FolderLibrary) -> Void) {
        do { try commit(change) } catch { errorMessage = error.localizedDescription }
    }

    private func commit(_ change: (inout FolderLibrary) -> Void) throws {
        guard canSave else {
            throw FolderInstance.failure("原始数据读取失败，为避免覆盖，请先修复或备份应用列表文件并重新启动。")
        }
        var next = library
        change(&next)
        do { try storage.save(next) } catch { throw FolderInstance.failure("保存失败：\(error.localizedDescription)") }
        library = next
        onChange?()
    }

    /// 当前 bundle 即将被移走，退出时不能再写入静态图标
    func skipIconUpdateOnQuit() { isReplacingBundle = true }

    func createFolder(_ name: String) {
        performInstanceOperation {
            let url = try FolderInstance.create(name: name)
            self.openInstance(url)
        }
    }

    func renameFolder(_ name: String) {
        performInstanceOperation {
            let name = try FolderInstance.validatedName(name)
            if name == self.current.name && Bundle.main.bundleURL.deletingPathExtension().lastPathComponent == name { return }
            _ = try FolderInstance.prepareRename(name: name, storage: self.storage.url)
            self.isReplacingBundle = true
            NSApp.terminate(nil)
        }
    }

    private func performInstanceOperation(_ operation: @escaping @MainActor () throws -> Void) {
        guard !isWorking, canSave else { return }
        isWorking = true
        Task { @MainActor in
            // Allow the progress indicator to render before local bundle/signing work.
            await Task.yield()
            defer { isWorking = false }
            do { try operation() }
            catch { errorMessage = error.localizedDescription }
        }
    }

    private func openInstance(_ url: URL) {
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            Task { @MainActor in
                if let error { self.errorMessage = "文件夹已创建，但打开失败：\(error.localizedDescription)\n\(url.path)" }
            }
        }
    }

    func revealFolderApp() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    func remove(_ app: AppEntry) {
        update { $0.folders[$0.selectedIndex].apps.removeAll { $0.id == app.id } }
    }

    func moveToFront(_ app: AppEntry) {
        update {
            let index = $0.selectedIndex
            $0.folders[index].apps.removeAll { $0.id == app.id }
            $0.folders[index].apps.insert(app, at: 0)
        }
    }

    func reorder(_ appIDs: [UUID]) {
        guard current.apps.map(\.id) != appIDs else { return }
        update { $0.reorder(appIDs, in: $0.folders[$0.selectedIndex].id) }
    }

    func addApplications(_ urls: [URL], to folderID: UUID? = nil) {
        let target = folderID ?? current.id
        var rejected: [String] = []
        var entries: [AppEntry] = []
        for rawURL in urls {
            let url = ((try? URL(resolvingAliasFileAt: rawURL, options: .withoutUI)) ?? rawURL).resolvingSymlinksInPath().standardizedFileURL
            guard url.pathExtension.lowercased() == "app",
                  let bundle = Bundle(url: url), bundle.executableURL != nil,
                  url != Bundle.main.bundleURL else {
                rejected.append(rawURL.lastPathComponent)
                continue
            }
            let name = FileManager.default.displayName(atPath: url.path)
            entries.append(AppEntry(name: name.hasSuffix(".app") ? String(name.dropLast(4)) : name,
                                    path: url.path, bundleIdentifier: bundle.bundleIdentifier,
                                    bookmark: try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)))
        }
        if !entries.isEmpty { update { library in entries.forEach { _ = library.add($0, to: target) } } }
        if !rejected.isEmpty { errorMessage = "只能添加其他 macOS 应用（.app）或应用替身：\n" + rejected.joined(separator: "、") }
    }

    func chooseApplications() {
        let picker = NSOpenPanel()
        picker.title = "添加应用到「\(current.name)」"
        picker.prompt = "添加应用"
        picker.directoryURL = URL(fileURLWithPath: "/Applications")
        picker.allowedContentTypes = [.applicationBundle]
        picker.allowsMultipleSelection = true
        picker.canChooseDirectories = false
        picker.treatsFilePackagesAsDirectories = false
        if picker.runModal() == .OK { addApplications(picker.urls) }
    }

    func resolvedURL(for app: AppEntry) -> URL? {
        if let bookmark = app.bookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale),
               FileManager.default.fileExists(atPath: url.path) { return url }
        }
        if FileManager.default.fileExists(atPath: app.path) { return URL(fileURLWithPath: app.path) }
        return app.bundleIdentifier.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
    }

    func icon(for app: AppEntry) -> NSImage {
        if let cached = icons[app.path] { return cached }
        let icon = NSWorkspace.shared.icon(forFile: resolvedURL(for: app)?.path ?? app.path)
        icons[app.path] = icon
        return icon
    }

    func launch(_ app: AppEntry) {
        guard let url = resolvedURL(for: app) else {
            errorMessage = "找不到「\(app.name)」，请重新添加该应用。"
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
            Task { @MainActor in
                if let error { self.errorMessage = "无法打开「\(app.name)」：\(error.localizedDescription)" }
                else { NSApp.hide(nil) }
            }
        }
    }

    func reveal(_ app: AppEntry) {
        guard let url = resolvedURL(for: app) else { errorMessage = "找不到「\(app.name)」。"; return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - 备份

    /// 返回导出位置；用户取消时返回 nil
    func exportBackup() throws -> URL? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        let panel = NSSavePanel()
        panel.title = "导出「\(displayName)」的备份"
        panel.prompt = "导出"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "\(displayName)-备份-\(formatter.string(from: Date())).json"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        try FolderBackup(name: displayName, apps: current.apps).encoded().write(to: url, options: .atomic)
        return url
    }

    /// 返回导入结果说明；用户取消时返回 nil
    func importBackup() throws -> String? {
        let panel = NSOpenPanel()
        panel.title = "导入备份到「\(displayName)」"
        panel.prompt = "导入"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        let backup = try FolderBackup.decode(Data(contentsOf: url))
        // 备份可能来自另一台 Mac：按书签、路径、bundle ID 依次在本机重新定位
        var missing: [String] = []
        let apps = backup.apps.compactMap { entry -> AppEntry? in
            guard let resolved = resolvedURL(for: entry) else { missing.append(entry.name); return nil }
            return AppEntry(name: entry.name, path: resolved.path,
                            bundleIdentifier: entry.bundleIdentifier ?? Bundle(url: resolved)?.bundleIdentifier,
                            bookmark: try? resolved.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil))
        }
        guard !apps.isEmpty else {
            throw FolderInstance.failure("备份「\(backup.name)」中的 \(backup.apps.count) 个应用在本机都找不到。")
        }
        let alert = NSAlert()
        alert.messageText = "导入「\(backup.name)」的 \(apps.count) 个应用"
        alert.informativeText = "合并：保留当前列表，只追加没有的应用。\n替换：当前列表改为与备份完全一致（含顺序）。"
            + (missing.isEmpty ? "" : "\n\n本机找不到、将跳过：" + missing.joined(separator: "、"))
        alert.addButton(withTitle: "合并")
        alert.addButton(withTitle: "替换")
        alert.addButton(withTitle: "取消")
        let response = alert.runModal()
        guard response != .alertThirdButtonReturn else { return nil }
        let replacing = response == .alertSecondButtonReturn
        var added = 0
        try commit { added = $0.importApps(apps, into: $0.folders[$0.selectedIndex].id, replacing: replacing) }
        var message = replacing ? "已替换为备份中的 \(added) 个应用。" : "已合并，新增 \(added) 个应用。"
        if !missing.isEmpty { message += "\n已跳过本机找不到的：" + missing.joined(separator: "、") }
        return message
    }

    // MARK: - 旧版入口

    /// 每个版本只提示一次；返回需要更新的入口名称
    func outdatedEntriesToPrompt() -> [String] {
        let key = "outdatedEntriesPromptedBuild"
        guard let current = InstanceCatalog.currentBuild, UserDefaults.standard.integer(forKey: key) < current else { return [] }
        UserDefaults.standard.set(current, forKey: key)
        let catalog = InstanceCatalog()
        let others = ((try? catalog.list()) ?? [])
            .filter { $0.id != FolderInstance.id && !$0.needsRecovery && $0.isOutdated }
            .map(\.name)
        let copies = catalog.staleCopies(of: FolderInstance.id).map { $0.deletingPathExtension().lastPathComponent + "（当前文件夹的旧副本）" }
        return others + copies
    }
}
