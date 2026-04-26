import CoreGraphics
import AppKit

final class CursorController: GestureProcessorDelegate {
    private var isActive = false
    private var lastHandPoint = CGPoint.zero
    private var hasLastHandPoint = false
    /// Screen point locked when pinch engages; re-warped at click-down so the hit target matches the committed aim.
    private var pinchAimAnchor: CGPoint?

    // Minimum hand movement (in CGWarp pixel space) required before we override
    // the system cursor. When the hand is roughly still, physical trackpad input
    // is allowed to move the cursor freely.
    private let handMovementThreshold: CGFloat = 2.5

    private let haptics = NSHapticFeedbackManager.defaultPerformer

    private var momentumTimer: Timer?
    private var momentumVelocity: CGFloat = 0
    private var momentumAccumulator: CGFloat = 0
    private let momentumTickInterval: TimeInterval = 1.0 / 60.0
    /// Per-tick decay (trackpad-like coast). Lower = stops sooner.
    private let momentumFriction: CGFloat = 0.904
    /// Stop coasting when speed falls below this (same units as gesture velocity).
    private let momentumStopSpeed: CGFloat = 42

    func start() {
        isActive = true
        hasLastHandPoint = false
        pinchAimAnchor = nil
        stopScrollMomentum()
    }

    func stop() {
        isActive = false
        hasLastHandPoint = false
        pinchAimAnchor = nil
        stopScrollMomentum()
    }

    func moveCursor(to point: CGPoint) {
        guard isActive else { return }

        defer {
            lastHandPoint = point
            hasLastHandPoint = true
        }

        if hasLastHandPoint {
            let dx = point.x - lastHandPoint.x
            let dy = point.y - lastHandPoint.y
            if hypot(dx, dy) < handMovementThreshold {
                return
            }
        }

        CGWarpMouseCursorPosition(point)
    }

    func gestureProcessor(_ processor: GestureProcessor, didRecognize event: GestureEvent) {
        guard isActive else { return }

        if case .pinchAimCommitted(let pt) = event {
            applyPinchAimCommit(at: pt)
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            switch event {
            case .pinchAimCommitted:
                break
            case .leftClickDown:
                self.stopScrollMomentum()
                if let anchor = self.pinchAimAnchor {
                    CGWarpMouseCursorPosition(anchor)
                    self.pinchAimAnchor = nil
                }
                let clickPoint = self.currentCursorLocation()
                self.postMouseEvent(type: .leftMouseDown, point: clickPoint)
                self.fireHaptic(.levelChange)
                self.playSoundIfEnabled("Tink")
            case .leftClickUp:
                let clickPoint = self.currentCursorLocation()
                self.postMouseEvent(type: .leftMouseUp, point: clickPoint)
            case .rightClick:
                self.stopScrollMomentum()
                self.pinchAimAnchor = nil
                let clickPoint = self.currentCursorLocation()
                self.postMouseEvent(type: .rightMouseDown, point: clickPoint)
                self.postMouseEvent(type: .rightMouseUp, point: clickPoint)
                self.fireHaptic(.levelChange)
                self.playSoundIfEnabled("Tink")
            case .scroll(let deltaY):
                self.stopScrollMomentum()
                self.pinchAimAnchor = nil
                self.postScrollEvent(deltaY: deltaY)
            case .scrollMomentumStart(let velocityY):
                self.startScrollMomentum(velocityY: velocityY)
            case .handLost:
                self.stopScrollMomentum()
                self.pinchAimAnchor = nil
            case .handFound:
                break
            }
        }
    }

    private func applyPinchAimCommit(at point: CGPoint) {
        pinchAimAnchor = point
        CGWarpMouseCursorPosition(point)
        lastHandPoint = point
        hasLastHandPoint = true
    }

    private func stopScrollMomentum() {
        momentumTimer?.invalidate()
        momentumTimer = nil
        momentumVelocity = 0
        momentumAccumulator = 0
    }

    private func startScrollMomentum(velocityY: CGFloat) {
        stopScrollMomentum()
        guard abs(velocityY) > 48 else { return }
        momentumVelocity = velocityY
        momentumAccumulator = 0
        let timer = Timer(timeInterval: momentumTickInterval, repeats: true) { [weak self] _ in
            self?.tickScrollMomentum()
        }
        momentumTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func tickScrollMomentum() {
        let dt = CGFloat(momentumTickInterval)
        momentumVelocity *= momentumFriction
        momentumAccumulator += momentumVelocity * dt

        let chunk = momentumAccumulator.rounded(.towardZero)
        if chunk != 0 {
            postScrollEvent(deltaY: chunk)
            momentumAccumulator -= chunk
        }

        if abs(momentumVelocity) < momentumStopSpeed, abs(momentumAccumulator) < 0.35 {
            stopScrollMomentum()
        }
    }

    private func fireHaptic(_ pattern: NSHapticFeedbackManager.FeedbackPattern) {
        guard SettingsStore.shared.hapticsEnabled else { return }
        haptics.perform(pattern, performanceTime: .default)
    }

    private func playSoundIfEnabled(_ name: String) {
        guard SettingsStore.shared.soundEffectsEnabled else { return }
        NSSound(named: NSSound.Name(name))?.play()
    }

    private func currentCursorLocation() -> CGPoint {
        let loc = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(loc) }) ?? NSScreen.main
        guard let screen else { return loc }
        return CGPoint(x: loc.x, y: screen.frame.maxY - loc.y)
    }

    private func postMouseEvent(type: CGEventType, point: CGPoint) {
        let button: CGMouseButton = (type == .rightMouseDown || type == .rightMouseUp) ? .right : .left
        let event = CGEvent(
            mouseEventSource: nil,
            mouseType: type,
            mouseCursorPosition: point,
            mouseButton: button
        )
        event?.post(tap: .cghidEventTap)
    }

    private func postScrollEvent(deltaY: CGFloat) {
        let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 1,
            wheel1: Int32(-deltaY),
            wheel2: 0,
            wheel3: 0
        )
        event?.post(tap: .cghidEventTap)
    }
}
