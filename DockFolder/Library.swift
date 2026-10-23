import Foundation

struct AppEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var path: String
    var bundleIdentifier: String?
    var bookmark: Data?
}

struct AppFolder: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var apps: [AppEntry] = []
}

struct FolderLibrary: Codable, Equatable {
    var version = 1
    var folders: [AppFolder] = [AppFolder(name: "常用应用")]
    var selectedFolderID: UUID?

    var selectedIndex: Int {
        folders.firstIndex { $0.id == selectedFolderID } ?? 0
    }

    mutating func normalize() {
        if folders.isEmpty { folders = [AppFolder(name: "常用应用")] }
        if !folders.contains(where: { $0.id == selectedFolderID }) {
            selectedFolderID = folders[0].id
        }
    }

    @discardableResult
    mutating func add(_ entry: AppEntry, to folderID: UUID) -> Bool {
        guard let index = folders.firstIndex(where: { $0.id == folderID }),
              !folders[index].apps.contains(where: { $0.path == entry.path }) else { return false }
        folders[index].apps.append(entry)
        return true
    }

    mutating func move(_ appID: UUID, from sourceID: UUID, to targetID: UUID) {
        guard sourceID != targetID,
              let source = folders.firstIndex(where: { $0.id == sourceID }),
              let entry = folders[source].apps.first(where: { $0.id == appID }),
              folders.contains(where: { $0.id == targetID }) else { return }
        _ = add(entry, to: targetID)
        folders[source].apps.removeAll { $0.id == appID }
    }

    /// 按给定 ID 顺序重排；未列出的应用保持原相对顺序排在末尾
    mutating func reorder(_ appIDs: [UUID], in folderID: UUID) {
        guard let index = folders.firstIndex(where: { $0.id == folderID }) else { return }
        let rank = Dictionary(appIDs.enumerated().map { ($1, $0) }, uniquingKeysWith: min)
        func key(_ item: (offset: Int, element: AppEntry)) -> (Int, Int) { (rank[item.element.id] ?? appIDs.count, item.offset) }
        folders[index].apps = folders[index].apps.enumerated().sorted { key($0) < key($1) }.map(\.element)
    }

    /// 替换时按备份顺序重建列表；合并时只追加尚未存在的应用。返回新增数量
    @discardableResult
    mutating func importApps(_ apps: [AppEntry], into folderID: UUID, replacing: Bool) -> Int {
        guard let index = folders.firstIndex(where: { $0.id == folderID }) else { return 0 }
        if replacing { folders[index].apps = [] }
        return apps.filter { add($0, to: folderID) }.count
    }

    mutating func removeFolder(_ id: UUID) {
        guard folders.count > 1 else { return }
        folders.removeAll { $0.id == id }
        normalize()
    }
}

/// 单个文件夹的应用列表备份
struct FolderBackup: Codable, Equatable {
    static let formatName = "DockFolderBackup"
    var format = FolderBackup.formatName
    var version = 1
    var exportedAt = Date()
    var name: String
    var apps: [AppEntry]

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    /// 也接受数据目录中的 library.json，取其当前文件夹
    static func decode(_ data: Data) throws -> FolderBackup {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let backup = try? decoder.decode(FolderBackup.self, from: data), backup.format == formatName {
            guard backup.version == 1 else {
                throw NSError(domain: "DockFolder", code: 3, userInfo: [NSLocalizedDescriptionKey: "备份版本不兼容，请使用更新版本的应用。"])
            }
            return backup
        }
        if var library = try? decoder.decode(FolderLibrary.self, from: data), library.version == 1 {
            library.normalize()
            let folder = library.folders[library.selectedIndex]
            return FolderBackup(name: folder.name, apps: folder.apps)
        }
        throw NSError(domain: "DockFolder", code: 3, userInfo: [NSLocalizedDescriptionKey: "这不是 DockFolder 备份文件。"])
    }
}

struct LibraryStorage {
    let url: URL

    func load() throws -> FolderLibrary {
        guard FileManager.default.fileExists(atPath: url.path) else {
            var library = FolderLibrary()
            library.normalize()
            return library
        }
        var library = try JSONDecoder().decode(FolderLibrary.self, from: Data(contentsOf: url))
        guard library.version == 1 else {
            throw NSError(domain: "DockFolder", code: 1, userInfo: [NSLocalizedDescriptionKey: "数据版本不兼容，请使用更新版本的应用。"])
        }
        library.normalize()
        return library
    }

    func save(_ library: FolderLibrary) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(library).write(to: url, options: .atomic)
    }
}
