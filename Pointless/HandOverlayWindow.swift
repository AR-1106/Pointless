import AppKit

/// Full-screen, click-through overlay that renders the hand skeleton + an
/// accent-colored cursor ring. Joints are drawn as soft additive gradients
/// rather than hard white dots so the overlay reads as a living glass effect.
final class HandOverlayWindow {
    private let window: NSWindow
    private let skeletonView: HandSkeletonView
    private var isClosing = false

    init() {
        let frame = NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1920, height: 1080)
        window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        skeletonView = HandSkeletonView(frame: frame)

        window.backgroundColor = .clear
        window.isOpaque = false
        window.level = .screenSaver
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        window.contentView = skeletonView
        window.alphaValue = 0
        window.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Motion.presentDuration
            ctx.timingFunction = Motion.islandPresentTiming
            window.animator().alphaValue = 1
        }
    }

    func updatePose(_ pose: HandPose?) {
        let apply: () -> Void = { [weak self] in
            guard let self, !self.isClosing else { return }
            self.skeletonView.pose = pose
            self.skeletonView.needsDisplay = true
            NSAnimationContext.runAnimationGroup { context in
                context.duration = pose == nil ? 0.42 : 0.14
                context.timingFunction = pose == nil ? Motion.islandDismissTiming : Motion.islandPresentTiming
                self.window.animator().alphaValue = pose == nil ? 0.0 : 1.0
            }
        }
        if Thread.isMainThread {
            apply()
        } else {
            DispatchQueue.main.async(execute: apply)
        }
    }

    func updateGestureState(_ state: String) {
        let apply: () -> Void = { [weak self] in
            guard let self, !self.isClosing else { return }
            if self.skeletonView.gestureState == state { return }
            self.skeletonView.gestureState = state
            self.skeletonView.needsDisplay = true
        }
        if Thread.isMainThread {
            apply()
        } else {
            DispatchQueue.main.async(execute: apply)
        }
    }

    func close() {
        guard !isClosing else { return }
        isClosing = true
        let w = window
        w.contentView?.layer?.removeAllAnimations()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Motion.dismissDuration
            ctx.timingFunction = Motion.islandDismissTiming
            w.animator().alphaValue = 0
        }, completionHandler: {
            w.orderOut(nil)
        })
    }
}

final class HandSkeletonView: NSView {
    var pose: HandPose?
    var gestureState: String = "Ready"

    override var isOpaque: Bool { false }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let pose else { return }

        let committed = gestureState != "Ready"
        let tint = accentForGesture(gestureState)

        // Bones first, so joints render on top.
        drawBones(for: pose, color: tint, committed: committed)

        // Draw all joints as soft radial gradients.
        let joints = allJoints(for: pose)
        for (name, point) in joints {
            let radius: CGFloat
            let isEmphasized = name == "indexTip" || name == "thumbTip"
            if isEmphasized {
                radius = 9
            } else if name == "middleTip" || name == "ringTip" || name == "littleTip" {
                radius = 6
            } else if name == "wrist" {
                radius = 6
            } else {
                radius = 4
            }
            drawGradientDot(at: point, radius: radius, color: tint, emphasized: isEmphasized, committed: committed)
        }

        drawCursorRing(at: pose.indexTip, color: tint, committed: committed)
    }

    // MARK: - Drawing

    private func drawBones(for pose: HandPose, color: NSColor, committed: Bool) {
        let segments = boneSegments(for: pose)
        color.withAlphaComponent(committed ? 0.9 : 0.38).setStroke()
        for (start, end) in segments {
            let path = NSBezierPath()
            path.lineWidth = 1.6
            path.lineCapStyle = .round
            path.move(to: start)
            path.line(to: end)
            path.stroke()
        }
    }

    private func drawGradientDot(at point: CGPoint, radius: CGFloat, color: NSColor, emphasized: Bool, committed: Bool) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let outerRadius = radius * 2.6
        let centerAlpha: CGFloat = {
            if committed { return emphasized ? 1.0 : 0.9 }
            return emphasized ? 0.78 : 0.58
        }()
        let colors = [
            color.withAlphaComponent(centerAlpha).cgColor,
            color.withAlphaComponent(0.0).cgColor
        ] as CFArray

        if let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: colors,
            locations: [0.0, 1.0]
        ) {
            ctx.saveGState()
            ctx.drawRadialGradient(
                gradient,
                startCenter: point,
                startRadius: 0,
                endCenter: point,
                endRadius: outerRadius,
                options: []
            )
            ctx.restoreGState()
        }

        let dotRect = CGRect(
            x: point.x - radius,
            y: point.y - radius,
            width: radius * 2,
            height: radius * 2
        )
        let whiteCore: CGFloat = committed ? (emphasized ? 1.0 : 0.88) : (emphasized ? 0.9 : 0.68)
        NSColor.white.withAlphaComponent(whiteCore).setFill()
        NSBezierPath(ovalIn: dotRect).fill()
    }

    private func drawCursorRing(at point: CGPoint, color: NSColor, committed: Bool) {
        let outer = CGRect(x: point.x - 18, y: point.y - 18, width: 36, height: 36)
        let inner = CGRect(x: point.x - 12, y: point.y - 12, width: 24, height: 24)

        color.withAlphaComponent(committed ? 0.78 : 0.32).setStroke()
        let ring = NSBezierPath(ovalIn: outer)
        ring.lineWidth = committed ? 1.35 : 1.0
        ring.stroke()

        color.withAlphaComponent(committed ? 1.0 : 0.52).setStroke()
        let ringInner = NSBezierPath(ovalIn: inner)
        ringInner.lineWidth = committed ? 1.6 : 1.3
        ringInner.stroke()
    }

    // MARK: - Joint helpers (same topology as before)

    private func allJoints(for pose: HandPose) -> [(String, CGPoint)] {
        [
            ("wrist", pose.wrist),
            ("thumbCMC", pose.thumbCMC), ("thumbMP", pose.thumbMP), ("thumbIP", pose.thumbIP), ("thumbTip", pose.thumbTip),
            ("indexMCP", pose.indexMCP), ("indexPIP", pose.indexPIP), ("indexDIP", pose.indexDIP), ("indexTip", pose.indexTip),
            ("middleMCP", pose.middleMCP), ("middlePIP", pose.middlePIP), ("middleDIP", pose.middleDIP), ("middleTip", pose.middleTip),
            ("ringMCP", pose.ringMCP), ("ringPIP", pose.ringPIP), ("ringDIP", pose.ringDIP), ("ringTip", pose.ringTip),
            ("littleMCP", pose.littleMCP), ("littlePIP", pose.littlePIP), ("littleDIP", pose.littleDIP), ("littleTip", pose.littleTip)
        ].compactMap { name, point in
            guard let point else { return nil }
            return (name, point)
        }
    }

    private func boneSegments(for pose: HandPose) -> [(CGPoint, CGPoint)] {
        var segments: [(CGPoint, CGPoint)] = []
        let fingerChains: [[CGPoint?]] = [
            [pose.wrist, pose.thumbCMC, pose.thumbMP, pose.thumbIP, pose.thumbTip],
            [pose.wrist, pose.indexMCP, pose.indexPIP, pose.indexDIP, pose.indexTip],
            [pose.wrist, pose.middleMCP, pose.middlePIP, pose.middleDIP, pose.middleTip],
            [pose.wrist, pose.ringMCP, pose.ringPIP, pose.ringDIP, pose.ringTip],
            [pose.wrist, pose.littleMCP, pose.littlePIP, pose.littleDIP, pose.littleTip],
            [pose.indexMCP, pose.middleMCP, pose.ringMCP, pose.littleMCP]
        ]

        for chain in fingerChains {
            let validPoints = chain.compactMap { $0 }
            guard validPoints.count >= 2 else { continue }
            for i in 0..<(validPoints.count - 1) {
                segments.append((validPoints[i], validPoints[i + 1]))
            }
        }
        return segments
    }

    private func accentForGesture(_ state: String) -> NSColor {
        if state.contains("Scroll") { return .systemBlue }
        if state.contains("Tap") || state.contains("Click") { return .systemGreen }
        return GlassPalette.accent
    }
}
