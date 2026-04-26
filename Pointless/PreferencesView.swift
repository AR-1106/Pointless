import SwiftUI
import AppKit
import AVFoundation
import ServiceManagement

/// Top-level SwiftUI view for the `Settings` scene.
/// Uses a native sidebar so it picks up Liquid Glass on macOS 26
/// without any custom materials.
struct PreferencesView: View {
    enum Section: String, Hashable, CaseIterable {
        case general, camera, gestures, updates, about
        var title: String {
            switch self {
            case .general: return "General"
            case .camera: return "Camera"
            case .gestures: return "Gestures"
            case .updates: return "Updates"
            case .about: return "About"
            }
        }
        var symbol: String {
            switch self {
            case .general: return "gearshape"
            case .camera: return "camera"
            case .gestures: return "hand.tap"
            case .updates: return "arrow.down.circle"
            case .about: return "info.circle"
            }
        }
    }

    @State private var selection: Section = .general

    var body: some View {
        NavigationSplitView {
            List(Section.allCases, id: \.self, selection: $selection) { section in
                Label(section.title, systemImage: section.symbol)
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 220)
        } detail: {
            Group {
                switch selection {
                case .general: GeneralPane()
                case .camera: CameraPane()
                case .gestures: GesturesPane()
                case .updates: UpdatesPane()
                case .about: AboutPane()
                }
            }
            .navigationSplitViewColumnWidth(min: 420, ideal: 480)
        }
        .frame(minWidth: 640, minHeight: 440)
    }
}

// MARK: - Panes

private struct GeneralPane: View {
    @ObservedObject private var settings = SettingsStore.shared

    var body: some View {
        Form {
            SwiftUI.Section("Startup") {
                Toggle("Launch Pointless at login", isOn: Binding(
                    get: { settings.launchAtLogin },
                    set: { newValue in
                        settings.launchAtLogin = newValue
                        applyLaunchAtLogin(newValue)
                    }
                ))
                Toggle("Start tracking automatically", isOn: Binding(
                    get: { settings.autoStartTracking },
                    set: { settings.autoStartTracking = $0 }
                ))
            }
            SwiftUI.Section("Display") {
                Toggle("Show on-screen hand skeleton", isOn: Binding(
                    get: { settings.showSkeletonOverlay },
                    set: { settings.showSkeletonOverlay = $0 }
                ))
                Toggle("Show camera preview", isOn: Binding(
                    get: { settings.showCameraPreview },
                    set: { settings.showCameraPreview = $0 }
                ))
            }
            SwiftUI.Section("Feedback") {
                Toggle("Haptic feedback on click", isOn: Binding(
                    get: { settings.hapticsEnabled },
                    set: { settings.hapticsEnabled = $0 }
                ))
                Toggle("Sound effects", isOn: Binding(
                    get: { settings.soundEffectsEnabled },
                    set: { settings.soundEffectsEnabled = $0 }
                ))
            }
            SwiftUI.Section("Onboarding") {
                Button("Replay onboarding") {
                    NotificationCenter.default.post(name: .pointlessRequestShowOnboarding, object: nil)
                }
            }
        }
        .formStyle(.grouped)
        .padding(.horizontal, 4)
    }

    private func applyLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            print("Failed to toggle launch-at-login: \(error)")
        }
    }
}

private struct CameraPane: View {
    @ObservedObject private var settings = SettingsStore.shared
    @State private var cameras: [AVCaptureDevice] = []

    var body: some View {
        Form {
            SwiftUI.Section("Source") {
                Picker("Camera", selection: Binding(
                    get: { settings.selectedCameraID ?? "__default__" },
                    set: { newValue in
                        settings.selectedCameraID = (newValue == "__default__") ? nil : newValue
                    }
                )) {
                    Text("System Default").tag("__default__")
                    ForEach(cameras, id: \.uniqueID) { device in
                        Text(device.localizedName).tag(device.uniqueID)
                    }
                }
                .pickerStyle(.menu)
                Toggle("Mirror camera feed", isOn: Binding(
                    get: { settings.mirrorCamera },
                    set: { settings.mirrorCamera = $0 }
                ))
            }
            SwiftUI.Section {
                Button("Refresh camera list") {
                    loadCameras()
                }
            }
            SwiftUI.Section("Diagnostics") {
                Toggle("Verbose camera logging", isOn: Binding(
                    get: { settings.cameraDiagnosticLogging },
                    set: { settings.cameraDiagnosticLogging = $0 }
                ))
                Text(diagnosticHelp)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .padding(.horizontal, 4)
        .onAppear(perform: loadCameras)
    }

    private var diagnosticHelp: String {
        let bid = Bundle.main.bundleIdentifier ?? "Pointless"
        return """
        Open Console.app, select process “Pointless”, enable Info messages in the toolbar, then enable tracking. \
        Filter by subsystem “\(bid)” and category “Camera”. \
        Look for “First video frame received” (pipeline OK) or errors / “delayed startRunning skipped”.
        """
    }

    private func loadCameras() {
        cameras = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external],
            mediaType: .video,
            position: .unspecified
        ).devices
    }
}

private struct GesturesPane: View {
    @ObservedObject private var settings = SettingsStore.shared

    var body: some View {
        Form {
            SwiftUI.Section("Pinch click") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Sensitivity: \(percentLabel(settings.pinchSensitivity))")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Slider(value: Binding(
                        get: { settings.pinchSensitivity },
                        set: { settings.pinchSensitivity = $0 }
                    ), in: 0...1)
                }
            }
            SwiftUI.Section("Scroll") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Sensitivity: \(percentLabel(settings.scrollSensitivity))")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Slider(value: Binding(
                        get: { settings.scrollSensitivity },
                        set: { settings.scrollSensitivity = $0 }
                    ), in: 0...1)
                }
            }
            SwiftUI.Section("Cursor") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Smoothing: \(percentLabel(settings.cursorSmoothing))")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Slider(value: Binding(
                        get: { settings.cursorSmoothing },
                        set: { settings.cursorSmoothing = $0 }
                    ), in: 0...1)
                }
            }
        }
        .formStyle(.grouped)
        .padding(.horizontal, 4)
    }

    private func percentLabel(_ v: Double) -> String {
        "\(Int((v * 100).rounded()))%"
    }
}

private struct UpdatesPane: View {
    var body: some View {
        Form {
            SwiftUI.Section("Automatic updates") {
                Text("Pointless ships via a notarized DMG and auto-updates using Sparkle. On first release you'll be able to toggle update channels here.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Button("Check for Updates") {
                    NotificationCenter.default.post(name: Notification.Name("SUUpdaterCheckForUpdates"), object: nil)
                }
            }
        }
        .formStyle(.grouped)
        .padding(.horizontal, 4)
    }
}

private struct AboutPane: View {
    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(short) (\(build))"
    }

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "hand.point.up.left.fill")
                .font(.system(size: 64, weight: .medium))
                .foregroundStyle(Color(nsColor: .systemIndigo))
                .padding(.top, 24)
            Text("Pointless")
                .font(.system(size: 24, weight: .semibold, design: .rounded))
            Text("Version \(version)")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text("Hands-free cursor control for macOS.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Spacer()
            HStack(spacing: 14) {
                Link("Website", destination: URL(string: "https://pointless.app")!)
                Link("Privacy", destination: URL(string: "https://pointless.app/privacy")!)
                Link("Support", destination: URL(string: "mailto:support@pointless.app")!)
            }
            .font(.system(size: 12))
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
