import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import os

private enum CameraLog {
    /// Filter in Console.app: subsystem = your app bundle ID, category = `Camera`
    static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Pointless", category: "Camera")
}

protocol CameraManagerDelegate: AnyObject {
    func cameraManager(_ manager: CameraManager, didOutput sampleBuffer: CMSampleBuffer)
}

final class CameraManager: NSObject {
    weak var delegate: CameraManagerDelegate?
    var preferredCameraID: String?
    public var session: AVCaptureSession { captureSession }

    private let captureSession: AVCaptureSession
    private let videoOutput = AVCaptureVideoDataOutput()
    private let outputQueue = DispatchQueue(label: "com.pointless.camera")
    private let sessionQueue = DispatchQueue(label: "com.pointless.camera.session")
    private var isSessionConfigured = false
    private var shouldDelayStartForExternalCamera = false
    /// Bumped on `stop()` so a pending external-camera delayed `startRunning` never fires after teardown.
    private var externalStartGeneration: UInt64 = 0
    private var didLogFirstFrame = false

    override init() {
        self.captureSession = AVCaptureSession()
        super.init()
        addSessionObservers()
    }

    deinit {
        removeSessionObservers()
        CameraLog.logger.debug("CameraManager deinit")
    }

    func start() {
        let auth = AVCaptureDevice.authorizationStatus(for: .video)
        CameraLog.logger.info("start() camera auth status: \(String(describing: auth), privacy: .public)")
        switch auth {
        case .authorized:
            startRunning()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                CameraLog.logger.info("camera permission callback granted=\(granted, privacy: .public)")
                guard granted else {
                    CameraLog.logger.error("Camera access was not granted.")
                    return
                }
                self?.startRunning()
            }
        case .denied:
            CameraLog.logger.error("Camera access denied — enable in System Settings ▸ Privacy & Security ▸ Camera.")
        case .restricted:
            CameraLog.logger.error("Camera access restricted.")
        @unknown default:
            CameraLog.logger.error("Unknown camera authorization status.")
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.externalStartGeneration &+= 1
            CameraLog.logger.info("stop() on session queue, generation=\(self.externalStartGeneration, privacy: .public), running=\(self.captureSession.isRunning, privacy: .public)")
            if self.captureSession.isRunning {
                self.captureSession.stopRunning()
            }
        }
    }

    private func startRunning() {
        sessionQueue.async { [weak self] in
            guard let self else {
                CameraLog.logger.warning("startRunning: self nil (CameraManager already released)")
                return
            }
            if !self.isSessionConfigured {
                let ok = self.configureSession()
                self.isSessionConfigured = ok
                CameraLog.logger.info("configureSession result: \(ok, privacy: .public)")
            }

            guard self.isSessionConfigured else {
                CameraLog.logger.error("startRunning aborted: session not configured")
                return
            }
            if self.captureSession.isRunning {
                CameraLog.logger.info("startRunning: session already running, skipping")
                return
            }

            let generation = self.externalStartGeneration
            if self.shouldDelayStartForExternalCamera {
                CameraLog.logger.info("External camera: scheduling startRunning in 0.35s (generation=\(generation, privacy: .public))")
                self.sessionQueue.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                    guard let self else {
                        CameraLog.logger.warning("delayed startRunning: self nil")
                        return
                    }
                    guard self.externalStartGeneration == generation else {
                        CameraLog.logger.info("delayed startRunning skipped (generation mismatch — stop/reconfigure)")
                        return
                    }
                    guard !self.captureSession.isRunning else {
                        CameraLog.logger.info("delayed startRunning skipped (already running)")
                        return
                    }
                    CameraLog.logger.info("delayed startRunning: calling captureSession.startRunning()")
                    self.captureSession.startRunning()
                    CameraLog.logger.info("delayed startRunning returned; session.isRunning=\(self.captureSession.isRunning, privacy: .public)")
                }
            } else {
                CameraLog.logger.info("Calling captureSession.startRunning() (no external delay)")
                self.captureSession.startRunning()
                CameraLog.logger.info("startRunning returned; session.isRunning=\(self.captureSession.isRunning, privacy: .public)")
            }
        }
    }

    private func configureSession() -> Bool {
        let verbose = SettingsStore.shared.cameraDiagnosticLogging
        let session = captureSession

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        session.sessionPreset = .high

        let discoveredDevices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external],
            mediaType: .video,
            position: .unspecified
        ).devices

        CameraLog.logger.info("Discovery found \(discoveredDevices.count, privacy: .public) device(s)")
        if verbose {
            for d in discoveredDevices {
                let typeRaw = String(describing: d.deviceType)
                CameraLog.logger.info("  • \(d.localizedName, privacy: .public) | type=\(typeRaw, privacy: .public) | id=\(d.uniqueID, privacy: .public)")
            }
        }

        let preferredDevice = preferredCameraID.flatMap { preferredCameraID in
            discoveredDevices.first(where: { $0.uniqueID == preferredCameraID })
        }

        if let wanted = preferredCameraID, preferredDevice == nil {
            CameraLog.logger.warning("Saved preferred camera ID not in discovery list — will fall back. wantedID=\(wanted, privacy: .public)")
        }

        let selectedDevice = preferredDevice
            ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
            ?? AVCaptureDevice.default(for: .video)

        guard let device = selectedDevice else {
            CameraLog.logger.error("No available video capture device after discovery + defaults.")
            return false
        }

        shouldDelayStartForExternalCamera = (device.deviceType == .external)
        CameraLog.logger.info(
            "Selected device: \(device.localizedName, privacy: .public) type=\(String(describing: device.deviceType), privacy: .public) uniqueID=\(device.uniqueID, privacy: .public) externalDelay=\(self.shouldDelayStartForExternalCamera, privacy: .public)"
        )

        do {
            let input = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(input) {
                session.addInput(input)
            } else {
                CameraLog.logger.error("canAddInput returned false for \(device.localizedName, privacy: .public)")
                return false
            }
        } catch {
            CameraLog.logger.error("Failed to create AVCaptureDeviceInput: \(String(describing: error), privacy: .public)")
            return false
        }

        configureFrameRate(for: device)

        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: outputQueue)

        guard session.canAddOutput(videoOutput) else {
            CameraLog.logger.error("canAddOutput(video) returned false")
            return false
        }
        session.addOutput(videoOutput)
        CameraLog.logger.info("Session configured: input + video data output added.")
        return true
    }

    private func configureFrameRate(for device: AVCaptureDevice) {
        let ranges = device.activeFormat.videoSupportedFrameRateRanges
        let supports60 = ranges.contains { range in
            range.minFrameRate <= 60.0 && range.maxFrameRate >= 60.0
        }
        let supports30 = ranges.contains { range in
            range.minFrameRate <= 30.0 && range.maxFrameRate >= 30.0
        }

        let targetFPS: Int32
        if supports60 {
            targetFPS = 60
        } else if supports30 {
            targetFPS = 30
        } else {
            CameraLog.logger.warning("No standard 30/60 fps range on \(device.localizedName, privacy: .public) — leaving default frame duration")
            return
        }

        do {
            try device.lockForConfiguration()
            let frameDuration = CMTime(value: 1, timescale: targetFPS)
            device.activeVideoMinFrameDuration = frameDuration
            device.activeVideoMaxFrameDuration = frameDuration
            device.unlockForConfiguration()
            CameraLog.logger.info("Frame rate locked to \(targetFPS, privacy: .public) fps")
        } catch {
            CameraLog.logger.error("Failed to configure frame rate: \(String(describing: error), privacy: .public)")
        }
    }

    private func addSessionObservers() {
        let session = captureSession
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSessionWasInterrupted(_:)),
            name: AVCaptureSession.wasInterruptedNotification,
            object: session
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSessionInterruptionEnded(_:)),
            name: AVCaptureSession.interruptionEndedNotification,
            object: session
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSessionRuntimeError(_:)),
            name: AVCaptureSession.runtimeErrorNotification,
            object: session
        )
    }

    private func removeSessionObservers() {
        NotificationCenter.default.removeObserver(self)
    }

    @objc
    private func handleSessionWasInterrupted(_ notification: Notification) {
        let info = notification.userInfo ?? [:]
        // Interruption reason keys differ by platform; log raw userInfo on macOS.
        CameraLog.logger.warning("Session interrupted userInfo=\(String(describing: info), privacy: .public)")
    }

    @objc
    private func handleSessionInterruptionEnded(_ notification: Notification) {
        CameraLog.logger.info("Session interruption ended userInfo=\(String(describing: notification.userInfo), privacy: .public)")
    }

    @objc
    private func handleSessionRuntimeError(_ notification: Notification) {
        let info = notification.userInfo ?? [:]
        if let err = info[AVCaptureSessionErrorKey] as? Error {
            CameraLog.logger.error("Session runtime error: \(String(describing: err), privacy: .public)")
        } else {
            CameraLog.logger.error("Session runtime error (no AVCaptureSessionErrorKey): \(String(describing: info), privacy: .public)")
        }
    }
}

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        if !didLogFirstFrame {
            didLogFirstFrame = true
            CameraLog.logger.info("First video frame received — capture pipeline is delivering samples.")
        }
        delegate?.cameraManager(self, didOutput: sampleBuffer)
    }
}
