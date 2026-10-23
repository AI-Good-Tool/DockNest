import SwiftUI

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var checking = false
    @State private var message: String?
    @State private var releaseURL: URL?
    private let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("关于 DockNest").font(.title2.bold())
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("DockNest · v\(version)").foregroundStyle(.secondary)
            Link(destination: URL(string: "https://github.com/AI-Good-Tool/DockNest")!) {
                Label("仓库 · AI-Good-Tool/DockNest", systemImage: "chevron.left.forwardslash.chevron.right")
            }
            Link(destination: URL(string: "https://github.com/vs2pk0")!) {
                Label("作者 · vs2pk0", systemImage: "person.crop.circle")
            }
            Divider()
            HStack {
                Button(checking ? "正在检查…" : "检查更新") { Task { await checkForUpdates() } }
                    .disabled(checking)
                if checking { ProgressView().controlSize(.small) }
                if let releaseURL { Link("前往下载", destination: releaseURL) }
            }
            if let message {
                Text(message).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(24).frame(width: 430)
    }

    @MainActor private func checkForUpdates() async {
        checking = true
        message = nil
        releaseURL = nil
        defer { checking = false }
        do {
            let release = try await ReleaseUpdate.latest()
            if try release.isNewer(than: version) {
                message = "发现新版本 \(release.tagName)，可前往 GitHub Releases 下载。"
                releaseURL = release.htmlURL
            } else { message = "当前已是最新版本（v\(version)）。" }
        } catch { message = "无法检查更新：\(error.localizedDescription)" }
    }
}
