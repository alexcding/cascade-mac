import Foundation
import Testing

actor LoginItemFixture: LoginItemService {
    var value = LoginItemState(status: .notRegistered, registrationUnavailableReason: nil)
    var nextStatus = LoginItemStatus.requiresApproval
    var failure: String?
    var writes: [Bool] = []
    var settingsOpens = 0
    func configure(_ status: LoginItemStatus, unavailable: String? = nil) {
        value = LoginItemState(status: status, registrationUnavailableReason: unavailable)
    }
    func fail(_ message: String?) { failure = message }
    func state() async -> LoginItemState {
        let snapshot = value
        try? await Task.sleep(for: .milliseconds(30))
        return snapshot
    }
    func setEnabled(_ enabled: Bool) async throws {
        writes.append(enabled)
        try await Task.sleep(for: .milliseconds(30))
        value = LoginItemState(status: enabled ? nextStatus : .notRegistered, registrationUnavailableReason: nil)
        if let failure { throw BackendError.operation(failure) }
    }
    func openSystemSettings() { settingsOpens += 1 }
}

@MainActor private func waitForLoginItem(_ condition: () -> Bool) async throws {
    for _ in 0..<300 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw BackendError.operation("Timed out waiting for login-item state")
}

@MainActor @Test(.timeLimit(.minutes(1))) func loginItemReflectsApprovalFailureAndExternalChangesWithoutOptimisticState() async throws {
    let service = LoginItemFixture()
    let subject = LoginItemViewModel(service: service)
    subject.onAction = { [weak subject] in subject?.perform($0) }
    #expect(subject.state == nil && !subject.canToggle)
    subject.setActive(true)
    try await waitForLoginItem { !subject.loading }
    #expect(!subject.registered && subject.canToggle && subject.statusText == "Off")
    #expect(await service.writes.isEmpty)
    subject.setEnabled(true); subject.setEnabled(true)
    #expect(!subject.registered && subject.changing)
    try await waitForLoginItem { !subject.changing }
    #expect(subject.registered && subject.needsApproval)
    #expect(subject.statusText.contains("approval required"))
    #expect(await service.writes == [true])
    subject.openSystemSettings()
    for _ in 0..<100 {
        if await service.settingsOpens == 1 { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await service.settingsOpens == 1)
    await service.configure(.enabled)
    subject.refresh(); try await waitForLoginItem { !subject.loading }
    #expect(subject.statusText == "Enabled" && !subject.needsApproval)
    subject.setEnabled(false)
    await subject.stop() // Shutdown drains an authorized OS mutation.
    #expect(!subject.registered && !subject.changing)
    subject.setActive(true); try await waitForLoginItem { !subject.loading }
    await service.fail("Approval was denied")
    subject.setEnabled(true)
    try await waitForLoginItem { !subject.changing }
    #expect(subject.error == "Approval was denied" && subject.needsApproval)
    #expect(subject.registered) // Failure still rereads the changed OS status.
    await service.configure(.enabled)
    subject.refresh(); try await waitForLoginItem { !subject.loading }
    #expect(subject.error == nil && subject.statusText == "Enabled")
    await service.fail(nil)
    subject.setEnabled(false)
    try await waitForLoginItem { !subject.changing }
    #expect(subject.error == nil && !subject.registered)
    await subject.stop()
}

@MainActor @Test(.timeLimit(.minutes(1))) func loginItemDevelopmentGuardAllowsRemovalAndCancelsStaleReads() async throws {
    let service = LoginItemFixture()
    await service.configure(.notRegistered, unavailable: "Development build")
    let model = LoginItemViewModel(service: service)
    model.onAction = { [weak model] in model?.perform($0) }
    model.setActive(true); try await waitForLoginItem { !model.loading }
    #expect(!model.canToggle)
    model.setEnabled(true)
    #expect(await service.writes.isEmpty)
    await service.configure(.requiresApproval, unavailable: "Development build")
    model.refresh(); try await waitForLoginItem { !model.loading }
    #expect(model.canToggle && model.registered)
    model.setEnabled(false)
    try await waitForLoginItem { !model.changing }
    #expect(await service.writes == [false])
    await service.configure(.enabled)
    model.refresh()
    await model.stop()
    await service.configure(.notFound)
    model.setActive(true); try await waitForLoginItem { !model.loading }
    #expect(model.state?.status == .notFound && !model.canToggle)
    await service.configure(.unknown)
    model.refresh(); try await waitForLoginItem { !model.loading }
    #expect(!model.canToggle && model.statusText.contains("unknown"))
    await model.stop()
    #expect(LoginItemRegistrationPolicy.unavailableReason(debug: true, packaged: true) != nil)
    #expect(LoginItemRegistrationPolicy.unavailableReason(debug: false, packaged: false) != nil)
    #expect(LoginItemRegistrationPolicy.unavailableReason(debug: false, packaged: true) == nil)
}
