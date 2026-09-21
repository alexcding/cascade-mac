import Foundation
import Testing

private actor MicrophoneFixture: MicrophoneAccessService {
    var value = MicrophoneAccessStatus.notDetermined
    var granted = true
    var requests = 0
    var settingsOpens = 0
    func configure(_ status: MicrophoneAccessStatus) { value = status }
    func status() async -> MicrophoneAccessStatus {
        let snapshot = value
        try? await Task.sleep(for: .milliseconds(20))
        return snapshot
    }
    func requestAccess() async -> MicrophoneAccessStatus {
        requests += 1
        try? await Task.sleep(for: .milliseconds(20))
        if value == .notDetermined { value = granted ? .authorized : .denied }
        return value
    }
    func openSystemSettings() { settingsOpens += 1 }
}

@MainActor private func waitForMicrophone(_ condition: () -> Bool) async throws {
    for _ in 0..<300 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw BackendError.operation("Timed out waiting for microphone state")
}

@MainActor @Test(.timeLimit(.minutes(1))) func microphoneRequestsOnceThenReflectsSystemState() async throws {
    let service = MicrophoneFixture()
    let subject = MicrophoneAccessViewModel(service: service)
    #expect(subject.status == nil && !subject.canRequest)
    subject.requestAccess()
    #expect(await service.requests == 0)
    subject.setActive(true)
    try await waitForMicrophone { !subject.loading }
    #expect(subject.canRequest && !subject.canOpenSystemSettings)
    subject.requestAccess(); subject.requestAccess()
    #expect(subject.requesting)
    try await waitForMicrophone { !subject.requesting }
    #expect(await service.requests == 1)
    #expect(subject.authorized && !subject.canRequest && !subject.canOpenSystemSettings)
    await service.configure(.denied)
    subject.refresh(); try await waitForMicrophone { !subject.loading }
    #expect(subject.canOpenSystemSettings && subject.statusText.contains("Denied"))
    subject.openSystemSettings()
    for _ in 0..<100 {
        if await service.settingsOpens == 1 { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await service.settingsOpens == 1)
    // A policy restriction has no privacy-pane remedy, so the button stays hidden.
    await service.configure(.restricted)
    subject.refresh(); try await waitForMicrophone { !subject.loading }
    #expect(!subject.canOpenSystemSettings && !subject.canRequest && subject.statusText.contains("Restricted"))
    subject.retire()
    subject.openSystemSettings(); subject.requestAccess()
    #expect(!subject.canRequest && !subject.canOpenSystemSettings)
    #expect(await service.settingsOpens == 1)
    #expect(await service.requests == 1)
}
