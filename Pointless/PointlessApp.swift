import SwiftUI
import AppKit
import AppIntents

@main
struct PointlessApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Camera and other choices live in the menu bar; keep an empty Settings
        // scene so SwiftUI has a valid App body without a Dock-facing window.
        Settings { EmptyView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// `NSApplication.shared.delegate` is not `AppDelegate` under SwiftUI lifecycle — use this for App Intents / URLs.
    private(set) static weak var shared: AppDelegate?

    var statusBarController: StatusBarController?
    var onboardingController: OnboardingWindowController?

    private var onboardingReplayObserver: NSObjectProtocol?
    private var onboardingFinishedObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self

        NSApp.setActivationPolicy(.accessory)

        PermissionsManager.shared.startWatching()

        statusBarController = StatusBarController()

        if !SettingsStore.shared.didCompleteOnboarding || !PermissionsManager.shared.allGranted {
            showOnboarding()
        } else if SettingsStore.shared.autoStartTracking {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.statusBarController?.toggleTracking()
            }
        }

        onboardingReplayObserver = NotificationCenter.default.addObserver(
            forName: .pointlessRequestShowOnboarding,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.showOnboarding()
        }

        onboardingFinishedObserver = NotificationCenter.default.addObserver(
            forName: .pointlessOnboardingFinished,
            object: nil,
            queue: .main
        ) { _ in
            PermissionsManager.shared.refresh()
        }

        PointlessAppShortcuts.updateAppShortcutParameters()
    }

    func applicationWillTerminate(_ notification: Notification) {
        Self.shared = nil
        if let obs = onboardingReplayObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        if let obs = onboardingFinishedObserver {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    private func showOnboarding() {
        if onboardingController == nil {
            onboardingController = OnboardingWindowController()
        }
        onboardingController?.show()
    }

    /// Shortcuts / Siri: add an "Open URL" step with `pointless://toggle-tracking`
    /// (or run a shortcut by voice: "Run [shortcut name]").
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard url.scheme?.lowercased() == "pointless" else { continue }
            let host = (url.host ?? "").lowercased()
            switch host {
            case "toggle-tracking", "track", "":
                statusBarController?.toggleTracking()
            default:
                break
            }
        }
    }
}
