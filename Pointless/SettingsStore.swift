import Foundation
import Combine
import AppKit

/// Central, observable settings store backed by UserDefaults.
/// Every preference in the app funnels through here so controllers
/// can be configured and the Settings window stays in sync.
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    private enum Key {
        static let didCompleteOnboarding = "didCompleteOnboarding"
        static let selectedCameraID = "selectedCameraID"
        static let launchAtLogin = "launchAtLogin"
        static let showSkeletonOverlay = "showSkeletonOverlay"
        static let showCameraPreview = "showCameraPreview"
        static let mirrorCamera = "mirrorCamera"
        static let pinchSensitivity = "pinchSensitivity"
        static let scrollSensitivity = "scrollSensitivity"
        static let cursorSmoothing = "cursorSmoothing"
        static let hapticsEnabled = "hapticsEnabled"
        static let soundEffectsEnabled = "soundEffectsEnabled"
        static let autoStartTracking = "autoStartTracking"
        static let cameraDiagnosticLogging = "cameraDiagnosticLogging"
    }

    private let defaults = UserDefaults.standard

    init() {
        registerDefaults()
    }

    private func registerDefaults() {
        defaults.register(defaults: [
            Key.didCompleteOnboarding: false,
            Key.launchAtLogin: false,
            Key.showSkeletonOverlay: true,
            Key.showCameraPreview: true,
            Key.mirrorCamera: true,
            Key.pinchSensitivity: 0.5,
            Key.scrollSensitivity: 0.5,
            Key.cursorSmoothing: 0.5,
            Key.hapticsEnabled: true,
            Key.soundEffectsEnabled: false,
            Key.autoStartTracking: false,
            Key.cameraDiagnosticLogging: false
        ])
    }

    var didCompleteOnboarding: Bool {
        get { defaults.bool(forKey: Key.didCompleteOnboarding) }
        set {
            defaults.set(newValue, forKey: Key.didCompleteOnboarding)
            objectWillChange.send()
        }
    }

    var selectedCameraID: String? {
        get { defaults.string(forKey: Key.selectedCameraID) }
        set {
            let old = defaults.string(forKey: Key.selectedCameraID)
            if old == newValue { return }
            if let newValue {
                defaults.set(newValue, forKey: Key.selectedCameraID)
            } else {
                defaults.removeObject(forKey: Key.selectedCameraID)
            }
            objectWillChange.send()
            NotificationCenter.default.post(name: .pointlessSelectedCameraChanged, object: newValue)
        }
    }

    var launchAtLogin: Bool {
        get { defaults.bool(forKey: Key.launchAtLogin) }
        set {
            defaults.set(newValue, forKey: Key.launchAtLogin)
            objectWillChange.send()
        }
    }

    var showSkeletonOverlay: Bool {
        get { defaults.bool(forKey: Key.showSkeletonOverlay) }
        set {
            defaults.set(newValue, forKey: Key.showSkeletonOverlay)
            objectWillChange.send()
            NotificationCenter.default.post(name: .pointlessDisplaySettingsChanged, object: nil)
        }
    }

    var showCameraPreview: Bool {
        get { defaults.bool(forKey: Key.showCameraPreview) }
        set {
            defaults.set(newValue, forKey: Key.showCameraPreview)
            objectWillChange.send()
            NotificationCenter.default.post(name: .pointlessDisplaySettingsChanged, object: nil)
        }
    }

    var mirrorCamera: Bool {
        get { defaults.bool(forKey: Key.mirrorCamera) }
        set {
            defaults.set(newValue, forKey: Key.mirrorCamera)
            objectWillChange.send()
            NotificationCenter.default.post(name: .pointlessDisplaySettingsChanged, object: nil)
        }
    }

    /// Normalized 0..1; higher means more sensitive (smaller pinch required).
    var pinchSensitivity: Double {
        get { defaults.double(forKey: Key.pinchSensitivity) }
        set {
            defaults.set(newValue, forKey: Key.pinchSensitivity)
            objectWillChange.send()
            NotificationCenter.default.post(name: .pointlessGestureSettingsChanged, object: nil)
        }
    }

    /// Normalized 0..1; scales the scroll delta multiplier.
    var scrollSensitivity: Double {
        get { defaults.double(forKey: Key.scrollSensitivity) }
        set {
            defaults.set(newValue, forKey: Key.scrollSensitivity)
            objectWillChange.send()
            NotificationCenter.default.post(name: .pointlessGestureSettingsChanged, object: nil)
        }
    }

    /// Normalized 0..1; higher means more smoothing (more latency, less jitter).
    var cursorSmoothing: Double {
        get { defaults.double(forKey: Key.cursorSmoothing) }
        set {
            defaults.set(newValue, forKey: Key.cursorSmoothing)
            objectWillChange.send()
        }
    }

    var hapticsEnabled: Bool {
        get { defaults.bool(forKey: Key.hapticsEnabled) }
        set {
            defaults.set(newValue, forKey: Key.hapticsEnabled)
            objectWillChange.send()
        }
    }

    var soundEffectsEnabled: Bool {
        get { defaults.bool(forKey: Key.soundEffectsEnabled) }
        set {
            defaults.set(newValue, forKey: Key.soundEffectsEnabled)
            objectWillChange.send()
        }
    }

    var autoStartTracking: Bool {
        get { defaults.bool(forKey: Key.autoStartTracking) }
        set {
            defaults.set(newValue, forKey: Key.autoStartTracking)
            objectWillChange.send()
        }
    }

    /// Verbose camera discovery + session checkpoints in unified logging (Console.app).
    var cameraDiagnosticLogging: Bool {
        get { defaults.bool(forKey: Key.cameraDiagnosticLogging) }
        set {
            defaults.set(newValue, forKey: Key.cameraDiagnosticLogging)
            objectWillChange.send()
        }
    }

    // MARK: - Derived gesture params

    /// Maps pinchSensitivity (0..1) into the actual normalized-distance threshold.
    /// 0 -> 0.06 (less sensitive), 1 -> 0.025 (very sensitive).
    var derivedPinchThreshold: CGFloat {
        let t = CGFloat(pinchSensitivity.clamped(to: 0...1))
        return 0.06 - (0.06 - 0.025) * t
    }

    /// Maps scrollSensitivity into a delta multiplier for scroll events.
    var derivedScrollMultiplier: CGFloat {
        let t = CGFloat(scrollSensitivity.clamped(to: 0...1))
        return 0.5 + t * 2.5
    }
}

extension Notification.Name {
    static let pointlessSelectedCameraChanged = Notification.Name("pointless.selectedCameraChanged")
    static let pointlessGestureSettingsChanged = Notification.Name("pointless.gestureSettingsChanged")
    static let pointlessDisplaySettingsChanged = Notification.Name("pointless.displaySettingsChanged")
    static let pointlessOnboardingFinished = Notification.Name("pointless.onboardingFinished")
    static let pointlessRequestShowOnboarding = Notification.Name("pointless.requestShowOnboarding")
    static let pointlessTrackingStateChanged = Notification.Name("pointless.trackingStateChanged")
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
