import Combine
import Foundation

/// A personalized gesture classifier that uses on-device machine learning to
/// learn adaptive detection thresholds from the user's own calibration data.
///
/// **How it works:**
/// During calibration, the user performs 20 wrist flicks and 20 fist clenches.
/// From each set, the classifier extracts statistical parameters (mean, std dev,
/// percentiles) of key discriminative features. These become personalized
/// thresholds for the temporal gesture detector.
///
/// This is supervised parameter estimation — a core ML technique that adapts
/// detection to the individual rather than relying on fixed thresholds. The
/// approach combines ML-learned parameters with temporal detection logic
/// (spike duration for flick, sustained variance for clench) to achieve both
/// personalization and reliability.
///
/// The trained model is persisted to disk so it survives app restarts.
final class PersonalGestureClassifier: ObservableObject {

    // MARK: - Types

    /// Per-class statistical profile learned from calibration data.
    struct GestureProfile: Codable {
        let label: String
        let sampleCount: Int
        let featureMeans: [Double]     // 10 features
        let featureStdDevs: [Double]   // 10 features
    }

    /// ML-learned adaptive thresholds derived from calibration samples.
    struct AdaptiveThresholds: Codable {
        // Flick thresholds (learned from user's flick samples)
        let flickSpikeMin: Double        // minimum spike deviation to consider a flick
        let flickSpikeMean: Double       // typical spike magnitude
        let flickDurationMean: Double    // typical flick duration
        let flickDurationMax: Double     // maximum plausible flick duration
        let flickVarianceCeiling: Double // max variance during a flick (flicks have low sustained variance)

        // Clench thresholds (learned from user's clench samples)
        let clenchVarianceMin: Double    // minimum variance to consider a clench
        let clenchVarianceMean: Double   // typical clench variance
        let clenchSpikeCeiling: Double   // max spike from a clench (clenches have lower peaks than flicks)
        let clenchEnergyMin: Double      // minimum energy burst for a clench

        // Discrimination boundary
        let flickVsClenchPeakBoundary: Double  // spike above this = likely flick
        let flickVsClenchVarBoundary: Double   // variance above this = likely clench
    }

    /// Classification result with confidence scores.
    struct ClassificationResult {
        let predictedLabel: String
        let confidence: Double         // 0-1
        let scores: [String: Double]   // per-class scores
    }

    // MARK: - Published State

    /// Whether a trained model is loaded and ready.
    @Published var isReady: Bool = false

    /// The gesture profiles (one per trained gesture class).
    @Published private(set) var profiles: [GestureProfile] = []

    /// The set of labels that were trained (e.g. ["flick", "rotation"]).
    var trainedLabels: Set<String> {
        Set(profiles.map { $0.label.lowercased() })
    }

    /// ML-learned adaptive thresholds.
    @Published private(set) var adaptiveThresholds: AdaptiveThresholds? = nil

    /// Minimum confidence threshold. Below this, classification returns nil.
    @Published var confidenceThreshold: Double = 0.6

    // MARK: - Persistence

    private let storageKey = "MorseGesture.personalClassifier"
    private let thresholdsKey = "MorseGesture.adaptiveThresholds"

    // MARK: - Init

    init() {
        loadFromDisk()
    }

    // MARK: - Training

    /// Train the classifier from recorded gesture samples.
    /// Extracts per-class statistics AND computes adaptive detection thresholds.
    ///
    /// - Parameter samples: All recorded samples from the calibration session.
    /// - Parameter minSamplesPerClass: Minimum samples required per gesture (default 10).
    /// - Returns: True if training succeeded.
    @discardableResult
    func train(from samples: [GestureRecorder.GestureSample], minSamplesPerClass: Int = 10) -> Bool {
        // Group by label
        var grouped: [String: [[Double]]] = [:]
        for sample in samples {
            let vec = featureArray(from: sample.features)
            grouped[sample.label, default: []].append(vec)
        }

        // Validate: each class needs enough samples
        for (label, vectors) in grouped {
            if vectors.count < minSamplesPerClass {
                print("[PersonalGestureClassifier] Not enough samples for '\(label)': \(vectors.count) < \(minSamplesPerClass)")
                return false
            }
        }

        // Compute profiles (keep for display and Gaussian fallback)
        var newProfiles: [GestureProfile] = []
        for (label, vectors) in grouped {
            let featureCount = vectors[0].count
            var means = [Double](repeating: 0, count: featureCount)
            var stdDevs = [Double](repeating: 0, count: featureCount)

            // Compute means
            for vec in vectors {
                for i in 0..<featureCount {
                    means[i] += vec[i]
                }
            }
            let n = Double(vectors.count)
            for i in 0..<featureCount {
                means[i] /= n
            }

            // Compute standard deviations
            for vec in vectors {
                for i in 0..<featureCount {
                    let diff = vec[i] - means[i]
                    stdDevs[i] += diff * diff
                }
            }
            for i in 0..<featureCount {
                stdDevs[i] = sqrt(stdDevs[i] / max(n - 1, 1))
                stdDevs[i] = max(stdDevs[i], 1e-6)
            }

            newProfiles.append(GestureProfile(
                label: label,
                sampleCount: vectors.count,
                featureMeans: means,
                featureStdDevs: stdDevs
            ))
        }

        profiles = newProfiles

        // --- LEARN ADAPTIVE THRESHOLDS ---
        // Feature indices (from GestureRecorder.FeatureVector):
        //  0: peakMagnitude
        //  1: meanMagnitude
        //  2: magnitudeVariance
        //  3: peakDeviation
        //  4: duration
        //  5: rmsAcceleration
        //  6: tiltAngleChange
        //  7: zeroCrossings
        //  8: peakToTrough
        //  9: energyBurst

        let flickVectors = grouped["flick"] ?? grouped["pinch"] ?? []
        let rotationVectors = grouped["rotation"] ?? []
        let clenchVectors = grouped["clench"] ?? []

        // Need at least flick + one other gesture type
        let secondGesture = !rotationVectors.isEmpty ? rotationVectors : clenchVectors
        guard !flickVectors.isEmpty && !secondGesture.isEmpty else {
            isReady = !profiles.isEmpty
            saveToDisk()
            return true
        }

        // Extract key features per class
        let flickPeaks = flickVectors.map { $0[0] }         // peakMagnitude
        let flickVariances = flickVectors.map { $0[2] }     // magnitudeVariance
        let flickDurations = flickVectors.map { $0[4] }     // duration
        let flickDeviations = flickVectors.map { $0[3] }    // peakDeviation
        let flickEnergies = flickVectors.map { $0[9] }      // energyBurst

        let otherPeaks = secondGesture.map { $0[0] }        // peakMagnitude
        let otherVariances = secondGesture.map { $0[2] }    // magnitudeVariance
        let otherDeviations = secondGesture.map { $0[3] }   // peakDeviation
        let otherEnergies = secondGesture.map { $0[9] }     // energyBurst

        // Compute adaptive thresholds using learned distributions
        let thresholds = AdaptiveThresholds(
            // Flick: learn from the lower end of flick spike distribution
            flickSpikeMin: percentile(flickDeviations, p: 0.10),
            flickSpikeMean: mean(flickDeviations),
            flickDurationMean: mean(flickDurations),
            flickDurationMax: percentile(flickDurations, p: 0.95),
            flickVarianceCeiling: percentile(flickVariances, p: 0.90),

            // Second gesture: learn from its distribution
            clenchVarianceMin: percentile(otherVariances, p: 0.10),
            clenchVarianceMean: mean(otherVariances),
            clenchSpikeCeiling: percentile(otherPeaks, p: 0.90),
            clenchEnergyMin: percentile(otherEnergies, p: 0.10),

            // Discrimination boundaries
            flickVsClenchPeakBoundary: (mean(flickDeviations) + mean(otherDeviations)) / 2.0,
            flickVsClenchVarBoundary: (mean(flickVariances) + mean(otherVariances)) / 2.0
        )

        adaptiveThresholds = thresholds
        isReady = !profiles.isEmpty
        saveToDisk()

        print("[PersonalGestureClassifier] Trained with \(profiles.count) classes: \(profiles.map { "\($0.label)(\($0.sampleCount))" }.joined(separator: ", "))")
        print("[PersonalGestureClassifier] Adaptive thresholds: flickSpikeMin=\(String(format: "%.4f", thresholds.flickSpikeMin)), clenchVarMin=\(String(format: "%.6f", thresholds.clenchVarianceMin)), peakBoundary=\(String(format: "%.4f", thresholds.flickVsClenchPeakBoundary))")

        return true
    }

    // MARK: - Classification

    /// Classify a new gesture using adaptive thresholds + Gaussian scoring.
    /// Returns nil if confidence is below threshold or no model is loaded.
    func classify(_ features: GestureRecorder.FeatureVector) -> ClassificationResult? {
        guard isReady, !profiles.isEmpty else { return nil }

        let vec = featureArray(from: features)

        // If we have adaptive thresholds, use the hybrid approach
        if let thresholds = adaptiveThresholds {
            return classifyWithAdaptiveThresholds(vec, features: features, thresholds: thresholds)
        }

        // Fallback to pure Gaussian Naive Bayes
        return classifyGaussian(vec)
    }

    /// Classify using ONLY the Gaussian Naive Bayes model (bypasses rule-based
    /// adaptive thresholds). This is better for confirmation gating in the
    /// gesture detector because the Gaussian model was trained directly on the
    /// user's calibration data distributions. The rule-based classifier was
    /// designed for flick-vs-clench discrimination and doesn't handle
    /// flick-vs-rotation well.
    ///
    /// - Parameter features: The extracted feature vector.
    /// - Parameter minConfidence: Override the default confidence threshold
    ///   (useful for confirmation where lower confidence is acceptable).
    /// - Returns: Classification result, or nil if below confidence threshold.
    func classifyGaussianOnly(
        _ features: GestureRecorder.FeatureVector,
        minConfidence: Double? = nil
    ) -> ClassificationResult? {
        guard isReady, !profiles.isEmpty else { return nil }

        let vec = featureArray(from: features)
        let threshold = minConfidence ?? confidenceThreshold

        var scores: [String: Double] = [:]

        for profile in profiles {
            var logLikelihood: Double = 0
            for i in 0..<min(vec.count, profile.featureMeans.count) {
                let mean = profile.featureMeans[i]
                let std = profile.featureStdDevs[i]
                let x = vec[i]
                let z = (x - mean) / std
                logLikelihood += -0.5 * z * z - log(std)
            }
            scores[profile.label] = logLikelihood
        }

        let sorted = scores.sorted { $0.value > $1.value }
        guard let best = sorted.first else { return nil }

        let logLikelihoods = sorted.map { $0.value }
        let maxLL = logLikelihoods[0]
        let expSum = logLikelihoods.reduce(0.0) { $0 + exp($1 - maxLL) }
        let confidence = 1.0 / expSum

        guard confidence >= threshold else { return nil }

        return ClassificationResult(
            predictedLabel: best.key,
            confidence: confidence,
            scores: scores
        )
    }

    /// Hybrid classification: use ML-learned thresholds for the primary signal,
    /// then Gaussian scoring for confidence.
    ///
    /// Uses dynamic labels from trained profiles instead of hardcoded names,
    /// so training with "flick" + "rotation" correctly outputs "rotation"
    /// (not "clench").
    ///
    /// IMPORTANT: This classifier handles BOTH flick-vs-clench AND
    /// flick-vs-rotation. The key discriminators differ:
    ///   - Flick vs Clench: peak deviation (flick high) vs variance (clench high)
    ///   - Flick vs Rotation: tiltAngleChange (rotation high), duration (rotation
    ///     long), peak deviation (flick high, rotation low)
    private func classifyWithAdaptiveThresholds(
        _ vec: [Double],
        features: GestureRecorder.FeatureVector,
        thresholds: AdaptiveThresholds
    ) -> ClassificationResult? {
        let peakDeviation = features.peakDeviation
        let variance = features.magnitudeVariance
        let energyBurst = features.energyBurst
        let tiltAngleChange = features.tiltAngleChange
        let duration = features.duration

        // Dynamic labels: "flick" is always the primary, the second label
        // comes from whatever the user trained (rotation, clench, etc.)
        let secondLabel: String = profiles.first(where: { $0.label != "flick" })?.label ?? "rotation"
        let isRotationMode = (secondLabel == "rotation")

        var flickScore: Double = 0
        var secondScore: Double = 0

        if isRotationMode {
            // --- FLICK vs ROTATION discrimination ---
            // These gestures differ in fundamentally different ways than
            // flick vs clench. Rotation is a slow, smooth gravity vector
            // shift; flick is a fast spike.

            // Rule 1: Tilt angle change (strongest discriminator for rotation)
            // Rotation produces large tilt angle change (wrist turning),
            // flick produces small tilt change (quick snap, wrist stays put)
            if tiltAngleChange > 10.0 {
                secondScore += 3.0  // large tilt = rotation
            } else if tiltAngleChange < 5.0 {
                flickScore += 3.0   // small tilt = flick
            } else {
                // Ambiguous zone, slight lean toward flick
                flickScore += 1.0
            }

            // Rule 2: Duration (rotation is slow, flick is fast)
            if duration > 0.5 {
                secondScore += 2.0  // long gesture = rotation
            } else if duration < 0.2 {
                flickScore += 2.5   // very short = flick
            } else {
                flickScore += 1.0   // medium duration, slight lean flick
            }

            // Rule 3: Peak deviation (flicks have sharp spikes, rotation doesn't)
            if peakDeviation > thresholds.flickVsClenchPeakBoundary {
                flickScore += 2.5
            } else if peakDeviation < thresholds.flickSpikeMin * 0.5 {
                secondScore += 2.0  // very low peak = definitely not a flick
            } else {
                // In between, slight lean based on direction
                flickScore += 0.5
            }

            // Rule 4: Energy burst pattern
            if energyBurst > thresholds.clenchEnergyMin {
                let peakToVarRatio = peakDeviation / max(variance, 1e-6)
                if peakToVarRatio > 50 {
                    flickScore += 1.5  // sharp spike relative to variance
                } else {
                    secondScore += 1.0
                }
            }

        } else {
            // --- FLICK vs CLENCH discrimination (original logic) ---

            // Rule 1: Peak deviation (flicks have sharp spikes)
            if peakDeviation > thresholds.flickVsClenchPeakBoundary {
                flickScore += 3.0
            } else {
                secondScore += 2.0
            }

            // Rule 2: Variance (sustained high variance = clench)
            if variance > thresholds.flickVsClenchVarBoundary {
                secondScore += 3.0
            } else {
                flickScore += 2.0
            }

            // Rule 3: Check against learned minimums
            if peakDeviation >= thresholds.flickSpikeMin {
                flickScore += 1.0
            }
            if variance >= thresholds.clenchVarianceMin {
                secondScore += 1.0
            }

            // Rule 4: Energy burst pattern
            if energyBurst > thresholds.clenchEnergyMin {
                let peakToVarRatio = peakDeviation / max(variance, 1e-6)
                if peakToVarRatio > 50 {
                    flickScore += 2.0  // high peak, low variance = flick
                } else {
                    secondScore += 1.5
                }
            }

            // Rule 5: Variance ceiling check
            if variance > thresholds.flickVarianceCeiling * 1.5 {
                secondScore += 1.5
            }
        }

        // Compute confidence
        let total = flickScore + secondScore
        guard total > 0 else { return nil }

        let flickConf = flickScore / total
        let secondConf = secondScore / total

        let predicted: String
        let confidence: Double
        if flickScore > secondScore {
            predicted = "flick"
            confidence = flickConf
        } else {
            predicted = secondLabel
            confidence = secondConf
        }

        guard confidence >= confidenceThreshold else { return nil }

        return ClassificationResult(
            predictedLabel: predicted,
            confidence: confidence,
            scores: ["flick": flickConf, secondLabel: secondConf]
        )
    }

    /// Pure Gaussian Naive Bayes classification (fallback).
    private func classifyGaussian(_ vec: [Double]) -> ClassificationResult? {
        var scores: [String: Double] = [:]

        for profile in profiles {
            var logLikelihood: Double = 0
            for i in 0..<min(vec.count, profile.featureMeans.count) {
                let mean = profile.featureMeans[i]
                let std = profile.featureStdDevs[i]
                let x = vec[i]
                let z = (x - mean) / std
                logLikelihood += -0.5 * z * z - log(std)
            }
            scores[profile.label] = logLikelihood
        }

        let sorted = scores.sorted { $0.value > $1.value }
        guard let best = sorted.first else { return nil }

        let logLikelihoods = sorted.map { $0.value }
        let maxLL = logLikelihoods[0]
        let expSum = logLikelihoods.reduce(0.0) { $0 + exp($1 - maxLL) }
        let confidence = 1.0 / expSum

        guard confidence >= confidenceThreshold else { return nil }

        return ClassificationResult(
            predictedLabel: best.key,
            confidence: confidence,
            scores: scores
        )
    }

    // MARK: - Model Management

    /// Delete the trained model and start fresh.
    func reset() {
        profiles = []
        adaptiveThresholds = nil
        isReady = false
        UserDefaults.standard.removeObject(forKey: storageKey)
        UserDefaults.standard.removeObject(forKey: thresholdsKey)
    }

    /// Check if a specific gesture class is trained.
    func hasProfile(for label: String) -> Bool {
        profiles.contains { $0.label == label }
    }

    /// Get the sample count used for training a specific class.
    func sampleCount(for label: String) -> Int {
        profiles.first { $0.label == label }?.sampleCount ?? 0
    }

    // MARK: - Statistics Helpers

    private func mean(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    private func percentile(_ values: [Double], p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = min(Int(Double(sorted.count) * p), sorted.count - 1)
        return sorted[max(0, index)]
    }

    // MARK: - Feature Conversion

    /// Convert a FeatureVector struct to a plain array for math operations.
    func featureArray(from f: GestureRecorder.FeatureVector) -> [Double] {
        [
            f.peakMagnitude,
            f.meanMagnitude,
            f.magnitudeVariance,
            f.peakDeviation,
            f.duration,
            f.rmsAcceleration,
            f.tiltAngleChange,
            Double(f.zeroCrossings),
            f.peakToTrough,
            f.energyBurst,
        ]
    }

    // MARK: - Persistence

    private func saveToDisk() {
        if let data = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
        if let thresholds = adaptiveThresholds,
           let data = try? JSONEncoder().encode(thresholds) {
            UserDefaults.standard.set(data, forKey: thresholdsKey)
        }
    }

    private func loadFromDisk() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let saved = try? JSONDecoder().decode([GestureProfile].self, from: data) {
            profiles = saved
        }
        if let data = UserDefaults.standard.data(forKey: thresholdsKey),
           let saved = try? JSONDecoder().decode(AdaptiveThresholds.self, from: data) {
            adaptiveThresholds = saved
        }
        isReady = !profiles.isEmpty
    }
}
