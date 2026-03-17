import Combine
import CoreMotion
import Foundation

/// Detects distinct wrist gestures using the Apple Watch accelerometer:
///
/// - **Flick:** A quick wrist snap producing a sharp acceleration spike
///   that rapidly returns to baseline (< ~250ms). Uses magnitude domain.
///
/// - **Rotation:** Pronation/supination (turning the wrist like a doorknob).
///   Smoothly shifts the gravity vector across the x-z plane. Uses angular
///   domain — fundamentally different signal from flick (no spike, no
///   variance change, just smooth gravity rotation).
///
/// - **Tilt-and-hold:** Tilting the wrist to one side and holding.
///
/// - **Clench:** Closing the fist. Sustained variance from micro-tremors.
///
/// The recommended pair for Morse input is flick (dot) + rotation (dash).
/// These are on completely different signal domains, making cross-triggering
/// physically impossible.
///
/// IMPORTANT: Only works on a real Apple Watch. The simulator does not
/// generate accelerometer data.
final class AccelerometerGestureDetector: ObservableObject {

    // MARK: - Types

    /// The gesture types we can detect.
    enum DetectedGesture: String, CaseIterable, Codable {
        case flick     = "Flick"
        case rotation  = "Rotation"
        case tiltHold  = "Tilt & Hold"
        case clench    = "Clench"
    }

    // MARK: - Published State

    @Published var isActive: Bool = false
    @Published var currentMagnitude: Double = 0.0
    @Published var currentTiltDegrees: Double = 0.0
    @Published var currentVariance: Double = 0.0
    @Published var currentRotationAngle: Double = 0.0  // for rotation debug
    @Published var debugState: String = "Idle"
    @Published var lastGesture: DetectedGesture? = nil

    // MARK: - Flick Thresholds

    @Published var flickSpikeThreshold: Double = 0.35
    @Published var flickMaxDuration: TimeInterval = 0.25
    @Published var flickMinDuration: TimeInterval = 0.03

    // MARK: - Tilt-and-Hold Thresholds

    @Published var tiltAngleThreshold: Double = 15.0
    @Published var tiltHoldDuration: TimeInterval = 0.5

    // MARK: - Clench Thresholds

    /// Minimum variance of acceleration magnitude (over the sliding window)
    /// to consider a clench. Clenching increases micro-vibrations from
    /// isometric muscle contraction, raising the variance above resting.
    @Published var clenchVarianceThreshold: Double = 0.005

    /// How long (seconds) the variance must stay elevated to fire a clench.
    /// Increased to 0.7s so brief settling bumps don't trigger.
    /// A real clench sustains for seconds; settling lasts < 0.5s.
    @Published var clenchHoldDuration: TimeInterval = 0.7

    /// Size of the sliding window for variance calculation (number of samples).
    /// At 50Hz, 25 samples = 0.5s window.
    @Published var clenchWindowSize: Int = 25

    /// Number of consecutive variance samples that must exceed the threshold
    /// before clench timing starts. Prevents brief noise spikes from
    /// initiating clench detection.
    private var clenchConfirmationCount: Int = 0
    private let clenchConfirmationRequired: Int = 8  // ~0.16s at 50Hz

    // MARK: - Rotation Thresholds

    /// Minimum peak rotation angle (degrees) the wrist must reach for a
    /// rotation gesture to count. Set to 21° — just above the 20° entry
    /// threshold. Tight coupling prevents false "Rotation STARTED" entries
    /// that never fire (which suppress flick detection while active).
    @Published var rotationAngleThreshold: Double = 21.0

    /// The rotation angle must exceed this to START tracking, and must
    /// return below this to FIRE. Raised from 15° to 20° because gravity
    /// drift causes the resting angle to hover at 15-17°, which was
    /// triggering constant false "Rotation STARTED" entries that
    /// suppressed flick detection via wind-up cancellation.
    @Published var rotationReturnThreshold: Double = 20.0

    /// Maximum time (seconds) allowed for a complete rotation gesture.
    @Published var rotationMaxDuration: TimeInterval = 2.0

    /// Minimum time for a rotation to avoid spurious triggers from vibration.
    @Published var rotationMinDuration: TimeInterval = 0.3

    // MARK: - General

    @Published var cooldownInterval: TimeInterval = 1.0

    // MARK: - Detection Mode

    enum DetectionMode: String, CaseIterable {
        case threshold    = "Threshold"     // Original threshold-based detection
        case clenchOnly   = "Clench Only"   // Only detect clench (for hybrid Double Tap + Clench)
        case personal     = "Personal ML"   // Trained from user's calibration data
    }

    @Published var detectionMode: DetectionMode = .threshold

    /// The personal classifier (set after calibration).
    var personalClassifier: PersonalGestureClassifier? {
        didSet {
            if personalClassifier?.isReady == true {
                detectionMode = .personal
            }
        }
    }

    // MARK: - Callback

    var onGesture: ((DetectedGesture) -> Void)?

    // MARK: - Private State

    private let motionManager = CMMotionManager()
    private let updateInterval: TimeInterval = 1.0 / 50.0  // 50 Hz

    // ML mode: sliding window of raw data (always running when in personal mode)
    private var slidingWindow: [(magnitude: Double, x: Double, y: Double, z: Double, time: Date)] = []
    private let slidingWindowSize = 40  // 0.8s at 50Hz — enough to capture a gesture
    private let featureExtractor = GestureRecorder()  // used only for extractFeatures()

    // Baseline
    private var baselineMagnitude: Double = 1.0
    private let baselineAlpha: Double = 0.01

    // Resting orientation
    private var restingGravity: (x: Double, y: Double, z: Double) = (0, 0, -1)
    private var hasCalibrated: Bool = false

    // Gravity estimation (low-pass filter)
    private var gravityEstimate: (x: Double, y: Double, z: Double) = (0, 0, -1)
    private let gravityAlpha: Double = 0.15

    // Flick state
    private var flickStartTime: Date? = nil
    private var isInFlickSpike: Bool = false
    private var flickPeakSpike: Double = 0.0  // track max spike during flick window

    // Tilt state
    private var tiltStartTime: Date? = nil
    private var isInTilt: Bool = false
    private var tiltFired: Bool = false

    // Clench state
    private var magnitudeWindow: [Double] = []
    private var clenchStartTime: Date? = nil
    private var isInClench: Bool = false
    private var clenchFired: Bool = false
    private var restingVariance: Double = 0.001

    // Rotation state
    private var rotationStartTime: Date? = nil
    private var rotationStartAngle: Double = 0.0
    private var rotationPeakAngle: Double = 0.0
    private var isInRotation: Bool = false
    private var rotationReachedThreshold: Bool = false
    private var rotationFired: Bool = false
    /// Wind-up zone: rotation angle is building (> half the return threshold)
    /// but hasn't crossed the full rotation entry threshold yet. Suppresses
    /// flick detection to prevent the initial wrist acceleration from firing dots.
    ///
    /// IMPORTANT: Wind-up requires the angle to be sustained above the threshold
    /// for several consecutive samples. A flick creates a brief transient angular
    /// shift that should NOT trigger suppression.
    private var isRotationWindUp: Bool = false
    private let rotationWindUpAngle: Double = 12.0  // degrees (raised from 8° to match higher rotation thresholds)
    private var rotationWindUpCount: Int = 0
    private let rotationWindUpRequired: Int = 5  // ~100ms at 50Hz: must be sustained

    // General
    private var lastGestureTime: Date = .distantPast
    private var hasLoggedThresholds: Bool = false

    // MARK: - Lifecycle

    func start() {
        guard motionManager.isAccelerometerAvailable else {
            print("[AccelerometerGestureDetector] Accelerometer not available (simulator?)")
            return
        }
        guard !isActive else { return }

        motionManager.accelerometerUpdateInterval = updateInterval
        motionManager.startAccelerometerUpdates(to: .main) { [weak self] data, error in
            guard let self = self, let data = data else { return }
            self.processAccelerometerData(data)
        }

        isActive = true
        debugState = "Listening"

        if !hasCalibrated {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.calibrateBaseline()
            }
        }
    }

    func stop() {
        motionManager.stopAccelerometerUpdates()
        isActive = false
        resetAllState()
        debugState = "Stopped"
    }

    // MARK: - Signal Processing

    private func processAccelerometerData(_ data: CMAccelerometerData) {
        let acc = data.acceleration
        let magnitude = sqrt(acc.x * acc.x + acc.y * acc.y + acc.z * acc.z)

        currentMagnitude = magnitude

        // Update gravity estimate
        gravityEstimate.x = gravityEstimate.x * (1 - gravityAlpha) + acc.x * gravityAlpha
        gravityEstimate.y = gravityEstimate.y * (1 - gravityAlpha) + acc.y * gravityAlpha
        gravityEstimate.z = gravityEstimate.z * (1 - gravityAlpha) + acc.z * gravityAlpha

        // Tilt angle (overall deviation from resting orientation)
        let tiltAngle = angleBetweenVectors(a: restingGravity, b: gravityEstimate)
        currentTiltDegrees = tiltAngle

        // Rotation angle: track the gravity vector's rotation in the x-z plane
        // (pronation/supination). When you rotate your wrist like a doorknob,
        // the x and z gravity components swap while y stays roughly constant.
        let rotAngle = xzPlaneAngle(from: restingGravity, to: gravityEstimate)
        currentRotationAngle = rotAngle

        // Spike deviation
        let spikeDeviation = abs(magnitude - baselineMagnitude)

        // Sliding window for variance (clench detection)
        magnitudeWindow.append(magnitude)
        if magnitudeWindow.count > clenchWindowSize {
            magnitudeWindow.removeFirst()
        }
        let variance = computeVariance(magnitudeWindow)
        currentVariance = variance

        // Always maintain the sliding window for ML mode
        let now = Date()
        slidingWindow.append((magnitude: magnitude, x: acc.x, y: acc.y, z: acc.z, time: now))
        if slidingWindow.count > slidingWindowSize {
            slidingWindow.removeFirst()
        }

        let cooldownOk = now.timeIntervalSince(lastGestureTime) > cooldownInterval

        // Route to the appropriate detection pipeline
        if detectionMode == .personal, let classifier = personalClassifier, classifier.isReady {
            processMLDetection(
                spikeDeviation: spikeDeviation,
                now: now,
                cooldownOk: cooldownOk,
                classifier: classifier
            )
            return
        }

        if detectionMode == .clenchOnly {
            // --- CLENCH-ONLY MODE (for hybrid: Double Tap handles dot) ---
            detectClench(variance: variance, now: now, cooldownOk: cooldownOk)

            // Update baseline when idle
            if !isInClench {
                baselineMagnitude = baselineMagnitude * (1 - baselineAlpha) + magnitude * baselineAlpha
                restingVariance = restingVariance * 0.99 + variance * 0.01
            }

            // Debug state
            if isInClench {
                let elapsed = clenchStartTime.map { now.timeIntervalSince($0) } ?? 0
                debugState = String(format: "Clench %.1fs", elapsed)
            } else {
                debugState = cooldownOk ? "Listening (clench)" : "Cooldown"
            }
            return
        }

        // --- THRESHOLD-BASED DETECTION ---

        // Track rotation wind-up: angle must be SUSTAINED above threshold
        // for several consecutive samples before suppressing flick. This
        // prevents a brief flick spike (which transiently shifts gravity
        // angle) from triggering false wind-up suppression.
        let absRotAngle = abs(rotAngle)
        if !isInRotation && absRotAngle > rotationWindUpAngle {
            rotationWindUpCount += 1
            isRotationWindUp = rotationWindUpCount >= rotationWindUpRequired
        } else if !isInRotation {
            rotationWindUpCount = 0
            isRotationWindUp = false
        }
        // Once in full rotation, wind-up is irrelevant (isInRotation handles it)

        // --- 1. ROTATION DETECTION (angular domain, HIGHEST PRIORITY) ---
        // Runs first because rotation is slow and smooth; flick's spike
        // detector can steal the initial acceleration if it runs first.
        detectRotation(rotationAngle: rotAngle, now: now, cooldownOk: cooldownOk)

        // --- 2. FLICK DETECTION (magnitude domain) ---
        // Suppressed during active rotation AND during sustained rotation wind-up.
        if !isInRotation && !isRotationWindUp {
            detectFlick(spikeDeviation: spikeDeviation, now: now, cooldownOk: cooldownOk)
        } else {
            // Cancel any in-progress flick spike
            if isInFlickSpike {
                print("[GESTURE] Flick CANCELLED by rotation (inRot=\(isInRotation) windUp=\(isRotationWindUp) angle=\(String(format: "%.1f", absRotAngle))° windUpCount=\(rotationWindUpCount))")
                isInFlickSpike = false
                flickStartTime = nil
            }
        }

        // --- 3. TILT-AND-HOLD DETECTION ---
        if !isInRotation && !isRotationWindUp {
            detectTilt(tiltAngle: tiltAngle, now: now, cooldownOk: cooldownOk)
        }

        // --- 4. CLENCH DETECTION ---
        if !isInFlickSpike && !isInTilt && !isInRotation && !isRotationWindUp {
            detectClench(variance: variance, now: now, cooldownOk: cooldownOk)
        }

        // Update baseline when idle — INCLUDING resting gravity.
        // Without this, the resting gravity goes stale when the user shifts
        // their arm, causing the rotation angle to hover at 15-16° at rest,
        // which permanently triggers rotation entry and suppresses flick.
        if !isInFlickSpike && !isInTilt && !isInClench && !isInRotation && !isRotationWindUp {
            baselineMagnitude = baselineMagnitude * (1 - baselineAlpha) + magnitude * baselineAlpha
            restingVariance = restingVariance * 0.99 + variance * 0.01
            // Adapt resting gravity toward current gravity. Alpha of 0.02 means
            // ~2.5s to fully adapt at 50Hz — fast enough to track posture drift
            // but paused during active gestures so it doesn't chase the signal.
            let gravDriftAlpha = 0.02
            restingGravity.x = restingGravity.x * (1 - gravDriftAlpha) + gravityEstimate.x * gravDriftAlpha
            restingGravity.y = restingGravity.y * (1 - gravDriftAlpha) + gravityEstimate.y * gravDriftAlpha
            restingGravity.z = restingGravity.z * (1 - gravDriftAlpha) + gravityEstimate.z * gravDriftAlpha
        }

        // Debug state
        if isInRotation {
            debugState = String(format: "Rot %.0f°", currentRotationAngle)
        } else if isRotationWindUp {
            debugState = String(format: "Rot? %.0f°", currentRotationAngle)
        } else if isInFlickSpike {
            debugState = "Flick..."
        } else if isInTilt {
            let elapsed = tiltStartTime.map { now.timeIntervalSince($0) } ?? 0
            debugState = String(format: "Tilt %.1fs", elapsed)
        } else if isInClench {
            let elapsed = clenchStartTime.map { now.timeIntervalSince($0) } ?? 0
            debugState = String(format: "Clench %.1fs", elapsed)
        } else {
            debugState = cooldownOk ? "Listening" : "Cooldown"
        }
    }

    // MARK: - Flick Detection

    private func detectFlick(spikeDeviation: Double, now: Date, cooldownOk: Bool) {
        if isInFlickSpike {
            if spikeDeviation < flickSpikeThreshold * 0.5 {
                if let startTime = flickStartTime {
                    let duration = now.timeIntervalSince(startTime)
                    if duration >= flickMinDuration && duration <= flickMaxDuration {
                        fireGesture(.flick, at: now)
                    }
                }
                isInFlickSpike = false
                flickStartTime = nil
            }
        } else if cooldownOk && spikeDeviation > flickSpikeThreshold {
            isInFlickSpike = true
            flickStartTime = now
        }
    }

    // MARK: - Tilt-and-Hold Detection

    private func detectTilt(tiltAngle: Double, now: Date, cooldownOk: Bool) {
        if tiltAngle >= tiltAngleThreshold {
            if !isInTilt {
                isInTilt = true
                tiltStartTime = now
                tiltFired = false
            } else if !tiltFired, let startTime = tiltStartTime {
                let elapsed = now.timeIntervalSince(startTime)
                if elapsed >= tiltHoldDuration && cooldownOk {
                    fireGesture(.tiltHold, at: now)
                    tiltFired = true
                }
            }
        } else {
            isInTilt = false
            tiltStartTime = nil
            tiltFired = false
        }
    }

    // MARK: - Clench Detection

    /// Clench detection uses the variance of the acceleration magnitude
    /// over a sliding window. When you clench your fist, isometric muscle
    /// contraction in the forearm causes micro-tremors that raise the
    /// high-frequency noise floor of the accelerometer. This manifests
    /// as increased variance in the magnitude signal.
    private func detectClench(variance: Double, now: Date, cooldownOk: Bool) {
        let elevatedVariance = variance > (restingVariance + clenchVarianceThreshold)

        if elevatedVariance {
            clenchConfirmationCount += 1

            // Require several consecutive elevated samples before we consider
            // this a real clench onset (filters out brief settling bumps)
            if clenchConfirmationCount >= clenchConfirmationRequired {
                if !isInClench {
                    isInClench = true
                    clenchStartTime = now
                    clenchFired = false
                } else if !clenchFired, let startTime = clenchStartTime {
                    let elapsed = now.timeIntervalSince(startTime)
                    if elapsed >= clenchHoldDuration && cooldownOk {
                        fireGesture(.clench, at: now)
                        clenchFired = true
                    }
                }
            }
        } else {
            clenchConfirmationCount = 0
            isInClench = false
            clenchStartTime = nil
            clenchFired = false
        }
    }

    // MARK: - Rotation Detection

    /// Wrist rotation (pronation/supination) detection. Tracks the gravity
    /// vector's angle in the x-z plane. When you rotate your wrist like
    /// turning a doorknob, x and z gravity components swap.
    ///
    /// Detection flow:
    /// 1. Rotation angle exceeds threshold → start tracking
    /// 2. Angle reaches peak (user is at maximum rotation)
    /// 3. Angle returns near starting position → fire gesture
    ///
    /// This is on a completely different signal domain from flick (magnitude
    /// spike) or clench (variance), so cross-triggering is impossible.
    private func detectRotation(rotationAngle: Double, now: Date, cooldownOk: Bool) {
        let absAngle = abs(rotationAngle)

        if isInRotation {
            // Track peak rotation
            if absAngle > rotationPeakAngle {
                rotationPeakAngle = absAngle
            }

            // Check if rotation exceeded threshold at some point
            if rotationPeakAngle >= rotationAngleThreshold {
                rotationReachedThreshold = true
            }

            // Check for return to near-starting position
            if rotationReachedThreshold && absAngle < rotationReturnThreshold {
                if let startTime = rotationStartTime {
                    let duration = now.timeIntervalSince(startTime)
                    if duration >= rotationMinDuration && duration <= rotationMaxDuration && cooldownOk {
                        fireGesture(.rotation, at: now)
                    }
                }
                // Reset rotation state regardless
                isInRotation = false
                rotationStartTime = nil
                rotationReachedThreshold = false
                rotationPeakAngle = 0
                rotationFired = false
            }

            // Timeout: if rotation takes too long, cancel
            if let startTime = rotationStartTime {
                if now.timeIntervalSince(startTime) > rotationMaxDuration {
                    isInRotation = false
                    rotationStartTime = nil
                    rotationReachedThreshold = false
                    rotationPeakAngle = 0
                }
            }
        } else if cooldownOk && absAngle > rotationReturnThreshold {
            // Rotation starting — angle has moved beyond the noise floor
            print("[GESTURE] Rotation STARTED at \(String(format: "%.1f", absAngle))°")
            isInRotation = true
            rotationStartTime = now
            rotationStartAngle = rotationAngle
            rotationPeakAngle = absAngle
            rotationReachedThreshold = false
            rotationFired = false
        }
    }

    // MARK: - ML-Based Detection

    /// Personal ML mode uses adaptive thresholds learned from calibration.
    ///
    /// The approach combines ML-learned parameters with temporal detection:
    /// - Flick detection uses personalized spike thresholds + duration limits
    /// - Clench detection uses personalized variance thresholds + hold duration
    /// - When a gesture triggers, we also extract features and run the classifier
    ///   to confirm the gesture type, providing a confidence score.
    ///
    /// This gives us the reliability of temporal detection (which captures the
    /// fundamental physical difference between flick and clench) combined with
    /// ML-based personalization and confirmation.
    private func processMLDetection(
        spikeDeviation: Double,
        now: Date,
        cooldownOk: Bool,
        classifier: PersonalGestureClassifier
    ) {
        guard cooldownOk else {
            debugState = "Cooldown"
            return
        }

        // Need enough data in the window
        guard slidingWindow.count >= 20 else {
            debugState = "Buffering..."
            return
        }

        // Use ML-learned adaptive thresholds if available
        if let thresholds = classifier.adaptiveThresholds {
            processAdaptiveDetection(
                spikeDeviation: spikeDeviation,
                now: now,
                thresholds: thresholds,
                classifier: classifier
            )
            return
        }

        // Fallback: pure snapshot classification (legacy behavior)
        if spikeDeviation > flickSpikeThreshold * 0.6 {
            let features = featureExtractor.extractFeatures(from: slidingWindow)

            if let result = classifier.classify(features) {
                let gesture = labelToGesture(result.predictedLabel)
                debugState = "\(result.predictedLabel) \(Int(result.confidence * 100))%"
                fireGesture(gesture, at: now)
                slidingWindow.removeAll()
            } else {
                debugState = "? (low conf)"
            }
        } else {
            debugState = "ML Ready"
            let mag = slidingWindow.last?.magnitude ?? 1.0
            baselineMagnitude = baselineMagnitude * (1 - baselineAlpha) + mag * baselineAlpha
        }
    }

    // MARK: - Adaptive ML Detection

    /// Detect gestures using ML-learned personal thresholds combined with
    /// temporal pattern detection and feature-based confirmation.
    ///
    /// KEY DESIGN: After any gesture fires, ALL detector states are reset
    /// and a cooldown blocks both detectors. This prevents the "return to
    /// rest" motion from triggering the opposite gesture (e.g., wrist
    /// settling after flick creating a variance bump that looks like clench).
    private func processAdaptiveDetection(
        spikeDeviation: Double,
        now: Date,
        thresholds: PersonalGestureClassifier.AdaptiveThresholds,
        classifier: PersonalGestureClassifier
    ) {
        let variance = currentVariance

        // --- COOLDOWN CHECK ---
        // After any gesture, enforce a settling period where BOTH detectors
        // are completely silent. This lets the wrist return to rest without
        // the settling motion being misread as the opposite gesture.
        let timeSinceLastGesture = now.timeIntervalSince(lastGestureTime)
        guard timeSinceLastGesture > cooldownInterval else {
            // During cooldown, keep updating baseline so we track the new resting state
            let mag = slidingWindow.last?.magnitude ?? 1.0
            baselineMagnitude = baselineMagnitude * (1 - baselineAlpha) + mag * baselineAlpha
            restingVariance = restingVariance * 0.995 + variance * 0.005
            debugState = String(format: "Settling %.1fs", cooldownInterval - timeSinceLastGesture)
            return
        }

        // --- Track rotation wind-up in adaptive mode too ---
        let absRotAngle = abs(currentRotationAngle)
        if !isInRotation && absRotAngle > rotationWindUpAngle {
            rotationWindUpCount += 1
            isRotationWindUp = rotationWindUpCount >= rotationWindUpRequired
        } else if !isInRotation {
            rotationWindUpCount = 0
            isRotationWindUp = false
        }

        // --- 1. ROTATION DETECTION (angular domain, HIGHEST PRIORITY) ---
        // Runs first so the initial wrist acceleration doesn't trigger flick.
        detectRotation(rotationAngle: currentRotationAngle, now: now, cooldownOk: true)

        // --- 2. ADAPTIVE FLICK DETECTION (suppressed during rotation) ---
        //
        // ENTRY threshold (personalFlickThreshold): starts spike tracking.
        // Kept at 0.28 so we don't miss the onset of real flicks.
        //
        // FIRE threshold (flickFireThreshold): the peak spike during the
        // window must reach this level to actually fire. Set at 0.32:
        // post-rotation settling peaks at 0.28-0.31, real flicks start
        // at 0.32+. The slow+rotated guard and rotation angle guard
        // handle false positives from rotation spillover.
        //
        // Two-threshold approach: low entry catches the flick onset, high
        // fire requirement filters noise that barely crosses entry.
        let personalFlickThreshold = max(thresholds.flickSpikeMin * 0.9, 0.28)
        let flickFireThreshold = max(thresholds.flickSpikeMin * 1.2, 0.32)
        if !hasLoggedThresholds {
            print("[GESTURE-ML] Adaptive thresholds: entry=\(String(format: "%.3f", personalFlickThreshold)) fire=\(String(format: "%.3f", flickFireThreshold)) (learned flickMin=\(String(format: "%.3f", thresholds.flickSpikeMin)))")
            hasLoggedThresholds = true
        }

        if isInRotation || isRotationWindUp {
            // Cancel any in-progress flick spike during rotation
            if isInFlickSpike {
                print("[GESTURE-ML] Flick CANCELLED by rotation (inRot=\(isInRotation) windUp=\(isRotationWindUp) angle=\(String(format: "%.1f", absRotAngle))° windUpCount=\(rotationWindUpCount))")
            }
            isInFlickSpike = false
            flickStartTime = nil
            flickPeakSpike = 0
        } else if isInFlickSpike {
            // Track the peak spike value during this flick window
            if spikeDeviation > flickPeakSpike {
                flickPeakSpike = spikeDeviation
            }

            if spikeDeviation < personalFlickThreshold * 0.5 {
                // Spike ended, check duration and peak strength
                if let startTime = flickStartTime {
                    let duration = now.timeIntervalSince(startTime)
                    let maxDur = min(thresholds.flickDurationMax * 1.5, 0.5)

                    // Guard 1: duration in valid range
                    // Guard 2: peak spike reached the FIRE threshold
                    // Guard 3: rotation angle below 18° at fire time
                    // Guard 4: combined duration+angle check. If the spike is
                    //   slow (>0.18s) AND has large angular displacement (>12°),
                    //   it's likely a rotation onset. Relaxed from dur>0.12/angle>8
                    //   because real flicks can take 0.14-0.16s and produce up to
                    //   ~10° of transient angular displacement from the wrist snap.
                    let rotAngleAtFire = abs(currentRotationAngle)
                    let isSlowWithRotation = duration > 0.18 && rotAngleAtFire > 12.0
                    if duration >= flickMinDuration && duration <= maxDur
                        && flickPeakSpike >= flickFireThreshold
                        && rotAngleAtFire < 18.0
                        && !isSlowWithRotation {
                        print("[GESTURE-ML] Flick FIRED: dur=\(String(format: "%.3f", duration))s peakSpike=\(String(format: "%.3f", flickPeakSpike)) rotAngle=\(String(format: "%.1f", rotAngleAtFire))°")
                        fireGesture(.flick, at: now)
                        debugState = "Flick (temporal)"
                    } else if flickPeakSpike < flickFireThreshold {
                        print("[GESTURE-ML] Flick REJECTED: peakSpike \(String(format: "%.3f", flickPeakSpike)) < fire threshold \(String(format: "%.3f", flickFireThreshold))")
                    } else if rotAngleAtFire >= 18.0 {
                        print("[GESTURE-ML] Flick REJECTED: rotAngle \(String(format: "%.1f", rotAngleAtFire))° >= 18° (likely rotation)")
                    } else if isSlowWithRotation {
                        print("[GESTURE-ML] Flick REJECTED: slow+rotated dur=\(String(format: "%.3f", duration))s rotAngle=\(String(format: "%.1f", rotAngleAtFire))° (likely rotation onset)")
                    }
                }
                isInFlickSpike = false
                flickStartTime = nil
                flickPeakSpike = 0
            }
        } else if spikeDeviation > personalFlickThreshold {
            // Only start flick detection if variance is low (not during a clench)
            if variance < thresholds.flickVsClenchVarBoundary * 1.5 {
                isInFlickSpike = true
                flickStartTime = now
                flickPeakSpike = spikeDeviation
            }
        }

        // --- 3. ADAPTIVE CLENCH DETECTION (lower priority) ---
        // Only run clench detection if "clench" was actually trained.
        // When the user trains flick+rotation, clench detection just
        // creates false fires from normal wrist movement variance.
        let clenchTrained = classifier.trainedLabels.contains("clench")
        if clenchTrained && !isInFlickSpike && !isInRotation && !isRotationWindUp {
            let personalClenchVarThreshold = thresholds.clenchVarianceMin
            let elevatedVariance = variance > (restingVariance + personalClenchVarThreshold)

            if elevatedVariance {
                clenchConfirmationCount += 1

                guard clenchConfirmationCount >= clenchConfirmationRequired else {
                    return
                }

                if !isInClench {
                    isInClench = true
                    clenchStartTime = now
                    clenchFired = false
                } else if !clenchFired, let startTime = clenchStartTime {
                    let elapsed = now.timeIntervalSince(startTime)
                    if elapsed >= clenchHoldDuration {
                        let features = featureExtractor.extractFeatures(from: slidingWindow)
                        if let result = classifier.classify(features) {
                            let gesture = labelToGesture(result.predictedLabel)
                            debugState = "ML: \(result.predictedLabel) \(Int(result.confidence * 100))%"

                            if gesture == .clench || result.confidence < 0.75 {
                                fireGesture(.clench, at: now)
                            } else {
                                debugState = "Clench→ML:\(result.predictedLabel)"
                            }
                        } else {
                            fireGesture(.clench, at: now)
                            debugState = "Clench (temporal)"
                        }
                    }
                }
            } else {
                clenchConfirmationCount = 0
                isInClench = false
                clenchStartTime = nil
                clenchFired = false
            }
        }

        // Update baseline when idle — including resting gravity drift adaptation.
        // Gravity drift alpha is 0.02 (~2.5s to fully adapt at 50Hz). This is
        // faster than the previous 0.005 (~10s) because stale resting gravity
        // causes the rotation angle to hover at 15-17° at rest, triggering
        // false "Rotation STARTED" entries that suppress flick detection.
        // During active gestures the drift is paused, so fast adaptation
        // only tracks genuine posture changes when the wrist is idle.
        if !isInFlickSpike && !isInClench && !isInRotation && !isRotationWindUp {
            let mag = slidingWindow.last?.magnitude ?? 1.0
            baselineMagnitude = baselineMagnitude * (1 - baselineAlpha) + mag * baselineAlpha
            restingVariance = restingVariance * 0.97 + variance * 0.03
            let gravDriftAlpha = 0.02
            restingGravity.x = restingGravity.x * (1 - gravDriftAlpha) + gravityEstimate.x * gravDriftAlpha
            restingGravity.y = restingGravity.y * (1 - gravDriftAlpha) + gravityEstimate.y * gravDriftAlpha
            restingGravity.z = restingGravity.z * (1 - gravDriftAlpha) + gravityEstimate.z * gravDriftAlpha
        }

        // Debug state
        if !isInFlickSpike && !isInClench && !clenchFired {
            debugState = "ML Adaptive"
        } else if isInClench && !clenchFired {
            let elapsed = clenchStartTime.map { now.timeIntervalSince($0) } ?? 0
            debugState = String(format: "Clench? %.1fs", elapsed)
        }
    }

    /// Map a calibration label string to a DetectedGesture enum value.
    private func labelToGesture(_ label: String) -> DetectedGesture {
        switch label.lowercased() {
        case "flick":    return .flick
        case "rotation": return .rotation
        case "pinch":    return .flick    // legacy
        case "clench":   return .clench   // legacy
        default:         return .flick
        }
    }

    // MARK: - Gesture Emission

    private func fireGesture(_ gesture: DetectedGesture, at time: Date) {
        print("[GESTURE] *** FIRED: \(gesture.rawValue) *** | rotAngle=\(String(format: "%.1f", currentRotationAngle))° spike=\(String(format: "%.3f", currentMagnitude - baselineMagnitude)) var=\(String(format: "%.5f", currentVariance)) mode=\(detectionMode.rawValue)")
        lastGesture = gesture
        lastGestureTime = time
        onGesture?(gesture)

        // IMPORTANT: Only reset the FIRED gesture's domain + unrelated detectors.
        // Flick (magnitude domain) and rotation (angular domain) are independent.
        // Resetting rotation state when flick fires creates a vicious cycle where
        // false flicks prevent rotation from ever establishing.

        // Always reset: flick, tilt, clench
        isInFlickSpike = false
        flickStartTime = nil
        flickPeakSpike = 0
        isInClench = false
        clenchStartTime = nil
        clenchFired = false
        clenchConfirmationCount = 0
        isInTilt = false
        tiltStartTime = nil
        tiltFired = false
        magnitudeWindow.removeAll()
        // Don't clear slidingWindow — ML needs continuous data for classification.
        // The cooldown period prevents re-firing anyway.

        // Only reset rotation state when rotation itself fires.
        // When flick fires, rotation tracking must survive so it can
        // still detect the in-progress rotation.
        if gesture == .rotation || gesture == .tiltHold {
            isInRotation = false
            isRotationWindUp = false
            rotationWindUpCount = 0
            rotationStartTime = nil
            rotationReachedThreshold = false
            rotationPeakAngle = 0
            rotationFired = false
        }
    }

    // MARK: - Helpers

    private func angleBetweenVectors(
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

    /// Compute the rotation angle of the gravity vector projected onto the x-z
    /// plane. This captures pronation/supination (wrist rotation around the
    /// forearm axis) while ignoring flexion/extension (wrist up/down).
    ///
    /// Returns the angle difference in degrees. Positive = clockwise rotation
    /// (supination), negative = counter-clockwise (pronation).
    private func xzPlaneAngle(
        from a: (x: Double, y: Double, z: Double),
        to b: (x: Double, y: Double, z: Double)
    ) -> Double {
        let angleA = atan2(a.z, a.x)
        let angleB = atan2(b.z, b.x)
        var diff = (angleB - angleA) * 180.0 / .pi

        // Normalize to [-180, 180]
        while diff > 180 { diff -= 360 }
        while diff < -180 { diff += 360 }

        return diff
    }

    private func computeVariance(_ values: [Double]) -> Double {
        guard values.count > 1 else { return 0 }
        let mean = values.reduce(0, +) / Double(values.count)
        let sumSquaredDiffs = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
        return sumSquaredDiffs / Double(values.count - 1)
    }

    private func resetAllState() {
        isInFlickSpike = false
        flickStartTime = nil
        flickPeakSpike = 0
        isInTilt = false
        tiltStartTime = nil
        tiltFired = false
        isInClench = false
        clenchStartTime = nil
        clenchFired = false
        clenchConfirmationCount = 0
        isInRotation = false
        isRotationWindUp = false
        rotationWindUpCount = 0
        rotationStartTime = nil
        rotationReachedThreshold = false
        rotationPeakAngle = 0
        rotationFired = false
        magnitudeWindow.removeAll()
    }

    // MARK: - Test Support

    /// Reset all state for a fresh test capture (used by calibration test screen).
    func resetForTest() {
        resetAllState()
        lastGestureTime = .distantPast
        slidingWindow.removeAll()
        debugState = "Ready"
    }

    // MARK: - Calibration

    func calibrateBaseline() {
        baselineMagnitude = currentMagnitude > 0 ? currentMagnitude : 1.0
        restingGravity = gravityEstimate
        restingVariance = currentVariance > 0 ? currentVariance : 0.001
        hasCalibrated = true
        debugState = "Calibrated"
    }

    // MARK: - Sensitivity Presets

    enum Sensitivity: String, CaseIterable {
        case high   = "High"
        case normal = "Normal"
        case low    = "Low"
    }

    func applySensitivity(_ level: Sensitivity) {
        switch level {
        case .high:
            flickSpikeThreshold = 0.2
            flickMinDuration = 0.02
            tiltAngleThreshold = 10.0
            tiltHoldDuration = 0.4
            clenchVarianceThreshold = 0.003
            clenchHoldDuration = 0.5
            cooldownInterval = 0.7
        case .normal:
            flickSpikeThreshold = 0.35
            flickMinDuration = 0.03
            tiltAngleThreshold = 15.0
            tiltHoldDuration = 0.5
            clenchVarianceThreshold = 0.005
            clenchHoldDuration = 0.7
            cooldownInterval = 1.0
        case .low:
            flickSpikeThreshold = 0.55
            flickMinDuration = 0.05
            tiltAngleThreshold = 25.0
            tiltHoldDuration = 0.6
            clenchVarianceThreshold = 0.01
            clenchHoldDuration = 0.8
            cooldownInterval = 1.2
        }
    }

    deinit {
        stop()
    }
}
