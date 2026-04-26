import AppKit
import AVFoundation
import os
import QuartzCore

private enum TrackingLog {
    static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Pointless", category: "Tracking")
}

enum StatusBarIconState: Sendable {
    case idle
    case tracking
    case pinching
    case permissionNeeded
}

final class StatusBarController: NSObject, GestureProcessorDelegate, NSMenuDelegate {
    private final class HandPoseAdapter: NSObject, HandTrackerDelegate {
        weak var owner: StatusBarController?

        func handTracker(_ tracker: HandTracker, didDetectPose pose: HandPose?) {
            guard let pose else {
                DispatchQueue.main.async { [weak self] in
                    self?.owner?.handleSmoothedPose(nil)
                }
                return
            }
            DispatchQueue.main.async { [weak self] in
                self?.owner?.handleSmoothedPose(pose, smoothedIndex: pose.indexTip)
            }
        }
    }

    typealias IconState = StatusBarIconState

    private let statusItem: NSStatusItem
    private var cameraManager: CameraManager?
    private var handTracker: HandTracker?
    private var gestureProcessor: GestureProcessor?
    private var cursorController: CursorController?
    private var handPoseAdapter: HandPoseAdapter?
    private var toggleMenuItem: NSMenuItem?
    private var statusHeaderItem: NSMenuItem?
    private var overlayWindow: HandOverlayWindow?
    private var cameraPreviewWindow: CameraPreviewWindow?
    private var isTracking = false
    private var iconState: IconState = .idle
    private var settingsObservers: [NSObjectProtocol] = []
    private var permissionTimer: Timer?
    /// Stops tracking after this many seconds without a visible hand once tracking has been established.
    private let noHandAutoStopInterval: TimeInterval = 3.0
    /// On initial tracking start (before the first visible hand), allow a longer grace period.
    private let initialNoHandAutoStopInterval: TimeInterval = 6.0
    private var noHandIdleTimer: Timer?
    private var trackingStartedAt: Date?
    private var lastHandVisibleAt: Date?
    private var isHandCurrentlyVisible = false
    private var cameraSubmenu: NSMenu?

    override init() {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        if let button = statusItem.button {
            button.image = Self.symbolImage(for: .idle)
            button.image?.isTemplate = true
            button.toolTip = "Pointless"
        }

        setupMenu()
        observeSettings()
        startPermissionWatchdog()
    }

    deinit {
        for obs in settingsObservers {
            NotificationCenter.default.removeObserver(obs)
        }
        permissionTimer?.invalidate()
        noHandIdleTimer?.invalidate()
    }

    // MARK: - Menu

    private func setupMenu() {
        let menu = NSMenu()
        menu.delegate = self

        let header = NSMenuItem(title: "Pointless", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        statusHeaderItem = header
        refreshStatusHeader()

        menu.addItem(.separator())

        let toggleItem = NSMenuItem(
            title: "Enable Tracking",
            action: #selector(toggleTrackingMenu),
            keyEquivalent: "t"
        )
        toggleItem.target = self
        menu.addItem(toggleItem)
        self.toggleMenuItem = toggleItem

        menu.addItem(.separator())

        let cameraSub = NSMenu(title: "Camera")
        cameraSubmenu = cameraSub
        rebuildCameraSubmenu()
        let cameraItem = NSMenuItem(title: "Camera", action: nil, keyEquivalent: "")
        cameraItem.submenu = cameraSub
        menu.addItem(cameraItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit Pointless",
            action: #selector(quitApp),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    private func rebuildCameraSubmenu() {
        guard let sub = cameraSubmenu else { return }
        sub.removeAllItems()

        let selectedID = SettingsStore.shared.selectedCameraID

        let defaultItem = NSMenuItem(
            title: "Default",
            action: #selector(selectCameraMenuItem(_:)),
            keyEquivalent: ""
        )
        defaultItem.target = self
        defaultItem.state = selectedID == nil ? .on : .off
        sub.addItem(defaultItem)

        let devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external],
            mediaType: .video,
            position: .unspecified
        ).devices

        for device in devices {
            let item = NSMenuItem(
                title: device.localizedName,
                action: #selector(selectCameraMenuItem(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = device.uniqueID as NSString
            item.state = selectedID == device.uniqueID ? .on : .off
            sub.addItem(item)
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        if menu === statusItem.menu {
            rebuildCameraSubmenu()
        }
    }

    @objc private func selectCameraMenuItem(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? NSString {
            SettingsStore.shared.selectedCameraID = id as String
        } else {
            SettingsStore.shared.selectedCameraID = nil
        }
        rebuildCameraSubmenu()
    }

    private func refreshStatusHeader() {
        let perms = PermissionsManager.shared
        let statusText: String
        switch (perms.cameraStatus, perms.accessibilityStatus, isTracking) {
        case (.granted, .granted, true):
            statusText = "Tracking active"
        case (.granted, .granted, false):
            statusText = "Ready to track"
        case (_, .notDetermined, _), (_, .denied, _):
            statusText = "Accessibility permission needed"
        case (.notDetermined, _, _), (.denied, _, _):
            statusText = "Camera permission needed"
        default:
            statusText = "Pointless"
        }
        statusHeaderItem?.title = statusText
    }

    // MARK: - Tracking toggle

    @objc private func toggleTrackingMenu() { toggleTracking() }

    func toggleTracking() {
        isTracking ? stopTracking(reason: "menuToggle") : startTracking()
    }

    /// Siri / Shortcuts: turn tracking on only if it is off (idempotent).
    func enableTracking() {
        guard !isTracking else { return }
        startTracking()
    }

    /// Siri / Shortcuts: turn tracking off only if it is on (idempotent).
    func disableTracking() {
        guard isTracking else { return }
        stopTracking(reason: "disableIntent")
    }

    private func startTracking() {
        guard PermissionsManager.shared.allGranted else {
            NotificationCenter.default.post(name: .pointlessRequestShowOnboarding, object: nil)
            return
        }

        isTracking = true
        toggleMenuItem?.title = "Disable Tracking"

        cursorController = CursorController()
        gestureProcessor = GestureProcessor()
        gestureProcessor?.delegate = self

        if SettingsStore.shared.showSkeletonOverlay {
            overlayWindow = HandOverlayWindow()
            overlayWindow?.updateGestureState("Ready")
        }

        if SettingsStore.shared.showCameraPreview {
            cameraPreviewWindow = CameraPreviewWindow()
            cameraPreviewWindow?.applyMirroring(SettingsStore.shared.mirrorCamera)
            cameraPreviewWindow?.setHandDetected(false)
        }

        handTracker = HandTracker()
        handPoseAdapter = HandPoseAdapter()
        handPoseAdapter?.owner = self
        handTracker?.delegate = handPoseAdapter

        cameraManager = CameraManager()
        cameraManager?.preferredCameraID = SettingsStore.shared.selectedCameraID
        cameraManager?.delegate = handTracker

        cursorController?.start()
        cameraManager?.start()
        if let session = cameraManager?.session {
            cameraPreviewWindow?.connectSession(session)
        }

        trackingStartedAt = Date()
        lastHandVisibleAt = nil
        startNoHandAutoStopTimer()

        animateIcon(to: .tracking)
        refreshStatusHeader()
        NotificationCenter.default.post(name: .pointlessTrackingStateChanged, object: true)
    }

    private func stopTracking(reason: String) {
        TrackingLog.logger.notice("stopTracking reason=\(reason, privacy: .public)")
        isTracking = false
        toggleMenuItem?.title = "Enable Tracking"

        noHandIdleTimer?.invalidate()
        noHandIdleTimer = nil
        trackingStartedAt = nil
        lastHandVisibleAt = nil
        isHandCurrentlyVisible = false

        cameraManager?.stop()
        cursorController?.stop()

        cameraPreviewWindow?.dismiss()
        overlayWindow?.close()
        cameraPreviewWindow = nil
        overlayWindow = nil

        cameraManager = nil
        handTracker = nil
        handPoseAdapter = nil
        gestureProcessor = nil
        cursorController = nil

        animateIcon(to: .idle)
        refreshStatusHeader()
        NotificationCenter.default.post(name: .pointlessTrackingStateChanged, object: false)
    }

    // MARK: - Pose handling

    private func handleSmoothedPose(_ pose: HandPose?, smoothedIndex: CGPoint? = nil) {
        let handVisible = pose?.isVisible == true
        isHandCurrentlyVisible = handVisible
        if handVisible {
            lastHandVisibleAt = Date()
        }
        gestureProcessor?.processHandPose(pose)
        let gestureLabel = gestureProcessor?.gestureStateLabel ?? "Ready"

        overlayWindow?.updatePose(pose)
        overlayWindow?.updateGestureState(gestureLabel)
        cameraPreviewWindow?.updateHandPose(pose, gestureState: gestureLabel)

        if let smoothedIndex, gestureProcessor?.allowsDirectCursorMovement ?? true {
            cursorController?.moveCursor(to: smoothedIndex)
        }
    }

    func gestureProcessor(_ processor: GestureProcessor, didRecognize event: GestureEvent) {
        switch event {
        case .pinchAimCommitted:
            break
        case .scroll:
            overlayWindow?.updateGestureState("Scrolling")
            cameraPreviewWindow?.updateHandPose(nil, gestureState: "Scrolling")
        case .scrollMomentumStart:
            break
        case .leftClickDown:
            overlayWindow?.updateGestureState("Tap")
            cameraPreviewWindow?.updateHandPose(nil, gestureState: "Tap")
            animateIcon(to: .pinching)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
                self?.overlayWindow?.updateGestureState(self?.gestureProcessor?.gestureStateLabel ?? "Ready")
                self?.cameraPreviewWindow?.updateHandPose(nil, gestureState: self?.gestureProcessor?.gestureStateLabel ?? "Ready")
                if self?.iconState == .pinching {
                    self?.animateIcon(to: .tracking)
                }
            }
        case .leftClickUp:
            overlayWindow?.updateGestureState("Ready")
            cameraPreviewWindow?.updateHandPose(nil, gestureState: "Ready")
        case .rightClick:
            overlayWindow?.updateGestureState("Context")
            cameraPreviewWindow?.updateHandPose(nil, gestureState: "Context")
            animateIcon(to: .pinching)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { [weak self] in
                self?.overlayWindow?.updateGestureState(self?.gestureProcessor?.gestureStateLabel ?? "Ready")
                self?.cameraPreviewWindow?.updateHandPose(nil, gestureState: self?.gestureProcessor?.gestureStateLabel ?? "Ready")
                if self?.iconState == .pinching { self?.animateIcon(to: .tracking) }
            }
        case .handFound:
            cameraPreviewWindow?.setHandDetected(true)
        case .handLost:
            cameraPreviewWindow?.setHandDetected(false)
            overlayWindow?.updateGestureState("Ready")
            cameraPreviewWindow?.updateHandPose(nil, gestureState: "Ready")
        }

        cursorController?.gestureProcessor(processor, didRecognize: event)
    }

    // MARK: - Icon states

    private func animateIcon(to newState: IconState) {
        iconState = newState
        guard let button = statusItem.button else { return }

        let newImage = Self.symbolImage(for: newState)
        newImage?.isTemplate = true

        // Crossfade between images.
        CATransaction.begin()
        CATransaction.setAnimationDuration(Motion.stateChangeDuration)
        button.image = newImage
        CATransaction.commit()

        // Subtle bounce on pinching state.
        if newState == .pinching {
            let bounce = CABasicAnimation(keyPath: "transform.scale")
            bounce.fromValue = 1.0
            bounce.toValue = 1.12
            bounce.autoreverses = true
            bounce.duration = 0.12
            button.wantsLayer = true
            button.layer?.add(bounce, forKey: "pinch")
        }
    }

    static func symbolImage(for state: IconState) -> NSImage? {
        let name: String
        switch state {
        case .idle: return NSImage(systemSymbolName: "hand.point.up.left", accessibilityDescription: "Pointless idle")
        case .tracking: name = "hand.point.up.left.fill"
        case .pinching: name = "hand.pinch.fill"
        case .permissionNeeded: name = "exclamationmark.triangle.fill"
        }
        return NSImage(systemSymbolName: name, accessibilityDescription: "Pointless")
    }

    // MARK: - Settings observers

    private func observeSettings() {
        let center = NotificationCenter.default

        settingsObservers.append(center.addObserver(
            forName: .pointlessSelectedCameraChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.isTracking else { return }
            self.stopTracking(reason: "selectedCameraChanged")
            self.startTracking()
        })

        settingsObservers.append(center.addObserver(
            forName: .pointlessDisplaySettingsChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.applyDisplaySettings()
        })
    }

    private func applyDisplaySettings() {
        guard isTracking else { return }
        let s = SettingsStore.shared

        if s.showSkeletonOverlay && overlayWindow == nil {
            overlayWindow = HandOverlayWindow()
        } else if !s.showSkeletonOverlay, let ov = overlayWindow {
            ov.close()
            overlayWindow = nil
        }

        if s.showCameraPreview && cameraPreviewWindow == nil {
            cameraPreviewWindow = CameraPreviewWindow()
            cameraPreviewWindow?.applyMirroring(s.mirrorCamera)
            if let session = cameraManager?.session {
                cameraPreviewWindow?.connectSession(session)
            }
        } else if !s.showCameraPreview, let preview = cameraPreviewWindow {
            preview.dismiss()
            cameraPreviewWindow = nil
        } else {
            cameraPreviewWindow?.applyMirroring(s.mirrorCamera)
        }
    }

    private func startNoHandAutoStopTimer() {
        noHandIdleTimer?.invalidate()
        let t = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.evaluateNoHandAutoStop()
        }
        RunLoop.main.add(t, forMode: .common)
        noHandIdleTimer = t
    }

    private func evaluateNoHandAutoStop() {
        guard isTracking else { return }
        if isHandCurrentlyVisible {
            cameraPreviewWindow?.setDisconnectCountdown(secondsRemaining: nil)
            return
        }
        let now = Date()
        let idleDuration: TimeInterval
        let cutoff: TimeInterval
        if let last = lastHandVisibleAt {
            idleDuration = now.timeIntervalSince(last)
            cutoff = noHandAutoStopInterval
        } else if let started = trackingStartedAt {
            idleDuration = now.timeIntervalSince(started)
            cutoff = initialNoHandAutoStopInterval
        } else {
            return
        }
        let remaining = max(0, Int(ceil(cutoff - idleDuration)))
        cameraPreviewWindow?.setDisconnectCountdown(secondsRemaining: remaining)
        if idleDuration >= cutoff {
            stopTracking(reason: "noHandAutoStop")
        }
    }

    private func startPermissionWatchdog() {
        permissionTimer?.invalidate()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                self?.tickPermissions()
            }
        }
        RunLoop.main.add(permissionTimer!, forMode: .common)
    }

    private func tickPermissions() {
        PermissionsManager.shared.refresh()
        let perms = PermissionsManager.shared
        let needsPerms = !perms.allGranted
        // Do not stop the camera pipeline when only Accessibility is missing — `allGranted` is false
        // while AX is untrusted, which would kill external-camera sessions right after they start.
        // Cursor control still requires AX; we surface that in the menu header and icon instead.
        let cameraRevoked = perms.cameraStatus != .granted
        if cameraRevoked, isTracking {
            stopTracking(reason: "cameraPermissionRevoked")
        }
        let current = iconState
        if needsPerms && current != .permissionNeeded {
            animateIcon(to: .permissionNeeded)
        } else if !needsPerms && current == .permissionNeeded {
            animateIcon(to: .idle)
        }
        refreshStatusHeader()
    }

    // MARK: - Menu actions

    @objc private func showOnboarding() {
        NotificationCenter.default.post(name: .pointlessRequestShowOnboarding, object: nil)
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}
