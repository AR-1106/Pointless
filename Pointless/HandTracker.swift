import Vision
import AVFoundation
import AppKit
import QuartzCore

struct HandPose {
    var indexTip: CGPoint
    var thumbTip: CGPoint
    var middleTip: CGPoint?
    var pinchDistance: CGFloat
    var isVisible: Bool
    var wrist: CGPoint?
    var indexMCP: CGPoint?
    var indexPIP: CGPoint?
    var indexDIP: CGPoint?
    var middleMCP: CGPoint?
    var middlePIP: CGPoint?
    var middleDIP: CGPoint?
    var ringPIP: CGPoint?
    var ringDIP: CGPoint?
    var ringTip: CGPoint?
    var ringMCP: CGPoint?
    var littlePIP: CGPoint?
    var littleDIP: CGPoint?
    var littleTip: CGPoint?
    var littleMCP: CGPoint?
    var thumbCMC: CGPoint?
    var thumbMP: CGPoint?
    var thumbIP: CGPoint?
    var rawIndexTip: CGPoint
    var rawThumbTip: CGPoint
    var rawMiddleTip: CGPoint?
    var rawWrist: CGPoint?
    var rawIndexMCP: CGPoint?
    var rawIndexPIP: CGPoint?
    var rawIndexDIP: CGPoint?
    var rawMiddleMCP: CGPoint?
    var rawMiddlePIP: CGPoint?
    var rawMiddleDIP: CGPoint?
    var rawRingMCP: CGPoint?
    var rawRingPIP: CGPoint?
    var rawRingDIP: CGPoint?
    var rawRingTip: CGPoint?
    var rawLittleMCP: CGPoint?
    var rawLittlePIP: CGPoint?
    var rawLittleDIP: CGPoint?
    var rawLittleTip: CGPoint?
    var rawThumbCMC: CGPoint?
    var rawThumbMP: CGPoint?
    var rawThumbIP: CGPoint?
    /// Secondary hand pinch distance in Vision normalised space (nil = no second hand detected).
    var secondaryPinchDistance: CGFloat?
    /// Secondary hand index tip in screen space (nil = no second hand detected).
    var secondaryIndexTip: CGPoint?
}

protocol HandTrackerDelegate: AnyObject {
    func handTracker(_ tracker: HandTracker, didDetectPose pose: HandPose?)
}

final class HandTracker: NSObject, CameraManagerDelegate {
    weak var delegate: HandTrackerDelegate?

    private let handPoseRequest: VNDetectHumanHandPoseRequest
    private let processingQueue = DispatchQueue(label: "com.pointless.handtracker")
    private var jointSmoothers: [String: SmoothingFilter] = [:]
    /// Extra-stable screen-space ray for the index tip (visionOS indirect-input analogue).
    private let indexScreenRaySmoother = SmoothingFilter(minCutoff: 0.38, beta: 0.0018)
    /// Last known primary-hand index-tip position used to keep identity stable frame-to-frame.
    private var lastPrimaryIndexTip: CGPoint?

    override init() {
        let request = VNDetectHumanHandPoseRequest()
        request.maximumHandCount = 2
        self.handPoseRequest = request
        super.init()
    }

    func cameraManager(_ manager: CameraManager, didOutput sampleBuffer: CMSampleBuffer) {
        processingQueue.async { [weak self] in
            guard let self else { return }

            let handler = VNImageRequestHandler(cmSampleBuffer: sampleBuffer, orientation: .up, options: [:])

            do {
                try handler.perform([self.handPoseRequest])
            } catch {
                DispatchQueue.main.async {
                    self.delegate?.handTracker(self, didDetectPose: nil)
                }
                return
            }

            guard let results = self.handPoseRequest.results, !results.isEmpty else {
                DispatchQueue.main.async {
                    self.delegate?.handTracker(self, didDetectPose: nil)
                }
                return
            }

            // Pick primary observation: hand closest to last known primary position (stable identity).
            // If this is the first frame or only one hand, fall back to confidence ranking.
            let primaryObs: VNHumanHandPoseObservation
            let secondaryObs: VNHumanHandPoseObservation?

            if results.count == 1 {
                primaryObs = results[0]
                secondaryObs = nil
            } else if let lastPt = self.lastPrimaryIndexTip {
                let ranked = results.sorted { lhs, rhs in
                    let lPt = (try? lhs.recognizedPoint(.indexTip)).map { self.visionToScreen($0) }
                        ?? CGPoint(x: 1e9, y: 1e9)
                    let rPt = (try? rhs.recognizedPoint(.indexTip)).map { self.visionToScreen($0) }
                        ?? CGPoint(x: 1e9, y: 1e9)
                    return hypot(lPt.x - lastPt.x, lPt.y - lastPt.y)
                        < hypot(rPt.x - lastPt.x, rPt.y - lastPt.y)
                }
                primaryObs = ranked[0]
                secondaryObs = ranked[1]
            } else {
                let ranked = results.sorted { lhs, rhs in
                    let lc = (try? lhs.recognizedPoint(.indexTip))?.confidence ?? 0
                    let rc = (try? rhs.recognizedPoint(.indexTip))?.confidence ?? 0
                    return lc > rc
                }
                primaryObs = ranked[0]
                secondaryObs = ranked[1]
            }

            let observation = primaryObs

            do {
                let indexTip = try observation.recognizedPoint(.indexTip)
                let thumbTip = try observation.recognizedPoint(.thumbTip)

                guard indexTip.confidence > 0.2, thumbTip.confidence > 0.2 else {
                    DispatchQueue.main.async {
                        self.delegate?.handTracker(self, didDetectPose: nil)
                    }
                    return
                }

                let middlePoint = try? observation.recognizedPoint(.middleTip)
                let validMiddlePoint: VNRecognizedPoint? = {
                    guard let middlePoint, middlePoint.confidence > 0.2 else { return nil }
                    return middlePoint
                }()

                let threshold: Float = 0.2
                let wrist = self.recognizedPoint(observation, joint: .wrist, minimumConfidence: threshold)
                let indexMCP = self.recognizedPoint(observation, joint: .indexMCP, minimumConfidence: threshold)
                let indexPIP = self.recognizedPoint(observation, joint: .indexPIP, minimumConfidence: threshold)
                let indexDIP = self.recognizedPoint(observation, joint: .indexDIP, minimumConfidence: threshold)
                let middleMCP = self.recognizedPoint(observation, joint: .middleMCP, minimumConfidence: threshold)
                let middlePIP = self.recognizedPoint(observation, joint: .middlePIP, minimumConfidence: threshold)
                let middleDIP = self.recognizedPoint(observation, joint: .middleDIP, minimumConfidence: threshold)
                let ringMCP = self.recognizedPoint(observation, joint: .ringMCP, minimumConfidence: threshold)
                let ringPIP = self.recognizedPoint(observation, joint: .ringPIP, minimumConfidence: threshold)
                let ringDIP = self.recognizedPoint(observation, joint: .ringDIP, minimumConfidence: threshold)
                let ringTip = self.recognizedPoint(observation, joint: .ringTip, minimumConfidence: threshold)
                let littleMCP = self.recognizedPoint(observation, joint: .littleMCP, minimumConfidence: threshold)
                let littlePIP = self.recognizedPoint(observation, joint: .littlePIP, minimumConfidence: threshold)
                let littleDIP = self.recognizedPoint(observation, joint: .littleDIP, minimumConfidence: threshold)
                let littleTip = self.recognizedPoint(observation, joint: .littleTip, minimumConfidence: threshold)
                let thumbCMC = self.recognizedPoint(observation, joint: .thumbCMC, minimumConfidence: threshold)
                let thumbMP = self.recognizedPoint(observation, joint: .thumbMP, minimumConfidence: threshold)
                let thumbIP = self.recognizedPoint(observation, joint: .thumbIP, minimumConfidence: threshold)

                let pinchDistance = hypot(
                    indexTip.location.x - thumbTip.location.x,
                    indexTip.location.y - thumbTip.location.y
                )

                let timestamp = CACurrentMediaTime()
                let screenIndexTip = self.indexScreenRaySmoother.filter(
                    point: self.visionToScreen(indexTip),
                    timestamp: timestamp
                )
                self.lastPrimaryIndexTip = screenIndexTip
                let screenThumbTip = self.smoothedPoint(self.visionToScreen(thumbTip), key: "thumbTip", timestamp: timestamp)

                // Secondary hand: only extract what gesture detection needs (pinch distance + index tip).
                let secondaryPinchDistance: CGFloat? = secondaryObs.flatMap { obs in
                    guard
                        let si = try? obs.recognizedPoint(.indexTip), si.confidence > 0.2,
                        let st = try? obs.recognizedPoint(.thumbTip), st.confidence > 0.2
                    else { return nil }
                    return hypot(si.location.x - st.location.x, si.location.y - st.location.y)
                }
                let secondaryIndexTip: CGPoint? = secondaryObs.flatMap { obs in
                    guard let si = try? obs.recognizedPoint(.indexTip), si.confidence > 0.2 else { return nil }
                    return self.smoothedPoint(self.visionToScreen(si), key: "secondaryIndexTip", timestamp: timestamp)
                }

                let pose = HandPose(
                    indexTip: screenIndexTip,
                    thumbTip: screenThumbTip,
                    middleTip: validMiddlePoint.map { self.smoothedPoint(self.visionToScreen($0), key: "middleTip", timestamp: timestamp) },
                    pinchDistance: pinchDistance,
                    isVisible: true,
                    wrist: wrist.map { self.smoothedPoint(self.visionToScreen($0), key: "wrist", timestamp: timestamp) },
                    indexMCP: indexMCP.map { self.smoothedPoint(self.visionToScreen($0), key: "indexMCP", timestamp: timestamp) },
                    indexPIP: indexPIP.map { self.smoothedPoint(self.visionToScreen($0), key: "indexPIP", timestamp: timestamp) },
                    indexDIP: indexDIP.map { self.smoothedPoint(self.visionToScreen($0), key: "indexDIP", timestamp: timestamp) },
                    middleMCP: middleMCP.map { self.smoothedPoint(self.visionToScreen($0), key: "middleMCP", timestamp: timestamp) },
                    middlePIP: middlePIP.map { self.smoothedPoint(self.visionToScreen($0), key: "middlePIP", timestamp: timestamp) },
                    middleDIP: middleDIP.map { self.smoothedPoint(self.visionToScreen($0), key: "middleDIP", timestamp: timestamp) },
                    ringPIP: ringPIP.map { self.smoothedPoint(self.visionToScreen($0), key: "ringPIP", timestamp: timestamp) },
                    ringDIP: ringDIP.map { self.smoothedPoint(self.visionToScreen($0), key: "ringDIP", timestamp: timestamp) },
                    ringTip: ringTip.map { self.smoothedPoint(self.visionToScreen($0), key: "ringTip", timestamp: timestamp) },
                    ringMCP: ringMCP.map { self.smoothedPoint(self.visionToScreen($0), key: "ringMCP", timestamp: timestamp) },
                    littlePIP: littlePIP.map { self.smoothedPoint(self.visionToScreen($0), key: "littlePIP", timestamp: timestamp) },
                    littleDIP: littleDIP.map { self.smoothedPoint(self.visionToScreen($0), key: "littleDIP", timestamp: timestamp) },
                    littleTip: littleTip.map { self.smoothedPoint(self.visionToScreen($0), key: "littleTip", timestamp: timestamp) },
                    littleMCP: littleMCP.map { self.smoothedPoint(self.visionToScreen($0), key: "littleMCP", timestamp: timestamp) },
                    thumbCMC: thumbCMC.map { self.smoothedPoint(self.visionToScreen($0), key: "thumbCMC", timestamp: timestamp) },
                    thumbMP: thumbMP.map { self.smoothedPoint(self.visionToScreen($0), key: "thumbMP", timestamp: timestamp) },
                    thumbIP: thumbIP.map { self.smoothedPoint(self.visionToScreen($0), key: "thumbIP", timestamp: timestamp) },
                    rawIndexTip: indexTip.location,
                    rawThumbTip: thumbTip.location,
                    rawMiddleTip: validMiddlePoint?.location,
                    rawWrist: wrist?.location,
                    rawIndexMCP: indexMCP?.location,
                    rawIndexPIP: indexPIP?.location,
                    rawIndexDIP: indexDIP?.location,
                    rawMiddleMCP: middleMCP?.location,
                    rawMiddlePIP: middlePIP?.location,
                    rawMiddleDIP: middleDIP?.location,
                    rawRingMCP: ringMCP?.location,
                    rawRingPIP: ringPIP?.location,
                    rawRingDIP: ringDIP?.location,
                    rawRingTip: ringTip?.location,
                    rawLittleMCP: littleMCP?.location,
                    rawLittlePIP: littlePIP?.location,
                    rawLittleDIP: littleDIP?.location,
                    rawLittleTip: littleTip?.location,
                    rawThumbCMC: thumbCMC?.location,
                    rawThumbMP: thumbMP?.location,
                    rawThumbIP: thumbIP?.location,
                    secondaryPinchDistance: secondaryPinchDistance,
                    secondaryIndexTip: secondaryIndexTip
                )

                DispatchQueue.main.async {
                    self.delegate?.handTracker(self, didDetectPose: pose)
                }
            } catch {
                DispatchQueue.main.async {
                    self.delegate?.handTracker(self, didDetectPose: nil)
                }
            }
        }
    }

    func visionToScreen(_ point: VNRecognizedPoint) -> CGPoint {
        guard let screen = NSScreen.main else {
            return .zero
        }

        let visionX = point.location.x
        let visionY = point.location.y

        let mirroredX = 1.0 - visionX

        let margin: CGFloat = 0.15
        let mappedX = ((mirroredX - margin) / (1.0 - 2.0 * margin))
            .clamped(to: 0...1)
        let mappedY = ((visionY - margin) / (1.0 - 2.0 * margin))
            .clamped(to: 0...1)

        let screenWidth = screen.frame.width
        let screenHeight = screen.frame.height

        let cgX = mappedX * screenWidth
        let cgY = (1.0 - mappedY) * screenHeight

        return CGPoint(x: cgX, y: cgY)
    }

    private func smoothedPoint(_ point: CGPoint, key: String, timestamp: Double) -> CGPoint {
        if jointSmoothers[key] == nil {
            jointSmoothers[key] = SmoothingFilter()
        }
        guard let smoother = jointSmoothers[key] else { return point }
        return smoother.filter(point: point, timestamp: timestamp)
    }

    private func recognizedPoint(
        _ observation: VNHumanHandPoseObservation,
        joint: VNHumanHandPoseObservation.JointName,
        minimumConfidence: Float
    ) -> VNRecognizedPoint? {
        guard let point = try? observation.recognizedPoint(joint), point.confidence > minimumConfidence else {
            return nil
        }
        return point
    }
}

extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
