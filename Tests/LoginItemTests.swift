import Foundation
import ServiceManagement
import Testing
@testable import DockFolderCore

@MainActor
private final class FakeLoginService: LoginItemService {
    var status: SMAppService.Status = .notRegistered
    var approvalRequired = false
    var fail = false
    func register() throws {
        if fail { throw NSError(domain: "Test", code: 1) }
        status = approvalRequired ? .requiresApproval : .enabled
    }
    func unregister() async throws {
        if fail { throw NSError(domain: "Test", code: 2) }
        status = .notRegistered
    }
}

@Test @MainActor func loginToggleTracksRealStatusAndCanDisablePendingApproval() async {
    let service = FakeLoginService()
    service.approvalRequired = true
    let settings = LoginItemSettings(service: service)
    #expect(!settings.requested)
    await settings.setEnabled(true)
    #expect(settings.requested)
    #expect(settings.status == .requiresApproval)
    await settings.setEnabled(false)
    #expect(!settings.requested)
    #expect(!settings.busy)
}

@Test @MainActor func failedLoginChangeDoesNotPretendToSucceed() async {
    let service = FakeLoginService()
    let settings = LoginItemSettings(service: service)
    service.fail = true
    await settings.setEnabled(true)
    #expect(!settings.requested)
    #expect(settings.error != nil)
    service.fail = false
    await settings.setEnabled(true)
    #expect(settings.status == .enabled)
    #expect(settings.error == nil)
    service.fail = true
    await settings.setEnabled(false)
    #expect(settings.requested)
    #expect(!settings.busy)
}

@Test @MainActor func externalLoginChangesAndOtherInstancesAreIndependent() async {
    let a = FakeLoginService()
    let b = FakeLoginService()
    let first = LoginItemSettings(service: a)
    let second = LoginItemSettings(service: b)
    await first.setEnabled(true)
    #expect(!second.requested)
    a.status = .requiresApproval
    first.refresh()
    #expect(first.status == .requiresApproval)
    a.status = .notRegistered
    first.refresh()
    #expect(!first.requested)
}
