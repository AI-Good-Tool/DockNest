import SwiftUI
import ServiceManagement

struct FolderSettingsView: View {
    @ObservedObject var store: FolderStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var login = LoginItemSettings()
    @State private var backupResult: String?
    @State private var exportedURL: URL?
    @State private var backupError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("文件夹设置").font(.title2.bold())
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text(store.displayName).font(.headline).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 10) {
                Toggle("开机自启动（登录时启动）", isOn: Binding(get: { login.requested }, set: { value in Task { await login.setEnabled(value) } }))
                    .toggleStyle(.switch).disabled(login.busy)
                Text(login.description).font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("打开系统登录项设置") { SMAppService.openSystemSettingsLoginItems() }
                    if login.busy { ProgressView().controlSize(.small) }
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Text("Dock 下方的运行圆点").font(.headline)
                Text("macOS 没有提供只隐藏此文件夹运行圆点的公开设置。系统的关闭开关会隐藏所有应用的圆点。")
                    .font(.callout).foregroundStyle(.secondary)
                Text("如需全局隐藏：系统设置 → 桌面与程序坞 → 关闭「显示已打开应用程序的指示器」。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("打开桌面与程序坞设置") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Desktop-Settings.extension")!)
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Text("备份").font(.headline)
                Text("将此文件夹的 \(store.current.apps.count) 个应用（含顺序）导出为 JSON 文件；导入时可选择合并或替换当前列表，本机找不到的应用会被跳过。也可以导入数据目录中的 library.json。")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("导出备份…") {
                        runBackup {
                            guard let url = try store.exportBackup() else { return nil }
                            exportedURL = url
                            return "已导出到：\n\(url.path)"
                        }
                    }
                    .disabled(store.current.apps.isEmpty)
                    Button("导入备份…") { exportedURL = nil; runBackup { try store.importBackup() } }
                }
            }
        }
        .padding(24).frame(width: 470)
        .task { login.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in login.refresh() }
        .alert("无法完成设置", isPresented: Binding(get: { login.error != nil }, set: { if !$0 { login.error = nil } })) {
            Button("好") { login.error = nil }
        } message: { Text(login.error ?? "") }
        .alert("备份", isPresented: Binding(get: { backupResult != nil }, set: { if !$0 { backupResult = nil } })) {
            if let exportedURL { Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([exportedURL]) } }
            Button("好") {}
        } message: { Text(backupResult ?? "") }
        .alert("备份失败", isPresented: Binding(get: { backupError != nil }, set: { if !$0 { backupError = nil } })) {
            Button("好") {}
        } message: { Text(backupError ?? "") }
    }

    private func runBackup(_ operation: () throws -> String?) {
        do { backupResult = try operation() } catch { backupError = error.localizedDescription }
    }
}
