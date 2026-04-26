import Foundation
import CoreGraphics

struct LowPassFilter {
    var y: Double = 0
    var dy: Double = 0
    var initialized = false

    mutating func filter(x: Double, alpha: Double) -> Double {
        guard initialized else {
            y = x
            dy = 0
            initialized = true
            return x
        }

        dy = x - y
        y = alpha * x + (1 - alpha) * y
        return y
    }
}

struct OneEuroFilter {
    private let minCutoff: Double
    private let beta: Double
    private let dCutoff: Double

    private var xFilter = LowPassFilter()
    private var dxFilter = LowPassFilter()

    init(minCutoff: Double = 0.5, beta: Double = 0.003, dCutoff: Double = 1.0) {
        self.minCutoff = minCutoff
        self.beta = beta
        self.dCutoff = dCutoff
    }

    mutating func filter(x: Double, dt: Double) -> Double {
        let safeDt = max(dt, .leastNonzeroMagnitude)

        let dx = xFilter.initialized ? (x - xFilter.y) / safeDt : 0
        let aD = alpha(cutoff: dCutoff, dt: safeDt)
        let dxHat = dxFilter.filter(x: dx, alpha: aD)

        let cutoff = minCutoff + beta * abs(dxHat)
        let a = alpha(cutoff: cutoff, dt: safeDt)
        return xFilter.filter(x: x, alpha: a)
    }

    private func alpha(cutoff: Double, dt: Double) -> Double {
        let numerator = 2.0 * Double.pi * cutoff * dt
        return numerator / (numerator + 1.0)
    }
}

final class SmoothingFilter {
    private let minCutoff: Double
    private let beta: Double
    private let dCutoff: Double
    private var filterX: OneEuroFilter
    private var filterY: OneEuroFilter
    private var lastTimestamp: Double? = nil

    /// Stronger smoothing (lower `minCutoff`) approximates visionOS-style stabilized indirect rays.
    init(minCutoff: Double = 0.5, beta: Double = 0.003, dCutoff: Double = 1.0) {
        self.minCutoff = minCutoff
        self.beta = beta
        self.dCutoff = dCutoff
        filterX = OneEuroFilter(minCutoff: minCutoff, beta: beta, dCutoff: dCutoff)
        filterY = OneEuroFilter(minCutoff: minCutoff, beta: beta, dCutoff: dCutoff)
    }

    func filter(point: CGPoint, timestamp: Double) -> CGPoint {
        let dt: Double
        if let lastTimestamp {
            dt = max(timestamp - lastTimestamp, .leastNonzeroMagnitude)
        } else {
            dt = 1.0 / 60.0
        }

        self.lastTimestamp = timestamp

        return CGPoint(
            x: filterX.filter(x: Double(point.x), dt: dt),
            y: filterY.filter(x: Double(point.y), dt: dt)
        )
    }

    func reset() {
        filterX = OneEuroFilter(minCutoff: minCutoff, beta: beta, dCutoff: dCutoff)
        filterY = OneEuroFilter(minCutoff: minCutoff, beta: beta, dCutoff: dCutoff)
        lastTimestamp = nil
    }
}
