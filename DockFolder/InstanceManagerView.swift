import SwiftUI

struct InstanceManagerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var records: [ManagedFolder] = []
    @State private var pendingDeletion: [ManagedFolder] = []
    @State private var confirming = false
    @State private var busy = false
    @State private var error: String?
    @State private var staleCopies: [URL] = []
    @State private var duplicates: [URL] = []
    @State private var confirmingTrash = false
    @State private var switchTarget: URL?
    private let catalog = InstanceCatalog()
    private var deletable: [ManagedFolder] {
        records.filter { $0.id != FolderInstance.id && $0.id != FolderInstance.rootID }
    }
    private var pendingUpgrades: Int {
        records.filter(needsUpgrade).count + (staleCopies.isEmpty ? 0 : 1)
    }
    private func needsUpgrade(_ record: ManagedFolder) -> Bool {
        record.id != FolderInstance.id && !record.needsRecovery && record.dataError == nil && record.isOutdated
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("管理多开文件夹").font(.title2.bold())
                    Text("误删入口后，可用保存的列表恢复；每个文件夹独立管理。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("刷新", action: refresh)
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if pendingUpgrades > 0 {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.orange)
                    Text("\(pendingUpgrades) 个入口是旧版本，更新后才能拖动排序。名称和应用列表会保留。").font(.callout)
                    Spacer()
                    Button("全部更新", action: upgradeAll).buttonStyle(.borderedProminent)
                }
                .padding(12).background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
            } else if !duplicates.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "square.on.square").foregroundStyle(.orange)
                    Text("此文件夹有多个入口：正在使用「\(Bundle.main.bundleURL.lastPathComponent)」，另有「\(duplicates.map(\.lastPathComponent).joined(separator: "」「"))」。同时存在时打开和退出会互相干扰，请只保留一份。")
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 6) {
                        Button("只保留当前…") { confirmingTrash = true }
                        if duplicates.count == 1, let other = duplicates.first {
                            Button("改用「\(other.deletingPathExtension().lastPathComponent)」…") { switchTarget = other }
                        }
                    }
                }
                .padding(12).background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
            }
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(records) { record in
                        HStack(spacing: 12) {
                            Image(systemName: record.needsRecovery ? "folder.badge.questionmark" : "folder.fill")
                                .font(.title2).foregroundStyle(record.needsRecovery ? .orange : .blue)
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text(record.name).font(.headline).lineLimit(1)
                                    if record.id == FolderInstance.id { Text("当前").font(.caption).foregroundStyle(.secondary) }
                                    else if record.id == FolderInstance.rootID { Text("主入口").font(.caption).foregroundStyle(.secondary) }
                                }
                                Text(status(record)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                            Spacer()
                            if needsUpgrade(record) {
                                Button("更新并打开") { upgrade(record) }.buttonStyle(.borderedProminent)
                            } else if record.id == FolderInstance.id && !staleCopies.isEmpty {
                                Button("更新旧副本", action: upgradeStaleCopies).buttonStyle(.borderedProminent)
                            } else {
                                Button(record.needsRecovery ? "恢复并打开" : "打开") { open(record) }
                                    .disabled(record.dataError != nil)
                            }
                            Menu {
                                if needsUpgrade(record) {
                                    Button("直接打开旧版本") { open(record) }
                                }
                                if let url = record.appURL, !record.needsRecovery {
                                    Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                                }
                                if record.id == FolderInstance.id && !staleCopies.isEmpty {
                                    Button("在 Finder 中显示旧副本") { NSWorkspace.shared.activateFileViewerSelecting(staleCopies) }
                                }
                                if !record.needsRecovery {
                                    Button("更新到当前版本并打开") { upgrade(record) }
                                        .disabled(record.id == FolderInstance.id || record.dataError != nil)
                                }
                                Button("显示数据位置") {
                                    if let url = try? catalog.dataDirectory(record.id) { NSWorkspace.shared.open(url) }
                                }
                                Divider()
                                Button("删除文件夹及全部数据…", role: .destructive) {
                                    pendingDeletion = [record]; confirming = true
                                }.disabled(record.id == FolderInstance.id || record.id == FolderInstance.rootID)
                            } label: { Image(systemName: "ellipsis.circle") }
                            .menuStyle(.borderlessButton).fixedSize().help("管理「\(record.name)」")
                        }
                        .padding(14).background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
                    }
                    if records.isEmpty { Text("暂时没有已保存的文件夹").foregroundStyle(.secondary).padding(40) }
                }
            }
            HStack {
                Text("\(records.count) 个文件夹").font(.caption).foregroundStyle(.secondary)
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("删除其他多开…", role: .destructive) {
                    pendingDeletion = deletable; confirming = true
                }.disabled(deletable.isEmpty)
            }
            Text("删除会清理入口、列表、改名备份和缓存；不会卸载其中的应用。当前文件夹与主入口保留。")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(24).frame(width: 660, height: 460).disabled(busy)
        .task { refresh() }
        .alert("永久删除 \(pendingDeletion.count) 个多开文件夹？", isPresented: $confirming) {
            Button("取消", role: .cancel) { pendingDeletion = [] }
            Button("永久删除", role: .destructive) { deleteConfirmed() }
        } message: {
            Text(pendingDeletion.map(\.name).joined(separator: "、") + "\n将先退出目标文件夹，再删除入口和所有已保存的快捷方式、设置及改名备份。此操作不可撤销。")
        }
        .alert("只保留当前入口？", isPresented: $confirmingTrash) {
            Button("取消", role: .cancel) {}
            Button("移到废纸篓", role: .destructive, action: trashDuplicates)
        } message: {
            Text("保留正在使用的「\(Bundle.main.bundleURL.path)」，将以下入口移到废纸篓：\(duplicates.map(\.path).joined(separator: "、"))。\n应用列表和设置不受影响；如果 Dock 中固定的是被移走的那份，请重新固定当前入口。")
        }
        .alert("改用另一个入口？", isPresented: Binding(get: { switchTarget != nil }, set: { if !$0 { switchTarget = nil } }), presenting: switchTarget) { target in
            Button("取消", role: .cancel) {}
            Button("改用并重新打开") { NotificationCenter.default.post(name: .switchFolderEntry, object: target) }
        } message: { target in
            Text("将退出并把正在使用的「\(Bundle.main.bundleURL.path)」移到废纸篓，然后打开「\(target.path)」。\n应用列表和设置不受影响。")
        }
        .alert("无法完成操作", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("好") { error = nil }
        } message: { Text(error ?? "") }
    }

    private func status(_ record: ManagedFolder) -> String {
        if let error = record.dataError { return "数据读取失败：\(error)" }
        let state: String
        if record.needsRecovery { state = "入口已移走或删除 · 列表仍保留" }
        else if needsUpgrade(record) { state = "旧版 \(record.version ?? "")，更新后可拖动排序" }
        else if record.id == FolderInstance.id && !staleCopies.isEmpty {
            state = "另有旧版副本：" + staleCopies.map(\.lastPathComponent).joined(separator: "、")
        } else if record.id == FolderInstance.id && !duplicates.isEmpty {
            state = "另有重复入口：" + duplicates.map(\.lastPathComponent).joined(separator: "、")
        } else { state = "可打开" + (record.version.map { " · \($0)" } ?? "") }
        return "\(record.count ?? 0) 个应用 · \(state)"
    }
    private func refresh() {
        do { records = try catalog.list() }
        catch { self.error = error.localizedDescription }
        staleCopies = catalog.staleCopies(of: FolderInstance.id)
        duplicates = catalog.otherCopies(of: FolderInstance.id).filter { !staleCopies.contains($0) }
    }
    private func trashDuplicates() {
        do { try catalog.trashOtherCopies(of: FolderInstance.id) }
        catch { self.error = error.localizedDescription }
        refresh()
    }
    private func upgradeStaleCopies() {
        busy = true
        Task { @MainActor in
            await Task.yield()
            do { try catalog.upgradeStaleCopies(of: FolderInstance.id) }
            catch { self.error = error.localizedDescription }
            busy = false
            refresh()
        }
    }
    private func upgradeAll() {
        let targets = records.filter(needsUpgrade)
        busy = true
        Task { @MainActor in
            await Task.yield()
            var failures: [String] = []
            if !staleCopies.isEmpty {
                do { try catalog.upgradeStaleCopies(of: FolderInstance.id) }
                catch { failures.append("当前文件夹的旧副本：\(error.localizedDescription)") }
            }
            for target in targets {
                let wasRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: InstanceCatalog.identifier(target.id)).isEmpty
                await stop(target)
                do { try catalog.upgrade(target, protecting: FolderInstance.id, relaunch: wasRunning) }
                catch { failures.append("\(target.name)：\(error.localizedDescription)") }
            }
            busy = false
            refresh()
            if !failures.isEmpty { error = failures.joined(separator: "\n") }
        }
    }
    private func open(_ record: ManagedFolder) {
        if record.id == FolderInstance.id && !record.needsRecovery { dismiss(); return }
        busy = true
        Task { @MainActor in
            await Task.yield()
            defer { busy = false }
            do {
                let url = try record.needsRecovery ? catalog.recover(record) : record.appURL!
                // 不等打开结果再解锁界面：系统回调可能迟迟不来，整页会被锁住
                NSWorkspace.shared.openApplication(at: url, configuration: .init()) { _, failure in
                    Task { @MainActor in
                        if let failure { error = failure.localizedDescription }
                        refresh()
                    }
                }
            } catch { self.error = error.localizedDescription }
        }
    }
    @MainActor
    private func stop(_ record: ManagedFolder) async {
        let identifier = InstanceCatalog.identifier(record.id)
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: identifier) { app.terminate() }
        for _ in 0..<50 {
            if NSRunningApplication.runningApplications(withBundleIdentifier: identifier).isEmpty { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
    private func upgrade(_ record: ManagedFolder) {
        busy = true
        Task { @MainActor in
            await stop(record)
            do { try catalog.upgrade(record, protecting: FolderInstance.id) }
            catch { self.error = error.localizedDescription }
            busy = false
            refresh()
        }
    }
    private func deleteConfirmed() {
        let targets = pendingDeletion
        pendingDeletion = []
        busy = true
        Task { @MainActor in
            var failures: [String] = []
            for target in targets {
                await stop(target)
                do { try catalog.delete(target, protecting: FolderInstance.id) }
                catch { failures.append("\(target.name)：\(error.localizedDescription)") }
            }
            busy = false
            refresh()
            if !failures.isEmpty { error = failures.joined(separator: "\n") }
        }
    }
}
