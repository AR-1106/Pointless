import Foundation
import CoreGraphics
import QuartzCore

enum GestureEvent {
    /// visionOS-style indirect tap: aim is fixed at pinch close (here: stabilized index ray), like gaze + pinch.
    case pinchAimCommitted(at: CGPoint)
    case leftClickDown
    case leftClickUp
    /// Both hands pinch simultaneously → right-click / context menu.
    case rightClick
    case scroll(deltaY: CGFloat)
    /// Inertial scroll after pinch release (`velocityY` ≈ scroll delta units per second).
    case scrollMomentumStart(velocityY: CGFloat)
    case handFound
    case handLost
}

protocol GestureProcessorDelegate: AnyObject {
    func gestureProcessor(_ processor: GestureProcessor, didRecognize event: GestureEvent)
}

final class GestureProcessor: HandTrackerDelegate {
    private enum PinchState {
        case idle
        case pinching
    }

    weak var delegate: GestureProcessorDelegate?

    var pinchThreshold: CGFloat = 0.04
    let pinchFramesRequired = 4
    let clickDebounceInterval: TimeInterval = 0.2
    var scrollMultiplier: CGFloat = 1.0
    let scrollMinDelta: CGFloat = 3.0
    let handLostTimeout: TimeInterval = 0.5

    private var settingsObserver: NSObjectProtocol?

    init() {
        applySettings()
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .pointlessGestureSettingsChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.applySettings()
        }
    }

    deinit {
        if let obs = settingsObserver {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    private func applySettings() {
        let s = SettingsStore.shared
        pinchThreshold = s.derivedPinchThreshold
        scrollMultiplier = s.derivedScrollMultiplier
    }

    // MARK: - One-hand state
    private var pinchState: PinchState = .idle
    private var consecutivePinchFrames = 0
    private var lastClickTime: Date? = nil
    private var lastMiddleTipY: CGFloat? = nil
    private var lastHandSeenTime: Date? = nil
    private var handIsPresent = false
    /// True once we've emitted scroll during the current pinch — suppresses click on release.
    private var didScrollThisPinch = false
    private var lastScrollEmitTime: CFTimeInterval = 0
    /// Smoothed scroll speed in the same units as `scroll(deltaY:)` per second.
    private var smoothedScrollVelocity: CGFloat = 0
    /// After a tap, briefly block hand-driven cursor warps so the index finger
    /// doesn't drag the pointer while the pinch opens (same frame + rebound).
    private var suppressHandCursorUntil: CFTimeInterval = 0

    // MARK: - Two-hand state
    /// Consecutive frames the off (secondary) hand has been pinching.
    private var offHandPinchFrames = 0
    /// True while off-hand clutch is held and we've emitted mouseDown — primary hand steers the drag.
    private var offHandDragActive = false
    /// Debounce timestamp: prevents right-click re-fire within 300 ms.
    private var rightClickDebounceUntil: CFTimeInterval = 0

    var allowsDirectCursorMovement: Bool {
        // Cursor movement is free when idle OR when dragging (primary hand must steer the drag).
        (pinchState == .idle || offHandDragActive) && CACurrentMediaTime() >= suppressHandCursorUntil
    }

    var gestureStateLabel: String {
        if offHandDragActive { return "Drag" }
        switch pinchState {
        case .idle: return "Ready"
        case .pinching: return didScrollThisPinch ? "Scrolling" : "Pinch"
        }
    }

    func handTracker(_ tracker: HandTracker, didDetectPose pose: HandPose?) {
        processHandPose(pose)
    }

    func processHandPose(_ pose: HandPose?) {
        guard let pose = pose, pose.isVisible else {
            if handIsPresent {
                let elapsed = lastHandSeenTime.map {
                    Date().timeIntervalSince($0)
                } ?? handLostTimeout
                if elapsed > handLostTimeout {
                    handIsPresent = false
                    resetAllState()
                    delegate?.gestureProcessor(self, didRecognize: .handLost)
                }
            }
            return
        }

        lastHandSeenTime = Date()
        if !handIsPresent {
            handIsPresent = true
            delegate?.gestureProcessor(self, didRecognize: .handFound)
        }

        // Process off-hand first — its state gates what the primary hand can do.
        processOffHand(pose)

        // While dragging, primary hand just moves the cursor; skip pinch events.
        guard !offHandDragActive else {
            lastMiddleTipY = nil
            return
        }

        processPrimaryPinch(pose)
    }

    // MARK: - Off-hand (secondary hand) logic

    private func processOffHand(_ pose: HandPose) {
        let secondaryPinching = (pose.secondaryPinchDistance ?? .greatestFiniteMagnitude) < pinchThreshold

        if secondaryPinching {
            offHandPinchFrames += 1
        } else {
            offHandPinchFrames = 0
            if offHandDragActive {
                offHandDragActive = false
                delegate?.gestureProcessor(self, didRecognize: .leftClickUp)
            }
            return
        }

        // Only act once, on the frame the threshold is crossed.
        guard offHandPinchFrames == pinchFramesRequired else { return }

        let now = CACurrentMediaTime()
        if pinchState == .pinching, now >= rightClickDebounceUntil {
            // Primary was already aiming → dual-pinch = right-click.
            rightClickDebounceUntil = now + 0.3
            pinchState = .idle
            consecutivePinchFrames = 0
            didScrollThisPinch = false
            lastMiddleTipY = nil
            smoothedScrollVelocity = 0
            lastScrollEmitTime = 0
            offHandPinchFrames = 0
            delegate?.gestureProcessor(self, didRecognize: .rightClick)
        } else if pinchState == .idle, !offHandDragActive {
            // Off-hand clutch → hold left button for drag.
            offHandDragActive = true
            delegate?.gestureProcessor(self, didRecognize: .leftClickDown)
        }
    }

    // MARK: - Primary hand pinch / tap / scroll

    private func processPrimaryPinch(_ pose: HandPose) {
        if pose.pinchDistance < pinchThreshold {
            consecutivePinchFrames += 1

            if consecutivePinchFrames >= pinchFramesRequired, pinchState == .idle {
                let now = Date()
                let sinceLastClick = lastClickTime.map {
                    now.timeIntervalSince($0)
                } ?? clickDebounceInterval
                if sinceLastClick >= clickDebounceInterval {
                    pinchState = .pinching
                    didScrollThisPinch = false
                    lastClickTime = now
                    lastScrollEmitTime = 0
                    smoothedScrollVelocity = 0
                    delegate?.gestureProcessor(self, didRecognize: .pinchAimCommitted(at: pose.indexTip))
                }
            }
        } else {
            consecutivePinchFrames = 0
            switch pinchState {
            case .pinching:
                if didScrollThisPinch {
                    let now = CACurrentMediaTime()
                    let idleFor = now - lastScrollEmitTime
                    let stale = idleFor > 0.12 || lastScrollEmitTime == 0
                    let v = stale ? 0 : smoothedScrollVelocity
                    if abs(v) > 72 {
                        delegate?.gestureProcessor(self, didRecognize: .scrollMomentumStart(velocityY: v))
                    }
                } else {
                    delegate?.gestureProcessor(self, didRecognize: .leftClickDown)
                    delegate?.gestureProcessor(self, didRecognize: .leftClickUp)
                    lastClickTime = Date()
                    suppressHandCursorUntil = CACurrentMediaTime() + 0.11
                }
                smoothedScrollVelocity = 0
                lastScrollEmitTime = 0
                pinchState = .idle
            case .idle:
                break
            }
        }

        if pinchState != .idle {
            if let midY = pose.middleTip?.y {
                if let lastY = lastMiddleTipY {
                    let delta = midY - lastY
                    if abs(delta) > scrollMinDelta {
                        didScrollThisPinch = true
                        let deltaPosted = -delta * scrollMultiplier
                        recordScrollVelocity(deltaPosted: deltaPosted)
                        delegate?.gestureProcessor(self, didRecognize: .scroll(deltaY: deltaPosted))
                    }
                }
                lastMiddleTipY = midY
            }
        } else {
            lastMiddleTipY = nil
        }
    }

    private func recordScrollVelocity(deltaPosted: CGFloat) {
        let t = CACurrentMediaTime()
        if lastScrollEmitTime > 0 {
            let dt = t - lastScrollEmitTime
            if dt > 0.001, dt < 0.45 {
                let instant = deltaPosted / CGFloat(dt)
                smoothedScrollVelocity = instant * 0.38 + smoothedScrollVelocity * 0.62
            } else {
                smoothedScrollVelocity = deltaPosted / CGFloat(max(dt, 1.0 / 120.0))
            }
        } else {
            smoothedScrollVelocity = deltaPosted * 60
        }
        lastScrollEmitTime = t
    }

    private func resetAllState() {
        if offHandDragActive {
            offHandDragActive = false
            delegate?.gestureProcessor(self, didRecognize: .leftClickUp)
        }
        pinchState = .idle
        consecutivePinchFrames = 0
        didScrollThisPinch = false
        lastMiddleTipY = nil
        smoothedScrollVelocity = 0
        lastScrollEmitTime = 0
        suppressHandCursorUntil = 0
        offHandPinchFrames = 0
    }
}
