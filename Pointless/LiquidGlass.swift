import AppKit
import SwiftUI
import QuartzCore

// MARK: - Island-style springs (public CASpringAnimation — same family as UIKit layer springs)

/// Tuned to feel close to compact-to-expanded system morphs: slight overshoot on transform, soft settle.
/// Dynamic Island itself is private; this is the closest on-stack public analogue.
enum IslandLayerSpring {
    // Tuned to feel close to Dynamic Island / Face-ID morphs: crisp start, slight give on arrival.
    private static let presentStiffness: CGFloat = 320
    private static let presentDamping: CGFloat = 22
    private static let presentMass: CGFloat = 0.9
    private static let presentVelocityTransform: CGFloat = 0.5
    private static let presentVelocityOpacity: CGFloat = 0.25
    private static let presentVelocityCorner: CGFloat = 0.25

    // Dismiss: heavier damping so the tuck stays clean.
    private static let dismissStiffness: CGFloat = 300
    private static let dismissDamping: CGFloat = 40
    private static let dismissMass: CGFloat = 1.05

    private static func settlingDuration(
        keyPath: String,
        stiffness: CGFloat,
        damping: CGFloat,
        mass: CGFloat,
        velocity: CGFloat
    ) -> CFTimeInterval {
        let a = CASpringAnimation(keyPath: keyPath)
        a.stiffness = stiffness
        a.damping = damping
        a.mass = mass
        a.initialVelocity = velocity
        return a.settlingDuration
    }

    static var presentSyncDuration: CFTimeInterval {
        max(
            settlingDuration(keyPath: "transform", stiffness: presentStiffness, damping: presentDamping, mass: presentMass, velocity: presentVelocityTransform),
            settlingDuration(keyPath: "opacity", stiffness: presentStiffness, damping: presentDamping, mass: presentMass, velocity: presentVelocityOpacity),
            settlingDuration(keyPath: "cornerRadius", stiffness: presentStiffness, damping: presentDamping, mass: presentMass, velocity: presentVelocityCorner)
        )
    }

    static var dismissSyncDuration: CFTimeInterval {
        max(
            settlingDuration(keyPath: "transform", stiffness: dismissStiffness, damping: dismissDamping, mass: dismissMass, velocity: 0),
            settlingDuration(keyPath: "opacity", stiffness: dismissStiffness, damping: dismissDamping, mass: dismissMass, velocity: 0),
            settlingDuration(keyPath: "cornerRadius", stiffness: dismissStiffness, damping: dismissDamping, mass: dismissMass, velocity: 0)
        )
    }

    static func configurePresentTransform(_ a: CASpringAnimation) {
        a.stiffness = presentStiffness
        a.damping = presentDamping
        a.mass = presentMass
        a.initialVelocity = presentVelocityTransform
        a.duration = presentSyncDuration
    }

    static func configurePresentOpacity(_ a: CASpringAnimation) {
        a.stiffness = presentStiffness
        a.damping = presentDamping
        a.mass = presentMass
        a.initialVelocity = presentVelocityOpacity
        a.duration = presentSyncDuration
    }

    static func configurePresentCorner(_ a: CASpringAnimation) {
        a.stiffness = presentStiffness
        a.damping = presentDamping
        a.mass = presentMass
        a.initialVelocity = presentVelocityCorner
        a.duration = presentSyncDuration
    }

    static func configureDismiss(_ a: CASpringAnimation) {
        a.stiffness = dismissStiffness
        a.damping = dismissDamping
        a.mass = dismissMass
        a.initialVelocity = 0
        a.duration = dismissSyncDuration
    }
}

/// Centralized motion + material tokens so every surface feels consistent.
/// On macOS 26 we adopt the system Liquid Glass materials; on earlier OS we
/// fall back to comparable `NSVisualEffectView` materials.
enum Motion {
    /// Primary spring curve used for window presents, chip transitions, etc.
    static let primaryTiming = CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)
    /// Gentler curve used for dismissals.
    static let dismissTiming = CAMediaTimingFunction(controlPoints: 0.4, 0.0, 0.8, 0.4)

    /// Window morph uses AppKit animator; this curve approximates the tail of a UI spring (no public spring on `NSWindow`).
    static let islandPresentTiming = CAMediaTimingFunction(controlPoints: 0.28, 0.82, 0.12, 1.0)
    static let islandDismissTiming = CAMediaTimingFunction(controlPoints: 0.45, 0.0, 0.2, 1.0)

    /// Durations match `CASpringAnimation.settlingDuration` for the island layer springs (see `IslandLayerSpring`).
    static var presentDuration: CFTimeInterval { IslandLayerSpring.presentSyncDuration }
    static var dismissDuration: CFTimeInterval { IslandLayerSpring.dismissSyncDuration }
    static let stateChangeDuration: CFTimeInterval = 0.18

    /// SwiftUI animation tokens for onboarding / settings surfaces.
    static let spring: Animation = .spring(response: 0.55, dampingFraction: 0.82)
    static let snappy: Animation = .spring(response: 0.32, dampingFraction: 0.9)
    static let smooth: Animation = .easeInOut(duration: 0.25)
}

enum GlassPalette {
    /// Brand accent. Uses system indigo which harmonizes with Liquid Glass.
    static var accent: NSColor { NSColor.systemIndigo }

    /// Stroke used around glass panels when we need a hairline.
    static var hairline: NSColor { NSColor.white.withAlphaComponent(0.10) }

    /// Primary label color on top of glass.
    static var primary: NSColor { NSColor.labelColor }
    static var secondary: NSColor { NSColor.secondaryLabelColor }
}

/// An AppKit host that renders Liquid Glass on macOS 26 and falls back to
/// an `NSVisualEffectView` with an equivalent material on older systems.
///
/// We keep this as an `NSView` subclass so callers can simply assign it as
/// a window's content view or use it as a background layer host.
final class GlassBackdropView: NSView {
    enum Style {
        /// Heads-up (camera preview, onboarding hero cards).
        case hud
        /// Popover / menu-like chrome.
        case popover
        /// Thick toolbar-style chrome.
        case sidebar
    }

    private let effectView: NSVisualEffectView

    init(style: Style) {
        let ev = NSVisualEffectView(frame: .zero)
        switch style {
        case .hud:
            ev.material = .hudWindow
        case .popover:
            ev.material = .popover
        case .sidebar:
            ev.material = .sidebar
        }
        ev.blendingMode = .behindWindow
        ev.state = .active
        ev.wantsLayer = true
        ev.layer?.cornerRadius = 18
        ev.layer?.cornerCurve = .continuous
        ev.layer?.masksToBounds = true
        self.effectView = ev
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 18
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        addSubview(ev)
        ev.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            ev.topAnchor.constraint(equalTo: topAnchor),
            ev.bottomAnchor.constraint(equalTo: bottomAnchor),
            ev.leadingAnchor.constraint(equalTo: leadingAnchor),
            ev.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }

    /// Apply a new corner radius and keep the contained visual-effect view aligned.
    func applyCornerRadius(_ radius: CGFloat) {
        layer?.cornerRadius = radius
        effectView.layer?.cornerRadius = radius
    }

    /// Add a hairline border for Apple-style panel edges.
    func applyHairlineBorder() {
        layer?.borderWidth = 0.5
        layer?.borderColor = GlassPalette.hairline.cgColor
    }
}

// MARK: - SwiftUI convenience

extension View {
    /// A Liquid-Glass-styled card. Uses the native `.glassEffect` on macOS 26
    /// and a `.regularMaterial` approximation on earlier systems.
    @ViewBuilder
    func liquidGlassCard(cornerRadius: CGFloat = 22) -> some View {
        if #available(macOS 26.0, *) {
            self
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(.regularMaterial)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
                )
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .shadow(color: .black.opacity(0.25), radius: 24, x: 0, y: 10)
        } else {
            self
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(.regularMaterial)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
                )
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .shadow(color: .black.opacity(0.2), radius: 20, x: 0, y: 8)
        }
    }

    /// A smaller chip-style glass container used for status pills.
    @ViewBuilder
    func liquidGlassChip(cornerRadius: CGFloat = 14) -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.thinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}
