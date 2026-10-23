import Combine
import ServiceManagement

@MainActor
protocol LoginItemService {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() async throws
}

@MainActor
struct SystemLoginItemService: LoginItemService {
    var status: SMAppService.Status { SMAppService.mainApp.status }
    func register() throws { try SMAppService.mainApp.register() }
    func unregister() async throws { try await SMAppService.mainApp.unregister() }
}

@MainActor
final class LoginItemSettings: ObservableObject {
    private let service: any LoginItemService
    @Published private(set) var status: SMAppService.Status

    init(service: (any LoginItemService)? = nil) {
        let service = service ?? SystemLoginItemService()
        self.service = service
        status = service.status
    }
    @Published private(set) var busy = false
    @Published var error: String?

    var requested: Bool { status == .enabled || status == .requiresApproval }
    var description: String {
        switch status {
        case .enabled: return "已开启：登录 Mac 时自动启动此文件夹。"
        case .requiresApproval: return "等待系统允许，请在「登录项」中检查或开启此应用。"
        case .notRegistered: return "未开启。其他文件夹的设置不受影响。"
        case .notFound: return "尚未建立系统登录项，开启后将尝试注册。"
        @unknown default: return "系统返回了未知状态，请检查登录项。"
        }
    }
    func refresh() { status = service.status }
    func setEnabled(_ enabled: Bool) async {
        guard !busy else { return }
        busy = true
        error = nil
        defer { refresh(); busy = false }
        do {
            if enabled { try service.register() }
            else { try await service.unregister() }
        } catch { self.error = "无法修改登录项：\(error.localizedDescription)" }
    }
}
