import AppKit
import SwiftUI
import ServiceManagement

extension NSWindow {
    func endAllSheets() {
        for sheet in sheets {
            sheet.endAllSheets()
            endSheet(sheet)
        }
    }
}

final class FolderPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func cancelOperation(_ sender: Any?) { NSApp.hide(nil) }
}

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = FolderStore()
    private var panel: FolderPanel!
    private var lastCachedIcon: Data?

    static func main() {
        if CommandLine.arguments.contains("--disable-login-item") {
            do {
                if SMAppService.mainApp.status != .notRegistered && SMAppService.mainApp.status != .notFound {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                fputs("无法移除登录项：\(error.localizedDescription)\n", stderr)
                exit(1)
            }
            return
        }
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--finish-rename" {
            do { try FolderInstance.finishRename(requestURL: URL(fileURLWithPath: CommandLine.arguments[2])) }
            catch { NSLog("DockFolder rename: %@", error.localizedDescription) }
            return
        }
        do { try FolderInstance.waitForIconUpdate(storage: FolderInstance.storageURL(for: FolderInstance.id)) }
        catch { NSLog("DockFolder icon update: %@", error.localizedDescription); return }
        let app = NSApplication.shared
        if let identifier = Bundle.main.bundleIdentifier,
           let existing = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
               .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            if let url = existing.bundleURL {
                // 进程马上退出，需等请求送达，否则已运行的副本可能收不到激活
                let done = DispatchSemaphore(value: 0)
                NSWorkspace.shared.openApplication(at: url, configuration: .init()) { _, _ in done.signal() }
                _ = done.wait(timeout: .now() + 3)
            }
            return
        }
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleQuitEvent(_:withReplyEvent:)),
                                                     forEventClass: AEEventClass(kCoreEventClass), andEventID: AEEventID(kAEQuitApplication))
        NotificationCenter.default.addObserver(self, selector: #selector(switchEntry(_:)), name: .switchFolderEntry, object: nil)
        buildMenu()
        panel = FolderPanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: 440),
                            styleMask: [.borderless], backing: .buffered, defer: false)
        panel.title = store.displayName
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        // 图标网格需要按住拖动排序，窗口只允许从标题栏和底部栏拖动（见 WindowDragArea）
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: FolderView(store: store))
        store.onChange = { [weak self] in self?.updateDockIcon() }
        updateDockIcon()
        showFolder()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showFolder()
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if !store.isReplacingBundle && store.canCacheIcon {
            do { try FolderInstance.prepareIconUpdate(storage: FolderInstance.storageURL(for: FolderInstance.id)) }
            catch {
                let alert = NSAlert()
                alert.messageText = "静态图标未能保存"
                alert.informativeText = "\(error.localizedDescription)\n应用列表已保留。仍然退出时，将继续使用原来的静态图标。"
                alert.addButton(withTitle: "仍然退出")
                alert.addButton(withTitle: "取消")
                if alert.runModal() == .alertSecondButtonReturn { return .terminateCancel }
            }
        }
        return .terminateNow
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// AppKit 默认的退出处理会被打开着的 sheet 拦下（Dock「退出」无效），先收起 sheet 再退出
    @objc private func handleQuitEvent(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        quitFolder()
    }

    @objc private func quitFolder() {
        for window in NSApp.windows { window.endAllSheets() }
        NSApp.terminate(nil)
    }

    /// 改用同身份的另一份入口：当前入口移到废纸篓并退出，等进程结束后再打开目标（单实例下不能先打开）
    @objc private func switchEntry(_ notification: Notification) {
        guard let target = notification.object as? URL else { return }
        let catalog = InstanceCatalog()
        guard catalog.isManagedInstall(Bundle.main.bundleURL),
              catalog.otherCopies(of: FolderInstance.id).contains(where: { $0.resolvingSymlinksInPath().path == target.resolvingSymlinksInPath().path }) else {
            store.errorMessage = "当前入口不在「应用程序」目录中，不能自动移走，请手动处理。"
            return
        }
        let waiter = Process()
        waiter.executableURL = URL(fileURLWithPath: "/bin/sh")
        waiter.arguments = ["-c", "while kill -0 \"$0\" 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$1\"",
                            String(ProcessInfo.processInfo.processIdentifier), target.path]
        do {
            try waiter.run()
            try catalog.register(target, id: FolderInstance.id)
            try FileManager.default.trashItem(at: Bundle.main.bundleURL, resultingItemURL: nil)
        } catch {
            if waiter.isRunning { waiter.terminate() }
            try? catalog.register(Bundle.main.bundleURL, id: FolderInstance.id)
            store.errorMessage = "无法改用「\(target.lastPathComponent)」：\(error.localizedDescription)"
            return
        }
        store.skipIconUpdateOnQuit()
        quitFolder()
    }

    func applicationDidResignActive(_ notification: Notification) {
        guard panel != nil, panel.attachedSheet == nil, NSApp.modalWindow == nil, store.errorMessage == nil else { return }
        panel.orderOut(nil)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        store.addApplications(urls)
        if panel != nil { showFolder() }
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: store.displayName, action: #selector(showFolder), keyEquivalent: "").target = self
        menu.addItem(withTitle: "重命名…", action: #selector(renameFolder), keyEquivalent: "").target = self
        menu.addItem(withTitle: "新建独立文件夹…", action: #selector(createFolder), keyEquivalent: "").target = self
        menu.addItem(withTitle: "管理多开文件夹…", action: #selector(manageFolders), keyEquivalent: "").target = self
        menu.addItem(withTitle: "设置…", action: #selector(folderSettings), keyEquivalent: "").target = self
        return menu
    }

    @objc private func folderAbout() { showFolder(); NotificationCenter.default.post(name: .folderAbout, object: nil) }

    @objc private func folderSettings() { showFolder(); NotificationCenter.default.post(name: .folderSettings, object: nil) }

    @objc private func manageFolders() { showFolder(); NotificationCenter.default.post(name: .manageFolders, object: nil) }

    @objc private func renameFolder() { showFolder(); NotificationCenter.default.post(name: .renameFolder, object: nil) }
    @objc private func createFolder() { showFolder(); NotificationCenter.default.post(name: .createFolder, object: nil) }

    @objc private func showFolder() {
        guard panel != nil else { return }
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main
        if let screen {
            let frame = screen.visibleFrame
            let x = min(max(pointer.x - 300, frame.minX + 12), max(frame.minX + 12, frame.maxX - 612))
            panel.setFrameOrigin(NSPoint(x: x, y: frame.minY + 14))
        }
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func updateDockIcon() {
        let image = DockIcon.render(icons: store.current.apps.prefix(4).map { store.icon(for: $0) })
        NSApp.applicationIconImage = image
        guard store.canCacheIcon else { return }
        do {
            let data = try DockIcon.icnsData(for: image)
            if data != lastCachedIcon {
                let directory = FolderInstance.storageURL(for: FolderInstance.id).deletingLastPathComponent()
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: directory.appendingPathComponent("FolderIcon.icns"), options: .atomic)
                lastCachedIcon = data
                DistributedNotificationCenter.default().postNotificationName(
                    Notification.Name("com.dalong.DockFolder.iconChanged"), object: FolderInstance.id,
                    userInfo: nil, deliverImmediately: true)
            }
        } catch { store.errorMessage = "无法缓存文件夹图标：\(error.localizedDescription)" }
    }

    @objc private func addApplications() { showFolder(); store.chooseApplications() }
    @objc private func focusSearch() { showFolder(); NotificationCenter.default.post(name: .focusFolderSearch, object: nil) }

    private func buildMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 DockNest…", action: #selector(folderAbout), keyEquivalent: "").target = self
        appMenu.addItem(withTitle: "打开应用文件夹", action: #selector(showFolder), keyEquivalent: "1").target = self
        appMenu.addItem(withTitle: "设置…", action: #selector(folderSettings), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏 \(store.current.name)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "退出 \(store.current.name)", action: #selector(quitFolder), keyEquivalent: "q").target = self
        appItem.submenu = appMenu
        menu.addItem(appItem)
        let fileItem = NSMenuItem()
        let file = NSMenu(title: "文件")
        file.addItem(withTitle: "添加应用…", action: #selector(addApplications), keyEquivalent: "o").target = self
        file.addItem(withTitle: "搜索", action: #selector(focusSearch), keyEquivalent: "f").target = self
        file.addItem(withTitle: "新建独立文件夹…", action: #selector(createFolder), keyEquivalent: "n").target = self
        file.addItem(withTitle: "重命名…", action: #selector(renameFolder), keyEquivalent: "").target = self
        file.addItem(withTitle: "管理多开文件夹…", action: #selector(manageFolders), keyEquivalent: "m").target = self
        fileItem.submenu = file
        menu.addItem(fileItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        menu.addItem(editItem)
        NSApp.mainMenu = menu
    }
}
