import Combine
import CoreMotion
import Foundation

/// Records windows of accelerometer data during gesture calibration.
///
/// Usage:
///   1. Call `startListening()` to begin streaming accelerometer data.
///   2. When the user is about to perform a gesture, call `beginCapture()`.
///   3. When the gesture is done (or after a timeout), call `endCapture()`
///      to extract the window and compute features.
///   4. Repeat for each sample.
///   5. Call `stopListening()` when calibration is complete.
final class GestureRecorder: ObservableObject {

    // MARK: - Types

    /// A single recorded gesture sample with extracted features.
    struct GestureSample: Codable {
        let label: String              // e.g. "flick", "clench"
        let features: FeatureVector
        let timestamp: Date
    }

    /// Feature vector extracted from a window of accelerometer data.
    struct FeatureVector: Codable {
        let peakMagnitude: Double       // max acceleration in window
        let meanMagnitude: Double       // average acceleration
        let magnitudeVariance: Double   // variance of acceleration
        let peakDeviation: Double       // max deviation from baseline
        let duration: Double            // seconds the signal was above threshold
        let rmsAcceleration: Double     // root mean square of acceleration
        let tiltAngleChange: Double     // how much the gravity vector shifted
        let zeroCrossings: Int          // crossings of the mean (captures tremor)
        let peakToTrough: Double        // range of acceleration values
        let energyBurst: Double         // sum of squared deviations (captures intensity)
    }

    // MARK: - Published State

    @Published var isListening: Bool = false
    @Published var isCapturing: Bool = false
    @Published var currentMagnitude: Double = 0.0
    @Published var samplesCollected: [String: Int] = [:]  // label -> count

    // MARK: - Collected Data

    private(set) var allSamples: [GestureSample] = []

    // MARK: - Private

    private let motionManager = CMMotionManager()
    private let updateInterval: TimeInterval = 1.0 / 50.0  // 50 Hz

    // Ring buffer of recent accelerometer readings
    private var ringBuffer: [(magnitude: Double, x: Double, y: Double, z: Double, time: Date)] = []
    private let ringBufferMaxSize = 100  // 2 seconds at 50Hz

    // Capture window
    private var captureStartTime: Date? = nil
    private var captureBuffer: [(magnitude: Double, x: Double, y: Double, z: Double, time: Date)] = []

    // Baseline (computed from initial quiet period)
    private var baselineMagnitude: Double = 1.0
    private var baselineGravity: (x: Double, y: Double, z: Double) = (0, 0, -1)
    private var gravityEstimate: (x: Double, y: Double, z: Double) = (0, 0, -1)
    private let gravityAlpha: Double = 0.1
    private let baselineAlpha: Double = 0.02

    // MARK: - Lifecycle

    /// Start the accelerometer stream (call before calibration begins).
    func startListening() {
        guard motionManager.isAccelerometerAvailable else {
            print("[GestureRecorder] Accelerometer not available")
            return
        }
        guard !isListening else { return }

        motionManager.accelerometerUpdateInterval = updateInterval
        motionManager.startAccelerometerUpdates(to: .main) { [weak self] data, error in
            guard let self = self, let data = data else { return }
            self.processData(data)
        }
        isListening = true

        // Calibrate baseline after settling
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.captureBaseline()
        }
    }

    /// Stop the accelerometer stream.
    func stopListening() {
        motionManager.stopAccelerometerUpdates()
        isListening = false
        isCapturing = false
    }

    /// Snapshot the current resting state as baseline.
    func captureBaseline() {
        baselineMagnitude = currentMagnitude > 0 ? currentMagnitude : 1.0
        baselineGravity = gravityEstimate
    }

    // MARK: - Capture Controls

    /// Begin recording a gesture window. Call right before prompting the user.
    func beginCapture() {
        captureBuffer.removeAll()
        captureStartTime = Date()
        isCapturing = true
    }

    /// End the current capture and extract features.
    /// Returns nil if the capture was too short or had no meaningful data.
    func endCapture(label: String) -> GestureSample? {
        isCapturing = false
        guard !captureBuffer.isEmpty else { return nil }

        let features = extractFeatures(from: captureBuffer)
        let sample = GestureSample(
            label: label,
            features: features,
            timestamp: Date()
        )

        allSamples.append(sample)
        samplesCollected[label] = (samplesCollected[label] ?? 0) + 1

        captureBuffer.removeAll()
        captureStartTime = nil

        return sample
    }

    /// Clear all recorded samples (start over).
    func reset() {
        allSamples.removeAll()
        samplesCollected.removeAll()
    }

    /// Get all samples for a specific gesture label.
    func samples(for label: String) -> [GestureSample] {
        allSamples.filter { $0.label == label }
    }

    // MARK: - Data Processing

    private func processData(_ data: CMAccelerometerData) {
        let acc = data.acceleration
        let magnitude = sqrt(acc.x * acc.x + acc.y * acc.y + acc.z * acc.z)
        let now = Date()

        currentMagnitude = magnitude

        // Update gravity estimate
        gravityEstimate.x = gravityEstimate.x * (1 - gravityAlpha) + acc.x * gravityAlpha
        gravityEstimate.y = gravityEstimate.y * (1 - gravityAlpha) + acc.y * gravityAlpha
        gravityEstimate.z = gravityEstimate.z * (1 - gravityAlpha) + acc.z * gravityAlpha

        // Update baseline when not capturing
        if !isCapturing {
            baselineMagnitude = baselineMagnitude * (1 - baselineAlpha) + magnitude * baselineAlpha
        }

        let entry = (magnitude: magnitude, x: acc.x, y: acc.y, z: acc.z, time: now)

        // Ring buffer (always running)
        ringBuffer.append(entry)
        if ringBuffer.count > ringBufferMaxSize {
            ringBuffer.removeFirst()
        }

        // Capture buffer (only when actively capturing)
        if isCapturing {
            captureBuffer.append(entry)
        }
    }

    // MARK: - Feature Extraction

    /// Extract a feature vector from a window of accelerometer readings.
    func extractFeatures(
        from window: [(magnitude: Double, x: Double, y: Double, z: Double, time: Date)]
    ) -> FeatureVector {
        guard !window.isEmpty else {
            return FeatureVector(
                peakMagnitude: 0, meanMagnitude: 0, magnitudeVariance: 0,
                peakDeviation: 0, duration: 0, rmsAcceleration: 0,
                tiltAngleChange: 0, zeroCrossings: 0, peakToTrough: 0,
                energyBurst: 0
            )
        }

        let magnitudes = window.map { $0.magnitude }
        let count = Double(magnitudes.count)

        // Basic statistics
        let mean = magnitudes.reduce(0, +) / count
        let peak = magnitudes.max() ?? 0
        let trough = magnitudes.min() ?? 0
        let variance: Double = {
            guard magnitudes.count > 1 else { return 0 }
            let sumSq = magnitudes.reduce(0.0) { $0 + ($1 - mean) * ($1 - mean) }
            return sumSq / (count - 1)
        }()

        // Peak deviation from baseline
        let peakDeviation = magnitudes.map { abs($0 - baselineMagnitude) }.max() ?? 0

        // Duration above threshold (baseline + small margin)
        let threshold = baselineMagnitude + 0.1
        let samplesAbove = magnitudes.filter { $0 > threshold }.count
        let duration = Double(samplesAbove) * updateInterval

        // RMS acceleration
        let rms = sqrt(magnitudes.map { $0 * $0 }.reduce(0, +) / count)

        // Tilt angle change: angle between gravity at start vs end of window
        let startGravity = (x: window.first!.x, y: window.first!.y, z: window.first!.z)
        let endGravity = (x: window.last!.x, y: window.last!.y, z: window.last!.z)
        let tiltChange = angleBetween(a: startGravity, b: endGravity)

        // Zero crossings of the deviation from mean (captures oscillation/tremor)
        var zeroCrossings = 0
        for i in 1..<magnitudes.count {
            let prev = magnitudes[i-1] - mean
            let curr = magnitudes[i] - mean
            if (prev > 0 && curr <= 0) || (prev <= 0 && curr > 0) {
                zeroCrossings += 1
            }
        }

        // Energy burst: sum of squared deviations from baseline
        let energy = magnitudes.reduce(0.0) { sum, m in
            let dev = m - baselineMagnitude
            return sum + dev * dev
        }

        return FeatureVector(
            peakMagnitude: peak,
            meanMagnitude: mean,
            magnitudeVariance: variance,
            peakDeviation: peakDeviation,
            duration: duration,
            rmsAcceleration: rms,
            tiltAngleChange: tiltChange,
            zeroCrossings: zeroCrossings,
            peakToTrough: peak - trough,
            energyBurst: energy
        )
    }

    // MARK: - Helpers

    private func angleBetween(
        a: (x: Double, y: Double, z: Double),
        b: (x: Double, y: Double, z: Double)
    ) -> Double {
        let dot = a.x * b.x + a.y * b.y + a.z * b.z
        let magA = sqrt(a.x * a.x + a.y * a.y + a.z * a.z)
        let magB = sqrt(b.x * b.x + b.y * b.y + b.z * b.z)
        guard magA > 0 && magB > 0 else { return 0 }
        let cosAngle = max(-1.0, min(1.0, dot / (magA * magB)))
        return acos(cosAngle) * 180.0 / .pi
    }

    deinit {
        stopListening()
    }
}
