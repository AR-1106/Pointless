import AppIntents
import AppKit

// MARK: - Intents

/// Exposed to Shortcuts and Siri (e.g. “Enable tracking in Pointless”).
struct EnablePointlessTrackingIntent: AppIntent {
    static var title: LocalizedStringResource = "Enable Pointless Tracking"
    static var description = IntentDescription("Starts camera hand tracking in Pointless.")
    /// Ensures the Pointless process is running before `perform`; required for menu-bar–only apps from Shortcuts.
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            NSApp.activate(ignoringOtherApps: true)
            AppDelegate.shared?.statusBarController?.enableTracking()
        }
        return .result()
    }
}

struct DisablePointlessTrackingIntent: AppIntent {
    static var title: LocalizedStringResource = "Disable Pointless Tracking"
    static var description = IntentDescription("Stops hand tracking in Pointless.")
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            NSApp.activate(ignoringOtherApps: true)
            AppDelegate.shared?.statusBarController?.disableTracking()
        }
        return .result()
    }
}

// MARK: - Siri phrase suggestions

/// Registers suggested Siri / Shortcuts phrases that include the app name for reliable routing.
struct PointlessAppShortcuts: AppShortcutsProvider {
    @AppShortcutsBuilder
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: EnablePointlessTrackingIntent(),
            phrases: [
                "Enable tracking in \(.applicationName)",
                "Start hand tracking in \(.applicationName)",
                "Turn on tracking in \(.applicationName)",
            ],
            shortTitle: "Enable tracking",
            systemImageName: "hand.point.up.left.fill"
        )
        AppShortcut(
            intent: DisablePointlessTrackingIntent(),
            phrases: [
                "Disable tracking in \(.applicationName)",
                "Stop hand tracking in \(.applicationName)",
                "Turn off tracking in \(.applicationName)",
            ],
            shortTitle: "Disable tracking",
            systemImageName: "hand.point.up.left"
        )
    }
}
