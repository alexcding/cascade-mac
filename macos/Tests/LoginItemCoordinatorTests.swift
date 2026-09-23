import Foundation
import Testing

private actor LoginActionService: LoginItemService {
    var value = LoginItemState(status: .notRegistered, registrationUnavailableReason: nil)
    var writes: [Bool] = []
    var reads = 0, opens = 0, cancelledOpens = 0
    private var readGate: ProjectPageGate?
    private var writeGate: ProjectPageGate?
    private var openGate: ProjectPageGate?
    private var failure: String?
    func configure(_ status: LoginItemStatus) { value = .init(status: status, registrationUnavailableReason: nil) }
    func holdRead(_ gate: ProjectPageGate) { readGate = gate }
    func holdWrite(_ gate: ProjectPageGate) { writeGate = gate }
    func holdOpen(_ gate: ProjectPageGate) { openGate = gate }
    func fail(_ message: String) { failure = message }
    func state() async -> LoginItemState {
        reads += 1
        let snapshot = value
        if let gate = readGate { readGate = nil; try? await gate.wait() }
        return snapshot
    }
    func setEnabled(_ enabled: Bool) async throws {
        writes.append(enabled)
        if let gate = writeGate { writeGate = nil; try await gate.wait() }
        value = .init(status: enabled ? .requiresApproval : .notRegistered, registrationUnavailableReason: nil)
        if let failure { throw BackendError.operation(failure) }
    }
    func openSystemSettings() async {
        if let gate = openGate { openGate = nil; try? await gate.wait() }
        guard !Task.isCancelled else { cancelledOpens += 1; return }
        opens += 1
    }
}

private struct LoginActionFonts: CodeFontCatalog {
    func families() async -> [String] { [] }
}

@MainActor private func loginSettings(_ service: any LoginItemService) -> SettingsViewModel {
    NativeSettingsFeatureFactory(desktop: ProjectPageActions(), copy: { _ in }, loginItem: service, fontCatalog: LoginActionFonts()).settings()
}

@MainActor @Test(.timeLimit(.minutes(1))) func loginItemIntentsRequireActiveGeneralSectionOwnershipAndPresentationAvailability() async throws {
    let service = LoginActionService(), model = loginSettings(service), runtime = SettingsRuntimeFixture()
    let root = AppCoordinator(factory: NativeCreationFlowFactory(chooseFolder: { nil }))
    let child = root.installSettings(model, runtime: runtime), login = model.loginItem
    login.setEnabled(true); login.openSystemSettings()
    #expect(await service.writes.isEmpty)
    #expect(await service.opens == 0)
    root.setSettingsPresented(true); model.section = .general
    while login.loading { await Task.yield() }
    #expect(login.canToggle && !login.registered && !login.canOpenSystemSettings)
    model.section = .editor
    login.setEnabled(true); login.openSystemSettings()
    #expect(await service.writes.isEmpty)
    model.section = .general
    while login.loading { await Task.yield() }
    root.presentNewProject(service: ProjectPageService(), didSave: { _ in })
    login.setEnabled(true)
    #expect(await service.writes.isEmpty)
    root.dismissSheet(id: try #require(root.sheet).id)
    let ownership = child.isOwned; child.isOwned = { false }
    login.setEnabled(true); #expect(await service.writes.isEmpty)
    child.isOwned = ownership
    let gate = ProjectPageGate(); await service.holdWrite(gate)
    login.setEnabled(true); login.setEnabled(true)
    await gate.waitForStart()
    #expect(login.changing && !login.registered && !login.canToggle)
    root.setSettingsPresented(false)
    await gate.finish(); await login.waitForMutation()
    #expect(await service.writes == [true])
    #expect(login.registered && login.needsApproval && !login.active && !login.canToggle)
    root.setSettingsPresented(true); model.section = .general
    while login.loading { await Task.yield() }
    #expect(login.canOpenSystemSettings)
    let opening = ProjectPageGate(); await service.holdOpen(opening)
    login.openSystemSettings(); await opening.waitForStart()
    root.presentNewProject(service: ProjectPageService(), didSave: { _ in })
    #expect(!login.openingSettings && root.sheet != nil)
    await opening.finish()
    while await service.cancelledOpens == 0 { await Task.yield() }
    #expect(await service.opens == 0)
    root.dismissSheet(id: try #require(root.sheet).id)
    child.retire(); login.setEnabled(false); login.openSystemSettings()
    login.setActive(true); login.refresh(); login.setEnabled(false); login.openSystemSettings()
    #expect(login.retired && !login.active && !login.loading && !login.canToggle)
    #expect(await service.writes == [true])
    #expect(await service.opens == 0)
}

@MainActor @Test(.timeLimit(.minutes(1)), arguments: [false, true])
func loginItemAcceptedMutationDrainsOnStopOrRetirementWithoutAcceptingStaleCallbacks(retire: Bool) async throws {
    let service = LoginActionService(), model = loginSettings(service), runtime = SettingsRuntimeFixture()
    let root = AppCoordinator(factory: NativeCreationFlowFactory(chooseFolder: { nil }))
    let old = root.installSettings(model, runtime: runtime), login = model.loginItem
    root.setSettingsPresented(true); model.section = .general
    while login.loading { await Task.yield() }
    let gate = ProjectPageGate(); await service.holdWrite(gate)
    if retire { await service.fail("Fixture approval required") }
    login.setEnabled(true); await gate.waitForStart()
    if retire {
        root.installSettings(loginSettings(service), runtime: runtime)
        #expect(root.settingsCoordinator?.model.loginItem.changing == true)
        #expect(root.settingsCoordinator?.model.loginItem.canToggle == false)
    }
    let stop = Task { await login.stop() }
    while login.active { await Task.yield() }
    login.setEnabled(false)
    #expect(login.changing)
    await gate.finish(); await stop.value
    #expect(await service.writes == [true])
    #expect(await service.state().status == .requiresApproval)
    #expect(!login.changing && !login.active)
    if retire {
        await root.settingsCoordinator?.model.loginItem.waitForMutation()
        #expect(old.retired && login.retired && login.state?.status == .notRegistered)
        #expect(root.settingsCoordinator?.model.loginItem.needsApproval == true)
        #expect(root.settingsCoordinator?.model.loginItem.error == "Fixture approval required")
        login.setEnabled(false); login.setActive(true); login.setEnabled(false)
        #expect(await service.writes == [true])
    } else { #expect(login.registered && login.needsApproval) }
    root.settingsCoordinator?.retire()
}

@MainActor @Test(.timeLimit(.minutes(1))) func loginItemCancelsPendingSettingsOpenWithoutClearingANewerOpen() async throws {
    let service = LoginActionService(); await service.configure(.requiresApproval)
    let model = loginSettings(service), runtime = SettingsRuntimeFixture()
    let root = AppCoordinator(factory: NativeCreationFlowFactory(chooseFolder: { nil }))
    root.installSettings(model, runtime: runtime); root.setSettingsPresented(true)
    model.section = .general
    let login = model.loginItem
    while login.loading { await Task.yield() }
    let first = ProjectPageGate(); await service.holdOpen(first)
    login.openSystemSettings(); login.openSystemSettings(); await first.waitForStart()
    #expect(login.openingSettings && !login.canOpenSystemSettings)
    model.section = .editor
    #expect(!login.openingSettings && !login.active)
    model.section = .general
    while login.loading { await Task.yield() }
    let second = ProjectPageGate(); await service.holdOpen(second)
    login.openSystemSettings(); await second.waitForStart()
    await first.finish()
    while await service.cancelledOpens == 0 { await Task.yield() }
    #expect(login.openingSettings)
    #expect(await service.opens == 0)
    await second.finish(); await login.waitForSettingsOpen()
    #expect(await service.opens == 1)
    #expect(!login.openingSettings && login.canOpenSystemSettings)
    let retired = ProjectPageGate(); await service.holdOpen(retired)
    login.openSystemSettings(); await retired.waitForStart()
    root.installSettings(loginSettings(service), runtime: runtime)
    await retired.finish()
    while await service.cancelledOpens < 2 { await Task.yield() }
    #expect(await service.opens == 1)
    #expect(login.retired && !login.openingSettings)
    root.settingsCoordinator?.retire()
}

@MainActor @Test(.timeLimit(.minutes(1))) func loginItemOldReadsCannotOverwriteNewSectionReadsAndUnwiredIntentsDoNothing() async throws {
    let service = LoginActionService(), login = LoginItemViewModel(service: service)
    let first = ProjectPageGate(); await service.holdRead(first)
    login.setActive(true); await first.waitForStart()
    login.setActive(false)
    await service.configure(.requiresApproval)
    let second = ProjectPageGate(); await service.holdRead(second)
    login.setActive(true); await second.waitForStart()
    await first.finish(); await Task.yield()
    #expect(login.loading && login.state == nil)
    await second.finish()
    while login.loading { await Task.yield() }
    #expect(login.registered && login.needsApproval)
    login.setEnabled(false); login.openSystemSettings()
    #expect(await service.writes.isEmpty)
    #expect(await service.opens == 0)
    login.retire(); login.refresh()
    #expect(!login.loading && !login.canToggle && !login.canOpenSystemSettings)
}

@MainActor @Test(.timeLimit(.minutes(1))) func loginItemCallbacksCannotActAfterSettingsRuntimeIsReleased() async throws {
    let service = LoginActionService(); await service.configure(.requiresApproval)
    let model = loginSettings(service), root = AppCoordinator(factory: NativeCreationFlowFactory(chooseFolder: { nil }))
    var runtime: SettingsRuntimeFixture? = SettingsRuntimeFixture()
    weak var released = runtime
    root.installSettings(model, runtime: runtime!); root.setSettingsPresented(true)
    while model.loginItem.loading { await Task.yield() }
    runtime = nil
    #expect(released == nil)
    model.loginItem.setEnabled(false); model.loginItem.openSystemSettings()
    #expect(await service.writes.isEmpty)
    #expect(await service.opens == 0)
    root.setSettingsPresented(false)
    #expect(!model.active && !model.loginItem.active)
    root.setSettingsPresented(true)
    #expect(!model.active && !model.loginItem.active)
    root.settingsCoordinator?.retire()
}
