import AppKit
import SwiftUI

/// Controller that owns the onboarding NSWindow and dismisses it
/// when the user finishes (or skips) the flow.
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    func show(completion: (() -> Void)? = nil) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let size = NSSize(width: 520, height: 520)
        let screen = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
        let origin = NSPoint(
            x: screen.midX - size.width / 2,
            y: screen.midY - size.height / 2
        )

        let w = NSWindow(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.isMovableByWindowBackground = true
        w.backgroundColor = .windowBackgroundColor
        w.isOpaque = true
        w.hasShadow = true
        w.level = .normal
        w.delegate = self

        let host = NSHostingView(
            rootView: OnboardingRootView { [weak self] in
                self?.finish()
                completion?()
            }
        )
        host.translatesAutoresizingMaskIntoConstraints = false
        w.contentView = host

        window = w
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    func finish() {
        SettingsStore.shared.didCompleteOnboarding = true
        // Closing the hosting window synchronously from the primary button action can
        // tear down SwiftUI mid-transaction (objc_release / “entangling fence” issues)
        // and leave AppKit in a bad state for the status item menu. Finish on the next turn.
        // Disable the close animation before closing: the default titled-window close
        // animation creates an NSWindowTransformAnimation whose block-captures can race
        // with the activation-policy change queued below, causing EXC_BAD_ACCESS in
        // _NSWindowTransformAnimation dealloc.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            self.window?.animationBehavior = .none
            self.window?.close()
            NotificationCenter.default.post(name: .pointlessOnboardingFinished, object: nil)
        }
    }

    func close() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === window else { return }
        window = nil
        // Use asyncAfter so the activation-policy change fires well after the window
        // is fully removed from the screen — avoids any residual AppKit animation
        // (e.g. NSWindowTransformAnimation) referencing the now-closed window.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

// MARK: - SwiftUI flow

private enum OnboardingStep: Int, CaseIterable {
    case welcome
    case camera
    case accessibility
    case tutorial
    case ready

    var title: String {
        switch self {
        case .welcome: return "Meet Pointless"
        case .camera: return "Camera access"
        case .accessibility: return "Accessibility access"
        case .tutorial: return "Your first gestures"
        case .ready: return "You're all set"
        }
    }

    var subtitle: String {
        switch self {
        case .welcome: return "Move your cursor with just your hand."
        case .camera: return "Pointless needs your camera so it can see your hand. Frames never leave your Mac."
        case .accessibility: return "Pointless needs Accessibility access to move the cursor and click on your behalf."
        case .tutorial: return "Try these three gestures."
        case .ready: return "Head to the menu bar, click the hand icon, and enable tracking."
        }
    }
}

private struct OnboardingRootView: View {
    /// Must be `@ObservedObject`: `@StateObject` takes ownership and can crash
    /// with `EXC_BAD_ACCESS` in `objc_retain` when tearing down an `NSHostingView`.
    @ObservedObject private var permissions = PermissionsManager.shared
    @State private var step: OnboardingStep = .welcome
    let onFinish: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.top, 28)
                .padding(.horizontal, 36)
                .padding(.bottom, 8)

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 36)
                .padding(.vertical, 20)
                .transition(.opacity.combined(with: .offset(y: 8)))

            footer
                .padding(.horizontal, 36)
                .padding(.bottom, 24)
        }
        .frame(width: 520, height: 520)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        VStack(spacing: 14) {
            HStack(spacing: 6) {
                ForEach(OnboardingStep.allCases, id: \.rawValue) { s in
                    Capsule()
                        .fill(s.rawValue <= step.rawValue ? Color.accentColor : Color.secondary.opacity(0.25))
                        .frame(height: 3)
                        .animation(Motion.snappy, value: step)
                }
            }
            Text(step.title)
                .font(.system(size: 22, weight: .semibold, design: .default))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
            Text(step.subtitle)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var content: some View {
        VStack {
            switch step {
            case .welcome:
                WelcomeCard()
            case .camera:
                PermissionCard(
                    symbol: "camera.fill",
                    title: "Grant camera access",
                    description: "Frames are analyzed on-device using Apple's Vision framework and immediately discarded. Nothing is uploaded.",
                    status: permissions.cameraStatus,
                    actionLabel: permissions.cameraStatus == .granted ? "Granted" : "Grant Access",
                    action: { permissions.requestCamera { _ in } }
                )
            case .accessibility:
                PermissionCard(
                    symbol: "hand.point.up.left.fill",
                    title: "Grant accessibility access",
                    description: "This lets Pointless move the cursor and send clicks when you pinch.\n\n(If you enabled it but it's stuck, remove Pointless with the '-' button and add it back.)",
                    status: permissions.accessibilityStatus,
                    actionLabel: permissions.accessibilityStatus == .granted ? "Granted" : "Open System Settings",
                    action: {
                        permissions.promptAccessibility()
                        permissions.openAccessibilitySystemSettings()
                    }
                )
            case .tutorial:
                TutorialCard()
            case .ready:
                ReadyCard()
            }
        }
        .animation(Motion.spring, value: step)
    }

    private var footer: some View {
        HStack {
            if step != .welcome && step != .ready {
                Button("Back") {
                    withAnimation(Motion.smooth) { back() }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .keyboardShortcut(.leftArrow, modifiers: [])
            }
            Spacer()
            Button(primaryButtonTitle) {
                // Don't wrap in withAnimation on the last step — closing the hosting
                // window inside a live SwiftUI transaction causes EXC_BAD_ACCESS.
                if let last = OnboardingStep.allCases.last, step == last {
                    next()
                } else {
                    withAnimation(Motion.smooth) { next() }
                }
            }
            .id(primaryCTAIdentity)
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            // Without this, macOS 26’s default button hover/focus plate can lay out wider than the visible fill.
            .fixedSize(horizontal: true, vertical: false)
            .keyboardShortcut(.return, modifiers: [])
            .disabled(!canAdvance)
        }
    }

    /// New identity when copy or step changes so Liquid Glass hover chrome isn’t stuck at the old size.
    private var primaryCTAIdentity: String {
        "\(step.rawValue)-\(primaryButtonTitle)"
    }

    private var primaryButtonTitle: String {
        switch step {
        case .welcome: return "Get started"
        case .camera, .accessibility, .tutorial: return "Continue"
        case .ready: return "Open Pointless"
        }
    }

    private var canAdvance: Bool {
        switch step {
        case .camera: return permissions.cameraStatus == .granted
        case .accessibility: return permissions.accessibilityStatus == .granted
        default: return true
        }
    }

    private func next() {
        if let last = OnboardingStep.allCases.last, step == last {
            onFinish()
            return
        }
        if let nextStep = OnboardingStep(rawValue: step.rawValue + 1) {
            step = nextStep
        }
    }

    private func back() {
        if let prev = OnboardingStep(rawValue: step.rawValue - 1) {
            step = prev
        }
    }
}

// MARK: - Cards (minimal, no tinted backgrounds)

private struct WelcomeCard: View {
    var body: some View {
        VStack(spacing: 28) {
            Image(systemName: "hand.point.up.left.fill")
                .font(.system(size: 56, weight: .regular))
                .foregroundStyle(.secondary)
                .symbolRenderingMode(.hierarchical)
            VStack(spacing: 8) {
                Text("Pinch and release to tap. Pinch and move your middle finger to scroll.")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
                Text("Your trackpad still works. Use both.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct PermissionCard: View {
    let symbol: String
    let title: String
    let description: String
    let status: PermissionStatus
    let actionLabel: String
    let action: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: status == .granted ? "checkmark.circle.fill" : symbol)
                .font(.system(size: 44, weight: .regular))
                .foregroundStyle(status == .granted ? .primary : .secondary)
                .symbolRenderingMode(.hierarchical)
                .contentTransition(.symbolEffect(.replace))
            VStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(description)
                    .font(.system(size: 13))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(actionLabel, action: action)
                .disabled(status == .granted)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct TutorialCard: View {
    private let items: [(String, String, String)] = [
        ("hand.pinch.fill", "Tap", "Pinch, then open your hand — like a light tap."),
        ("arrow.up.and.down", "Scroll", "Stay pinched and move your middle finger up or down.")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, row in
                let (icon, name, desc) = row
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: icon)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, alignment: .center)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.primary)
                        Text(desc)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 12)
                if index < items.count - 1 {
                    Divider()
                }
            }
        }
    }
}

private struct ReadyCard: View {
    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 52, weight: .regular))
                .foregroundStyle(.secondary)
                .symbolRenderingMode(.hierarchical)
            VStack(spacing: 6) {
                Text("Look for the hand icon")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                Label("Top-right of your menu bar", systemImage: "arrow.up.right")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }
}
