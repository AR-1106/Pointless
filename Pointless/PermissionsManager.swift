import Foundation
import Combine
import AppKit
import AVFoundation
import ApplicationServices

enum PermissionStatus {
    case granted
    case denied
    case notDetermined
}

/// Central place to query & request Camera + Accessibility permissions.
///
/// Accessibility status is observed on a timer because macOS does not expose a
/// push notification when the user flips the toggle in System Settings.
final class PermissionsManager: ObservableObject {
    static let shared = PermissionsManager()

    @Published private(set) var cameraStatus: PermissionStatus = .notDetermined
    @Published private(set) var accessibilityStatus: PermissionStatus = .notDetermined

    private var pollingTimer: Timer?

    private init() {
        refresh()
    }

    // MARK: - Query

    func refresh() {
        cameraStatus = currentCameraStatus()
        accessibilityStatus = currentAccessibilityStatus()
    }

    private func currentCameraStatus() -> PermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }

    private func currentAccessibilityStatus() -> PermissionStatus {
        AXIsProcessTrusted() ? .granted : .notDetermined
    }

    var allGranted: Bool {
        cameraStatus == .granted && accessibilityStatus == .granted
    }

    // MARK: - Request

    func requestCamera(_ completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            DispatchQueue.main.async {
                self?.cameraStatus = granted ? .granted : .denied
                completion(granted)
            }
        }
    }

    /// Shows the native Accessibility prompt by passing the prompt option.
    /// Returns immediately; the user must grant via System Settings.
    func promptAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue()
        let options = [key as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        refresh()
    }

    // MARK: - Deep links

    func openCameraSystemSettings() {
        openSystemSettings(url: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")
    }

    func openAccessibilitySystemSettings() {
        openSystemSettings(url: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    private func openSystemSettings(url: String) {
        guard let url = URL(string: url) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Watchdog

    /// Start polling accessibility + camera status so UI can react when the
    /// user flips the toggle in System Settings.
    func startWatching() {
        stopWatching()
        pollingTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(pollingTimer!, forMode: .common)
    }

    func stopWatching() {
        pollingTimer?.invalidate()
        pollingTimer = nil
    }
}
