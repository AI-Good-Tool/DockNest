import SwiftUI
import UniformTypeIdentifiers

struct FolderView: View {
    @ObservedObject var store: FolderStore
    @State private var search = ""
    @State private var isDropTarget = false
    @State private var editingName = ""
    @State private var nameAction: NameAction?
    @State private var showingManager = false
    @State private var showingSettings = false
    @State private var showingAbout = false
    @State private var outdatedEntries: [String] = []
    @FocusState private var searchFocused: Bool
    @State private var drag: AppDrag?
    @State private var order: [UUID] = []
    @State private var scroll = ScrollMetrics()
    @State private var scrollPosition = ScrollPosition(edge: .top)
    @GestureState private var isPressing = false
    private static let viewport = "folderGridViewport"

    private enum NameAction: String, Identifiable {
        case create, rename
        var id: String { rawValue }
    }

    private var filteredApps: [AppEntry] {
        store.current.apps.filter { search.isEmpty || $0.name.localizedStandardContains(search) }
    }

    /// 拖动中使用临时顺序，松手后才写入存储
    private var displayedApps: [AppEntry] {
        guard !order.isEmpty else { return filteredApps }
        let apps = Dictionary(store.current.apps.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return order.compactMap { apps[$0] } + store.current.apps.filter { !order.contains($0.id) }
    }

    var body: some View {
        withAlerts(withSheets(panel))
    }

    private var panel: some View {
        VStack(spacing: 0) {
            header
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索此文件夹", text: $search)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit { if let app = filteredApps.first { store.launch(app) } }
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .accessibilityLabel("清除搜索")
                }
                Text("⌘F").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(11)
            .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 24).padding(.top, 8)

            if store.current.apps.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "square.grid.2x2.fill")
                        .font(.system(size: 42, weight: .light)).foregroundStyle(.blue.gradient)
                    Text("把常用应用，收进一个文件夹").font(.title3.weight(.semibold))
                    Text("从 Finder 拖入应用，或点击下方按钮。\n应用保留在原来的位置，随时一键打开。")
                        .multilineTextAlignment(.center).font(.callout).foregroundStyle(.secondary)
                    Button("选择应用…", action: store.chooseApplications)
                        .buttonStyle(.borderedProminent).controlSize(.large).padding(.top, 6)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredApps.isEmpty {
                ContentUnavailableView.search(text: search)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: GridMetrics.columnSpacing), count: GridMetrics.columns),
                              spacing: GridMetrics.rowSpacing) {
                        ForEach(displayedApps) { app in
                            AppTile(app: app, icon: store.icon(for: app), isPlaceholder: drag?.id == app.id)
                                .gesture(tileGesture(for: app))
                                .help("打开 \(app.name)")
                                .accessibilityAddTraits(.isButton)
                                .accessibilityLabel("打开 \(app.name)")
                                .accessibilityAction { store.launch(app) }
                                .contextMenu {
                                    Button("打开") { store.launch(app) }
                                    Button("在 Finder 中显示") { store.reveal(app) }
                                    Button("移到最前") { store.moveToFront(app) }
                                    Divider()
                                    Button("从文件夹移除", role: .destructive) { store.remove(app) }
                                }
                        }
                    }
                    .padding(.horizontal, GridMetrics.horizontalPadding).padding(.vertical, GridMetrics.verticalPadding)
                }
                .scrollPosition($scrollPosition)
                .onScrollGeometryChange(for: ScrollGeometry.self, of: { $0 }) { _, geometry in scrollChanged(geometry) }
                .coordinateSpace(.named(Self.viewport))
                .overlay(alignment: .topLeading) { liftedTile }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .task(id: drag?.id) { await autoScrollWhileDragging() }
                .onChange(of: isPressing) { _, pressing in if !pressing { finishDrag() } }
            }
            Divider().padding(.horizontal, 24)
            HStack {
                Text("\(store.current.apps.count) 个应用").allowsHitTesting(false)
                Spacer()
                Text("拖动排序 · 右键管理 · Esc 收起").foregroundStyle(.tertiary).allowsHitTesting(false)
                Spacer()
                Button(action: store.chooseApplications) { Label("添加应用", systemImage: "plus") }
                    .buttonStyle(.plain).foregroundStyle(.blue)
                    .keyboardShortcut("o", modifiers: .command)
            }
            .font(.caption).foregroundStyle(.secondary)
            .padding(.horizontal, 26).padding(.vertical, 12)
            .background(WindowDragArea())
        }
        .frame(width: 600, height: 440)
        .disabled(store.isWorking)
        .overlay { if store.isWorking { ProgressView("正在准备文件夹…").padding(20).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)) } }
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .overlay {
            RoundedRectangle(cornerRadius: 24)
                .strokeBorder(isDropTarget ? Color.accentColor : .white.opacity(0.25), lineWidth: isDropTarget ? 3 : 1)
                .allowsHitTesting(false)
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $isDropTarget) { providers in
            let folderID = store.current.id
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in store.addApplications([url], to: folderID) }
                }
            }
            return !providers.isEmpty
        }
    }

    private func withSheets<Content: View>(_ content: Content) -> some View {
        content
        .onChange(of: store.current.id) { _, _ in search = "" }
        .onReceive(NotificationCenter.default.publisher(for: .focusFolderSearch)) { _ in searchFocused = true }
        .onReceive(NotificationCenter.default.publisher(for: .renameFolder)) { _ in editingName = store.displayName; nameAction = .rename }
        .onReceive(NotificationCenter.default.publisher(for: .createFolder)) { _ in editingName = ""; nameAction = .create }
        .onReceive(NotificationCenter.default.publisher(for: .manageFolders)) { _ in showingManager = true }
        .sheet(isPresented: $showingManager) { InstanceManagerView() }
        .onReceive(NotificationCenter.default.publisher(for: .folderSettings)) { _ in showingSettings = true }
        .sheet(isPresented: $showingSettings) { FolderSettingsView(store: store) }
        .onReceive(NotificationCenter.default.publisher(for: .folderAbout)) { _ in showingAbout = true }
        .sheet(isPresented: $showingAbout) { AboutView() }
        .onExitCommand { NSApp.hide(nil) }
        .sheet(item: $nameAction) { action in
            VStack(alignment: .leading, spacing: 18) {
                Text(action == .create ? "新建独立文件夹" : "修改应用名称").font(.headline)
                TextField("文件夹名称", text: $editingName).textFieldStyle(.roundedBorder)
                Text(action == .create ? "新文件夹有独立的 Dock 图标和应用列表，可与当前文件夹同时使用。" : "保存后此文件夹会自动重新打开，刷新 Dock 中的名称。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("取消") { nameAction = nil }.keyboardShortcut(.cancelAction)
                    Button(action == .create ? "创建并打开" : "保存并重新打开") {
                        nameAction = nil
                        if action == .create { store.createFolder(editingName) }
                        else { store.renameFolder(editingName) }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(editingName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.padding(24).frame(width: 320)
        }
    }

    private func withAlerts<Content: View>(_ content: Content) -> some View {
        content
        .alert("使用提示", isPresented: Binding(get: { store.notice != nil }, set: { if !$0 { store.notice = nil } })) {
            Button("好") { store.notice = nil }
        } message: { Text(store.notice ?? "") }
        .alert("暂时无法完成", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("好") { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
        .task { outdatedEntries = store.outdatedEntriesToPrompt() }
        .alert("发现旧版入口", isPresented: Binding(get: { !outdatedEntries.isEmpty }, set: { if !$0 { outdatedEntries = [] } })) {
            Button("以后", role: .cancel) {}
            Button("前往更新") { Task { @MainActor in showingManager = true } }
        } message: {
            Text("「\(outdatedEntries.joined(separator: "」「"))」仍是旧版本，打开后无法拖动排序。可在「管理多开文件夹」中一键更新，名称和应用列表都会保留。")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text(store.displayName).font(.system(size: 17, weight: .semibold)).lineLimit(1).allowsHitTesting(false)
            Spacer()
            Menu {
                Button("设置…") { showingSettings = true }
                Button("关于 DockNest…") { showingAbout = true }
                Button("管理多开文件夹…") { showingManager = true }
                Button("新建独立文件夹…") { editingName = ""; nameAction = .create }
                Button("修改应用名称…") { editingName = store.displayName; nameAction = .rename }
                Divider()
                Button("如何固定到 Dock") {
                    store.notice = "右键点击 Dock 中的本应用图标，选择「选项 → 在程序坞中保留」。也可以把 DockFolder.app 从 Finder 拖到 Dock 的应用区域。"
                }
                Button("在 Finder 中显示此文件夹应用", action: store.revealFolderApp)
                Button("退出此文件夹") { NSApp.terminate(nil) }
            } label: { Image(systemName: "ellipsis.circle").font(.title3) }
                .menuStyle(.borderlessButton).fixedSize().help("文件夹选项")
            Button { NSApp.hide(nil) } label: { Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)).frame(width: 28, height: 28) }
                .buttonStyle(.plain).background(.primary.opacity(0.05), in: Circle()).help("收起文件夹")
        }
        .padding(.horizontal, 24).padding(.top, 12)
        .background(WindowDragArea())
    }

    // MARK: - 拖动排序

    @ViewBuilder private var liftedTile: some View {
        if let drag, let app = store.current.apps.first(where: { $0.id == drag.id }) {
            AppTile(app: app, icon: store.icon(for: app), isLifted: !drag.isDropping)
                .frame(width: columnStep - GridMetrics.columnSpacing)
                .offset(x: drag.location.x - drag.grab.width, y: drag.location.y - drag.grab.height)
                .allowsHitTesting(false)
        }
    }

    private var columnStep: CGFloat {
        (scroll.contentSize.width - GridMetrics.horizontalPadding * 2 + GridMetrics.columnSpacing) / CGFloat(GridMetrics.columns)
    }

    private var rowStep: CGFloat { GridMetrics.tileHeight + GridMetrics.rowSpacing }

    /// 第 index 个格子的左上角（视口坐标）
    private func slotOrigin(_ index: Int) -> CGPoint {
        CGPoint(x: GridMetrics.horizontalPadding + CGFloat(index % GridMetrics.columns) * columnStep - scroll.offset.x,
                y: GridMetrics.verticalPadding + CGFloat(index / GridMetrics.columns) * rowStep - scroll.offset.y)
    }

    private func slotIndex(at point: CGPoint) -> Int {
        let column = Int(((point.x + scroll.offset.x - GridMetrics.horizontalPadding) / columnStep).rounded(.down))
        let row = Int(((point.y + scroll.offset.y - GridMetrics.verticalPadding) / rowStep).rounded(.down))
        return min(max(row, 0) * GridMetrics.columns + min(max(column, 0), GridMetrics.columns - 1), order.count - 1)
    }

    /// 单个手势同时处理点击和拖动，避免拖动松手时误触发打开
    private func tileGesture(for app: AppEntry) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.viewport))
            .updating($isPressing) { _, pressing, _ in pressing = true }
            .onChanged { value in
                if drag == nil, search.isEmpty, columnStep > 0,
                   hypot(value.translation.width, value.translation.height) >= GridMetrics.dragThreshold {
                    beginDrag(app, at: value.startLocation)
                }
                guard drag?.id == app.id, drag?.isDropping == false else { return }
                drag?.location = value.location
                reorderToDragLocation()
            }
            .onEnded { value in
                // Control-点击用于弹出右键菜单，不能同时打开应用
                if drag == nil, hypot(value.translation.width, value.translation.height) < GridMetrics.dragThreshold,
                   !NSEvent.modifierFlags.contains(.control) {
                    store.launch(app)
                }
                finishDrag()
            }
    }

    private func beginDrag(_ app: AppEntry, at start: CGPoint) {
        order = store.current.apps.map(\.id)
        guard let index = order.firstIndex(of: app.id) else { order = []; return }
        let origin = slotOrigin(index)
        drag = AppDrag(id: app.id, grab: CGSize(width: start.x - origin.x, height: start.y - origin.y), location: start)
    }

    private func reorderToDragLocation() {
        guard let drag, !drag.isDropping, let from = order.firstIndex(of: drag.id) else { return }
        let center = CGPoint(x: drag.location.x - drag.grab.width + (columnStep - GridMetrics.columnSpacing) / 2,
                             y: drag.location.y - drag.grab.height + GridMetrics.tileHeight / 2)
        let to = slotIndex(at: center)
        guard to != from else { return }
        withAnimation(.snappy(duration: 0.25)) {
            order.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        }
    }

    private func finishDrag() {
        guard let current = drag, !current.isDropping else { return }
        guard let index = order.firstIndex(of: current.id) else { drag = nil; order = []; return }
        store.reorder(order)
        let origin = slotOrigin(index)
        withAnimation(.snappy(duration: 0.22)) {
            drag?.isDropping = true
            drag?.location = CGPoint(x: origin.x + current.grab.width, y: origin.y + current.grab.height)
        } completion: {
            drag = nil
            order = []
        }
    }

    private func scrollChanged(_ geometry: ScrollGeometry) {
        scroll.offset = geometry.contentOffset
        scroll.contentSize = geometry.contentSize
        scroll.containerHeight = geometry.containerSize.height
        scroll.insets = geometry.contentInsets
        reorderToDragLocation()
    }

    private func autoScrollWhileDragging() async {
        while drag != nil, !Task.isCancelled {
            if let drag, !drag.isDropping { autoScrollStep(towards: drag.location.y) }
            try? await Task.sleep(for: .milliseconds(16))
        }
    }

    /// 拖到网格上下边缘时，越靠外滚得越快
    private func autoScrollStep(towards y: CGFloat) {
        let edge: CGFloat = 44, maxStep: CGFloat = 12
        let height = scroll.containerHeight
        let overshoot = y < edge ? y - edge : y > height - edge ? y - (height - edge) : 0
        guard overshoot != 0 else { return }
        let minY = -scroll.insets.top
        let maxY = max(minY, scroll.contentSize.height - height + scroll.insets.bottom)
        let step = min(max(overshoot / edge * maxStep, -maxStep), maxStep)
        let target = min(max(scroll.offset.y + step, minY), maxY)
        guard target != scroll.offset.y else { return }
        scrollPosition.scrollTo(y: target)
    }
}

/// 无边框面板的拖动区域
private struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }
}

private enum GridMetrics {
    static let columns = 5
    static let columnSpacing: CGFloat = 8
    static let rowSpacing: CGFloat = 4
    static let tileHeight: CGFloat = 94
    static let horizontalPadding: CGFloat = 20
    static let verticalPadding: CGFloat = 6
    static let dragThreshold: CGFloat = 4
}

private struct AppDrag {
    var id: UUID
    /// 按下点相对图块左上角的偏移
    var grab: CGSize
    /// 鼠标位置（视口坐标）
    var location: CGPoint
    var isDropping = false
}

/// 滚动几何只在拖动计算时读取，用引用类型保存以免每次滚动都刷新视图
private final class ScrollMetrics {
    var offset: CGPoint = .zero
    var contentSize: CGSize = .zero
    var containerHeight: CGFloat = 0
    var insets = EdgeInsets()
}

private struct AppTile: View {
    let app: AppEntry
    let icon: NSImage
    var isPlaceholder = false
    var isLifted = false
    @State private var hovered = false

    var body: some View {
        VStack(spacing: 4) {
            Image(nsImage: icon).resizable().interpolation(.high).frame(width: 58, height: 58)
                .scaleEffect(hovered || isLifted ? 1.07 : 1)
            Text(app.name).font(.system(size: 11, weight: .medium)).lineLimit(2)
                .multilineTextAlignment(.center).frame(height: 26, alignment: .top)
        }
        .frame(maxWidth: .infinity).padding(.top, 3).padding(.bottom, 3)
        .frame(height: GridMetrics.tileHeight)
        .background(hovered && !isLifted ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 15))
        .scaleEffect(isLifted ? 1.08 : 1)
        .shadow(color: .black.opacity(isLifted ? 0.22 : 0), radius: 10, y: 5)
        .opacity(isPlaceholder ? 0 : 1)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.15), value: hovered)
    }
}

extension Notification.Name {
    static let switchFolderEntry = Notification.Name("switchFolderEntry")
    static let folderAbout = Notification.Name("folderAbout")
    static let folderSettings = Notification.Name("folderSettings")
    static let manageFolders = Notification.Name("manageFolders")
    static let renameFolder = Notification.Name("renameFolder")
    static let createFolder = Notification.Name("createFolder")
    static let focusFolderSearch = Notification.Name("focusFolderSearch")
}
