import AppKit
import AVFoundation
import Foundation

enum MicrophoneAccessStatus: Sendable, Equatable { case notDetermined, authorized, denied, restricted }

/// Microphone permission belongs to macOS. Terminal sessions and the agents they run inherit
/// Craft's grant, because TCC attributes a child process's audio input to the responsible app.
protocol MicrophoneAccessService: Sendable {
    func status() async -> MicrophoneAccessStatus
    /// Shows the system prompt when the status is undetermined; otherwise returns the current status.
    func requestAccess() async -> MicrophoneAccessStatus
    func openSystemSettings() async
}

actor NativeMicrophoneAccessService: MicrophoneAccessService {
    private static let privacyPane = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!

    func status() -> MicrophoneAccessStatus { Self.map(AVCaptureDevice.authorizationStatus(for: .audio)) }

    func requestAccess() async -> MicrophoneAccessStatus {
        guard status() == .notDetermined else { return status() }
        _ = await AVCaptureDevice.requestAccess(for: .audio)
        return status()
    }

    func openSystemSettings() async {
        await MainActor.run {
            guard !Task.isCancelled else { return }
            NSWorkspace.shared.open(Self.privacyPane)
        }
    }

    private static func map(_ status: AVAuthorizationStatus) -> MicrophoneAccessStatus {
        switch status {
        case .notDetermined: return .notDetermined
        case .authorized: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        @unknown default: return .restricted
        }
    }
}
