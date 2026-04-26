import AppKit
import AVFoundation
import QuartzCore

/// Floating Liquid Glass camera preview that drops down from the notch.
final class CameraPreviewWindow {
    private let window: DraggablePreviewWindow
    private let previewView: CameraPreviewView
    private let contentSize: CGSize
    private let presentedFrame: CGRect
    private var isDismissing = false

    init() {
        contentSize = CGSize(width: 264, height: 188)
        let screen = NSScreen.main ?? NSScreen.screens.first ?? NSScreen()
        let frames = Self.frames(contentSize: contentSize, screen: screen)
        let hiddenFrame = frames.hidden
        presentedFrame = frames.presented

        window = DraggablePreviewWindow(
            contentRect: hiddenFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        previewView = CameraPreviewView(frame: CGRect(origin: .zero, size: contentSize))

        window.backgroundColor = .clear
        window.isOpaque = false
        window.level = .floating
        window.ignoresMouseEvents = false
        window.contentView = previewView
        window.hasShadow = true
        window.alphaValue = 0
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.orderFrontRegardless()

        present()
    }

    /// Notch “pill” strip (hidden) vs full card (presented) — same geometry as Dynamic Island expand/contract.
    private static func frames(contentSize: CGSize, screen: NSScreen) -> (hidden: CGRect, presented: CGRect) {
        let screenFrame = screen.frame
        let notchHeight: CGFloat = {
            if #available(macOS 12.0, *), screen.safeAreaInsets.top > 0 {
                return screen.safeAreaInsets.top
            }
            return NSStatusBar.system.thickness
        }()

        let presentedOrigin = CGPoint(
            x: screenFrame.midX - contentSize.width / 2,
            y: screenFrame.maxY - notchHeight - contentSize.height - 10
        )
        let presented = CGRect(origin: presentedOrigin, size: contentSize)

        let hiddenOrigin = CGPoint(
            x: presentedOrigin.x + contentSize.width * 0.04,
            y: screenFrame.maxY - notchHeight + 4
        )
        let hiddenSize = CGSize(width: contentSize.width * 0.92, height: 1)
        let hidden = CGRect(origin: hiddenOrigin, size: hiddenSize)
        return (hidden, presented)
    }

    private func present() {
        previewView.needsLayout = true
        previewView.layoutSubtreeIfNeeded()
        previewView.playIslandPresentAnimation()

        // Window frame lands slightly ahead of the layer springs so the pill shape is stable
        // *before* the content inside fades in — this is what sells the "notch extending" read.
        let frameDuration = Motion.presentDuration * 0.72
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = frameDuration
            ctx.timingFunction = Motion.islandPresentTiming
            ctx.allowsImplicitAnimation = true
            window.animator().alphaValue = 1
            window.animator().setFrame(presentedFrame, display: true)
        }, completionHandler: nil)
    }

    func dismiss() {
        guard !isDismissing else { return }
        isDismissing = true
        let w = window
        let screen = w.screen ?? NSScreen.main ?? NSScreen.screens.first!
        let retreatFrame = Self.frames(contentSize: contentSize, screen: screen).hidden

        previewView.playIslandDismissAnimation()

        // Delay the window retreat until content has faded (mirrors the present order in reverse).
        let contentFadeDuration = Motion.dismissDuration * 0.35
        let frameDuration = Motion.dismissDuration - contentFadeDuration
        DispatchQueue.main.asyncAfter(deadline: .now() + contentFadeDuration) { [weak self] in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = frameDuration
                ctx.timingFunction = Motion.islandDismissTiming
                ctx.allowsImplicitAnimation = true
                w.animator().alphaValue = 0
                w.animator().setFrame(retreatFrame, display: true)
            }, completionHandler: {
                w.contentView?.layer?.removeAllAnimations()
                w.orderOut(nil)
                _ = self // keep reference alive until retreat finishes
            })
        }
    }

    func connectSession(_ session: AVCaptureSession) {
        previewView.connectSession(session)
    }

    func updateHandPose(_ pose: HandPose?, gestureState: String) {
        previewView.updateHandPose(pose, gestureState: gestureState)
    }

    func setHandDetected(_ detected: Bool) {
        previewView.setHandDetected(detected)
    }

    func setDisconnectCountdown(secondsRemaining: Int?) {
        previewView.setDisconnectCountdown(secondsRemaining: secondsRemaining)
    }

    func applyMirroring(_ mirrored: Bool) {
        previewView.applyMirroring(mirrored)
    }
}

final class DraggablePreviewWindow: NSWindow {
    override func mouseDragged(with event: NSEvent) {
        let location = NSEvent.mouseLocation
        setFrameOrigin(CGPoint(x: location.x - frame.width / 2, y: location.y - 20))
    }
}

/// Passes mouse events through so the window / video host can handle dragging.
private final class PreviewOverlayHostView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class CameraPreviewView: NSView {
    /// Hosts `AVCaptureVideoPreviewLayer` only. Must not sit under `NSVisualEffectView`
    /// with `behindWindow` blending — that composites the desktop, not this layer.
    private let videoHost = NSView(frame: .zero)
    private let overlayHost = PreviewOverlayHostView(frame: .zero)
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private let skeletonLayer = CAShapeLayer()
    private var sessionObserver: NSObjectProtocol?
    private let chipLayer = CAShapeLayer()
    private let chipBlurLayer = CALayer()
    private let statusDotLayer = CALayer()
    private let statusTextLayer = CATextLayer()

    private var pose: HandPose?
    private var gestureState: String = "Ready"
    private var handDetected = false
    private var disconnectCountdownSeconds: Int?
    private var mirrored = true

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false

        videoHost.wantsLayer = true
        videoHost.layer?.cornerRadius = 22
        videoHost.layer?.cornerCurve = .continuous
        videoHost.layer?.masksToBounds = true
        videoHost.layer?.borderWidth = 0.5
        videoHost.layer?.borderColor = GlassPalette.hairline.cgColor
        // Solid pure black base so the shape reads as the notch extending during the morph
        // (matches the feel of Dynamic Island / Face ID notifications on notched Macs).
        videoHost.layer?.backgroundColor = NSColor.black.cgColor

        overlayHost.wantsLayer = true
        overlayHost.layer?.backgroundColor = NSColor.clear.cgColor
        overlayHost.layer?.masksToBounds = false

        addSubview(videoHost)
        addSubview(overlayHost)
        videoHost.translatesAutoresizingMaskIntoConstraints = false
        overlayHost.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            videoHost.topAnchor.constraint(equalTo: topAnchor),
            videoHost.bottomAnchor.constraint(equalTo: bottomAnchor),
            videoHost.leadingAnchor.constraint(equalTo: leadingAnchor),
            videoHost.trailingAnchor.constraint(equalTo: trailingAnchor),
            overlayHost.topAnchor.constraint(equalTo: topAnchor),
            overlayHost.bottomAnchor.constraint(equalTo: bottomAnchor),
            overlayHost.leadingAnchor.constraint(equalTo: leadingAnchor),
            overlayHost.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
        setupLayers()
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        if let obs = sessionObserver {
            NotificationCenter.default.removeObserver(obs)
            sessionObserver = nil
        }
        previewLayer?.session = nil
        previewLayer?.removeFromSuperlayer()
        skeletonLayer.removeFromSuperlayer()
        chipLayer.removeFromSuperlayer()
        chipBlurLayer.removeFromSuperlayer()
        statusDotLayer.removeFromSuperlayer()
        statusTextLayer.removeFromSuperlayer()
        layer?.removeAllAnimations()
    }

    func connectSession(_ session: AVCaptureSession) {
        previewLayer?.session = session
        sessionObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureSession.didStartRunningNotification,
            object: session,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.previewLayer?.connection?.automaticallyAdjustsVideoMirroring = false
            self.previewLayer?.connection?.isVideoMirrored = self.mirrored
            if let obs = self.sessionObserver {
                NotificationCenter.default.removeObserver(obs)
                self.sessionObserver = nil
            }
        }
    }

    func applyMirroring(_ mirrored: Bool) {
        self.mirrored = mirrored
        previewLayer?.connection?.automaticallyAdjustsVideoMirroring = false
        previewLayer?.connection?.isVideoMirrored = mirrored
    }

    func updateHandPose(_ pose: HandPose?, gestureState: String) {
        DispatchQueue.main.async {
            self.pose = pose
            self.gestureState = gestureState
            self.updateSkeleton()
            self.updateChip()
        }
    }

    func setHandDetected(_ detected: Bool) {
        DispatchQueue.main.async {
            self.handDetected = detected
            self.updateChip()
        }
    }

    func setDisconnectCountdown(secondsRemaining: Int?) {
        DispatchQueue.main.async {
            self.disconnectCountdownSeconds = secondsRemaining
            self.updateChip()
        }
    }

    override func layout() {
        super.layout()
        guard overlayHost.layer != nil else { return }

        let videoBounds = videoHost.bounds
        previewLayer?.frame = CGRect(origin: .zero, size: videoBounds.size)
        skeletonLayer.frame = videoBounds

        let chipSize = CGSize(width: 152, height: 28)
        let chipOrigin = CGPoint(
            x: videoBounds.midX - chipSize.width / 2,
            y: videoBounds.minY + 12
        )
        let chipRect = CGRect(origin: chipOrigin, size: chipSize)
        chipBlurLayer.frame = chipRect
        chipLayer.frame = chipRect
        chipLayer.path = CGPath(
            roundedRect: CGRect(origin: .zero, size: chipSize),
            cornerWidth: chipSize.height / 2,
            cornerHeight: chipSize.height / 2,
            transform: nil
        )
        statusDotLayer.frame = CGRect(x: chipRect.minX + 12, y: chipRect.midY - 4, width: 8, height: 8)
        statusTextLayer.frame = CGRect(x: chipRect.minX + 26, y: chipRect.minY + 6, width: chipSize.width - 34, height: 16)
    }

    private func setupLayers() {
        guard let videoLayer = videoHost.layer, let overlayLayer = overlayHost.layer else { return }

        let preview = AVCaptureVideoPreviewLayer()
        preview.videoGravity = .resizeAspectFill
        videoLayer.addSublayer(preview)
        self.previewLayer = preview

        skeletonLayer.fillColor = NSColor.clear.cgColor
        skeletonLayer.strokeColor = GlassPalette.accent.withAlphaComponent(0.9).cgColor
        skeletonLayer.lineWidth = 1.4
        skeletonLayer.lineCap = .round
        skeletonLayer.lineJoin = .round
        overlayLayer.addSublayer(skeletonLayer)

        // Floating status chip.
        chipBlurLayer.backgroundColor = NSColor.black.withAlphaComponent(0.28).cgColor
        chipBlurLayer.cornerRadius = 14
        chipBlurLayer.cornerCurve = .continuous
        chipBlurLayer.masksToBounds = true
        chipBlurLayer.borderWidth = 0.5
        chipBlurLayer.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        overlayLayer.addSublayer(chipBlurLayer)

        chipLayer.fillColor = NSColor.clear.cgColor
        chipLayer.strokeColor = NSColor.white.withAlphaComponent(0.18).cgColor
        chipLayer.lineWidth = 0.5
        overlayLayer.addSublayer(chipLayer)

        statusDotLayer.cornerRadius = 4
        statusDotLayer.backgroundColor = NSColor.systemGray.cgColor
        overlayLayer.addSublayer(statusDotLayer)

        statusTextLayer.fontSize = 11
        statusTextLayer.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        statusTextLayer.foregroundColor = NSColor.white.cgColor
        statusTextLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        statusTextLayer.alignmentMode = .left
        statusTextLayer.truncationMode = .end
        overlayLayer.addSublayer(statusTextLayer)

        updateChip()
    }

    /// The content layers that live INSIDE the pill — fade in after the pill container settles so
    /// the shape reads as "notch extending" first, then content appears inside it (Face-ID-style).
    private var contentLayers: [CALayer] {
        var layers: [CALayer] = [skeletonLayer, chipBlurLayer, chipLayer, statusDotLayer, statusTextLayer]
        if let p = previewLayer { layers.append(p) }
        return layers
    }

    /// Dynamic Island / Face-ID-style morph: pill container expands first, then content fills in.
    func playIslandPresentAnimation() {
        guard let root = layer, let videoLayer = videoHost.layer else { return }
        root.removeAllAnimations()
        videoLayer.removeAllAnimations()

        // Pill geometry: start pill-shaped so the corner morph tells the story, no scale on the view.
        let fromR: CGFloat = 40
        let toR: CGFloat = 22
        videoLayer.cornerRadius = fromR
        // Hide hairline border during the morph — the notch has no border.
        videoLayer.borderColor = NSColor.clear.cgColor
        root.opacity = 1

        // Content inside the pill appears after the container has mostly settled.
        let sync = IslandLayerSpring.presentSyncDuration
        let contentDelay = sync * 0.45
        for cl in contentLayers {
            cl.opacity = 0
        }

        let corner = CASpringAnimation(keyPath: "cornerRadius")
        IslandLayerSpring.configurePresentCorner(corner)
        corner.fromValue = fromR
        corner.toValue = toR

        CATransaction.begin()
        CATransaction.setAnimationDuration(sync)
        CATransaction.setDisableActions(true)
        videoLayer.add(corner, forKey: "island.present.corner")
        videoLayer.cornerRadius = toR
        CATransaction.commit()

        // Delayed content fade — uses `beginTime` so CA schedules everything on its own clock.
        for cl in contentLayers {
            let fade = CASpringAnimation(keyPath: "opacity")
            IslandLayerSpring.configurePresentOpacity(fade)
            fade.fromValue = 0
            fade.toValue = 1
            fade.beginTime = CACurrentMediaTime() + contentDelay
            fade.fillMode = .backwards
            cl.add(fade, forKey: "island.present.contentFade")
            cl.opacity = 1
        }

        // Restore border once the container is nearly settled so it doesn’t flicker during the morph.
        DispatchQueue.main.asyncAfter(deadline: .now() + sync * 0.85) { [weak self] in
            guard let self else { return }
            let restore = CASpringAnimation(keyPath: "borderColor")
            IslandLayerSpring.configurePresentOpacity(restore)
            restore.fromValue = NSColor.clear.cgColor
            restore.toValue = GlassPalette.hairline.cgColor
            self.videoHost.layer?.add(restore, forKey: "island.present.border")
            self.videoHost.layer?.borderColor = GlassPalette.hairline.cgColor
        }
    }

    /// Content fades out first, then container contracts back toward a pill.
    func playIslandDismissAnimation() {
        guard let root = layer, let videoLayer = videoHost.layer else { return }
        root.removeAllAnimations()
        videoLayer.removeAllAnimations()

        let sync = IslandLayerSpring.dismissSyncDuration
        let contentFadeDuration = sync * 0.35

        // 1) Content fades quickly so the pill looks empty before it tucks away.
        CATransaction.begin()
        CATransaction.setAnimationDuration(contentFadeDuration)
        CATransaction.setDisableActions(true)
        for cl in contentLayers {
            let out = CABasicAnimation(keyPath: "opacity")
            out.fromValue = cl.opacity
            out.toValue = 0
            out.duration = contentFadeDuration
            out.timingFunction = Motion.islandDismissTiming
            out.fillMode = .forwards
            cl.add(out, forKey: "island.dismiss.contentFade")
            cl.opacity = 0
        }
        CATransaction.commit()

        // 2) Pill container: corner back to pill shape, plus a gentle opacity falloff at the end.
        let fromR = videoLayer.cornerRadius
        let toR: CGFloat = 40

        let corner = CASpringAnimation(keyPath: "cornerRadius")
        IslandLayerSpring.configureDismiss(corner)
        corner.fromValue = fromR
        corner.toValue = toR

        let rootFade = CASpringAnimation(keyPath: "opacity")
        IslandLayerSpring.configureDismiss(rootFade)
        rootFade.fromValue = 1
        rootFade.toValue = 0
        rootFade.beginTime = CACurrentMediaTime() + contentFadeDuration
        rootFade.fillMode = .backwards

        CATransaction.begin()
        CATransaction.setAnimationDuration(sync)
        CATransaction.setDisableActions(true)
        videoLayer.add(corner, forKey: "island.dismiss.corner")
        root.add(rootFade, forKey: "island.dismiss.opacity")
        videoLayer.cornerRadius = toR
        root.opacity = 0
        CATransaction.commit()
    }

    private func updateChip() {
        CATransaction.begin()
        CATransaction.setAnimationDuration(Motion.stateChangeDuration)

        let dotColor: NSColor
        let text: String
        if let countdown = disconnectCountdownSeconds {
            dotColor = .systemOrange
            text = "Disconnecting in \(countdown)s"
        } else if gestureState.contains("Scroll") {
            dotColor = .systemBlue
            text = "Scrolling"
        } else if gestureState.contains("Tap") || gestureState.contains("Click") {
            dotColor = .systemGreen
            text = "Tap"
        } else if handDetected {
            dotColor = .systemGreen
            text = "Tracking"
        } else {
            dotColor = NSColor(white: 0.7, alpha: 1.0)
            text = "Waiting for hand"
        }
        statusDotLayer.backgroundColor = dotColor.cgColor
        statusTextLayer.string = text
        CATransaction.commit()
    }

    private func updateSkeleton() {
        guard let pose else {
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.2)
            skeletonLayer.path = nil
            CATransaction.commit()
            return
        }

        let color: NSColor
        if gestureState.contains("Scroll") {
            color = .systemBlue
        } else if gestureState.contains("Tap") || gestureState.contains("Click") {
            color = .systemGreen
        } else {
            color = GlassPalette.accent
        }

        CATransaction.begin()
        CATransaction.setAnimationDuration(Motion.stateChangeDuration)
        skeletonLayer.strokeColor = color.withAlphaComponent(0.9).cgColor
        CATransaction.commit()

        let path = NSBezierPath()
        path.lineWidth = 1.4

        let joints = mapJointsToPreview(pose)
        let fingerChains: [[CGPoint?]] = [
            [joints["wrist"], joints["thumbCMC"], joints["thumbMP"], joints["thumbIP"], joints["thumbTip"]],
            [joints["wrist"], joints["indexMCP"], joints["indexPIP"], joints["indexDIP"], joints["indexTip"]],
            [joints["wrist"], joints["middleMCP"], joints["middlePIP"], joints["middleDIP"], joints["middleTip"]],
            [joints["wrist"], joints["ringMCP"], joints["ringPIP"], joints["ringDIP"], joints["ringTip"]],
            [joints["wrist"], joints["littleMCP"], joints["littlePIP"], joints["littleDIP"], joints["littleTip"]],
            [joints["indexMCP"], joints["middleMCP"], joints["ringMCP"], joints["littleMCP"]]
        ]

        for chain in fingerChains {
            let validPoints = chain.compactMap { $0 }
            guard validPoints.count >= 2 else { continue }
            path.move(to: validPoints[0])
            for point in validPoints.dropFirst() {
                path.line(to: point)
            }
        }

        for (name, point) in joints {
            let radius: CGFloat
            if name == "indexTip" || name == "thumbTip" {
                radius = 4.5
            } else if name == "middleTip" || name == "ringTip" || name == "littleTip" {
                radius = 3.5
            } else if name == "wrist" {
                radius = 3
            } else {
                radius = 2.2
            }
            let rect = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
            path.appendOval(in: rect)
        }

        skeletonLayer.path = path.cgPathCompat
    }

    private func mapJointsToPreview(_ pose: HandPose) -> [String: CGPoint] {
        func toPreview(_ point: CGPoint?) -> CGPoint? {
            guard let point else { return nil }
            return visionToPreviewPoint(point)
        }

        return [
            "wrist": toPreview(pose.rawWrist),
            "indexMCP": toPreview(pose.rawIndexMCP),
            "indexPIP": toPreview(pose.rawIndexPIP),
            "indexDIP": toPreview(pose.rawIndexDIP),
            "indexTip": toPreview(pose.rawIndexTip),
            "middleMCP": toPreview(pose.rawMiddleMCP),
            "middlePIP": toPreview(pose.rawMiddlePIP),
            "middleDIP": toPreview(pose.rawMiddleDIP),
            "middleTip": toPreview(pose.rawMiddleTip),
            "ringMCP": toPreview(pose.rawRingMCP),
            "ringPIP": toPreview(pose.rawRingPIP),
            "ringDIP": toPreview(pose.rawRingDIP),
            "ringTip": toPreview(pose.rawRingTip),
            "littleMCP": toPreview(pose.rawLittleMCP),
            "littlePIP": toPreview(pose.rawLittlePIP),
            "littleDIP": toPreview(pose.rawLittleDIP),
            "littleTip": toPreview(pose.rawLittleTip),
            "thumbCMC": toPreview(pose.rawThumbCMC),
            "thumbMP": toPreview(pose.rawThumbMP),
            "thumbIP": toPreview(pose.rawThumbIP),
            "thumbTip": toPreview(pose.rawThumbTip)
        ].compactMapValues { $0 }
    }

    private func visionToPreviewPoint(_ visionPoint: CGPoint) -> CGPoint {
        if let layer = previewLayer {
            return layer.layerPointConverted(fromCaptureDevicePoint: visionPoint)
        }
        return CGPoint(x: visionPoint.x * bounds.width, y: visionPoint.y * bounds.height)
    }
}

extension NSBezierPath {
    var cgPathCompat: CGPath {
        if #available(macOS 14.0, *) {
            return self.cgPath
        }
        let path = CGMutablePath()
        var points = [NSPoint](repeating: .zero, count: 3)
        for index in 0..<elementCount {
            let elem = element(at: index, associatedPoints: &points)
            switch elem {
            case .moveTo:
                path.move(to: points[0])
            case .lineTo:
                path.addLine(to: points[0])
            case .curveTo:
                path.addCurve(to: points[2], control1: points[0], control2: points[1])
            case .closePath:
                path.closeSubpath()
            default:
                break
            }
        }
        return path
    }
}
