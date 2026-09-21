import Foundation
import Testing

actor CLIFixture: CLISettingsService {
    var probes = 0
    var mutations: [String] = []
    var statuses = ["claude": "absent", "codex": "absent"]
    var fails = false
    var probeGate: ProjectPageGate?
    var hooksGate: ProjectPageGate?
    var mutationGate: ProjectPageGate?
    func fail(_ value: Bool) { fails = value }
    func holdProbe(_ gate: ProjectPageGate) { probeGate = gate }
    func holdHooks(_ gate: ProjectPageGate) { hooksGate = gate }
    func holdMutation(_ gate: ProjectPageGate) { mutationGate = gate }
    func probe() async throws -> [String: CLIAvailability] {
        probes += 1
        if let gate = probeGate { probeGate = nil; try await gate.wait() }
        try await Task.sleep(for: .milliseconds(100))
        if fails { throw BackendError.operation("Probe unavailable") }
        return ["gh": CLIAvailability(present: true, authed: nil), "claude": CLIAvailability(present: true)]
    }
    func hooks() async throws -> [String: String] {
        let result = statuses
        if let gate = hooksGate { hooksGate = nil; try await gate.wait() }
        try await Task.sleep(for: .milliseconds(20))
        return result
    }
    func setHook(_ cli: ManagedCLI, installed: Bool) async throws -> [String: String] {
        mutations.append(cli.rawValue)
        if let gate = mutationGate { mutationGate = nil; try await gate.wait() }
        try await Task.sleep(for: .milliseconds(30))
        if fails { throw BackendError.operation("Hook file unavailable") }
        statuses[cli.rawValue] = installed ? "installed" : "absent"
        return statuses
    }
}

@MainActor @Test(.timeLimit(.minutes(1))) func cliSettingsOldStopCannotClearReplacementProbeOrService() async throws {
    let old = CLIFixture(), fresh = CLIFixture(), oldGate = ProjectPageGate(), freshGate = ProjectPageGate()
    let model = CLISettingsViewModel(copy: { _ in }, openBrowser: { _ in true })
    await old.holdProbe(oldGate); model.connect(old); model.refresh(); await oldGate.waitForStart()
    let stop = Task { await model.stop() }
    while model.probing { await Task.yield() }
    await fresh.holdProbe(freshGate); model.connect(fresh); model.refresh(); await freshGate.waitForStart()
    await oldGate.finish(); await stop.value
    #expect(model.probing)
    model.refresh()
    #expect(await fresh.probes == 1)
    await freshGate.finish()
    while model.probing || model.loadingHooks { await Task.yield() }
    #expect(model.canChange(.claude) && model.label(.gh) == "Installed; sign-in status unavailable")
    await model.stop()
}

@MainActor @Test(.timeLimit(.minutes(1))) func cliSettingsLoadHooksIndependentlyAndRejectStaleReadsDuringEdits() async throws {
    let service = CLIFixture()
    let probeGate = ProjectPageGate(), hooksGate = ProjectPageGate(), mutationGate = ProjectPageGate()
    await service.holdProbe(probeGate)
    var copied: String?
    let model = CLISettingsViewModel(copy: { copied = $0 }, openBrowser: { _ in true })
    model.onAction = { [weak model] in model?.perform($0) }
    model.connect(service)
    #expect(await service.probes == 0) // construction/reconnect does not spawn probes
    model.refresh(); model.refresh()
    await probeGate.waitForStart()
    while model.loadingHooks { try await Task.sleep(for: .milliseconds(5)) }
    #expect(model.hooks["claude"] == "absent" && model.probing)
    #expect(await service.probes == 1)
    await service.holdHooks(hooksGate)
    model.refresh() // read captures the old hook status before the edit
    await hooksGate.waitForStart()
    await service.holdMutation(mutationGate)
    let edit = Task { await model.toggleHook(.claude) }
    while model.changing == nil { await Task.yield() }
    await hooksGate.finish()
    await mutationGate.waitForStart()
    await model.toggleHook(.claude)
    await mutationGate.finish()
    await edit.value
    while model.loadingHooks { try await Task.sleep(for: .milliseconds(5)) }
    #expect(await service.mutations == ["claude"])
    #expect(model.hooks["claude"] == "installed")
    await probeGate.finish()
    while model.probing { try await Task.sleep(for: .milliseconds(5)) }
    #expect(model.label(.gh) == "Installed; sign-in status unavailable")
    await service.fail(true)
    await model.toggleHook(.claude)
    #expect(model.hooks["claude"] == "installed" && model.hookError == "Hook file unavailable")
    model.refresh()
    while model.probing { try await Task.sleep(for: .milliseconds(5)) }
    #expect(model.availability["gh"]?.present == true && model.probeError == "Probe unavailable")
    model.copyLogin(.gh)
    #expect(copied == "gh auth login")
    model.copyInstall(.ghWebhook); model.copyInstall(.gh) // only the extension has a one-line install
    #expect(copied == "gh extension install cli/gh-webhook")
    #expect(CLIAvailability(present: true).label(for: .ghWebhook) == "Installed"
        && CLIAvailability(present: false).label(for: .ghWebhook) == "Not installed")
    await service.fail(false)
    await model.toggleHook(.claude)
    #expect(model.hooks["claude"] == "absent")
    await model.stop()
    #expect(!model.canChange(.claude))
}

@Test func cliStatusDistinguishesMissingSignedOutAndUnknownAuthorization() {
    #expect(CLIAvailability(present: false, authed: false).label(for: .gh) == "Not found")
    #expect(CLIAvailability(present: true, authed: false).label(for: .gh) == "Not signed in")
    #expect(CLIAvailability(present: true, authed: true).label(for: .acli) == "Signed in")
    #expect(CLIAvailability(present: true).label(for: .claude) == "Installed")
    #expect(CLIAvailability(present: true).label(for: .acli) == "Installed; sign-in status unavailable")
}
