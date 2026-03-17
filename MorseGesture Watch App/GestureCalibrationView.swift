import SwiftUI

/// Guided calibration flow that records the user's personal gesture patterns.
///
/// Steps:
///   1. Rest — capture baseline (wrist at rest for 3 seconds)
///   2. Flick — perform 20 wrist flick gestures with countdown prompts
///   3. Rotation — perform 20 wrist rotation gestures with countdown prompts
///   4. Training — classifier trains on collected data
///   5. Test — try a few gestures to verify the model works
///   6. Done — save and proceed
struct GestureCalibrationView: View {
    @EnvironmentObject var haptics: HapticFeedbackManager
    @StateObject private var recorder = GestureRecorder()
    @StateObject private var classifier = PersonalGestureClassifier()

    /// Called when calibration is complete. Parent view handles navigation.
    var onComplete: (PersonalGestureClassifier) -> Void

    @State private var phase: CalibrationPhase = .intro
    @State private var currentGestureIndex: Int = 0
    @State private var captureState: CaptureState = .waiting
    @State private var countdownValue: Int = 3
    @State private var testResults: [String] = []
    @State private var trainError: String? = nil

    let samplesPerGesture = 20

    enum CalibrationPhase {
        case intro
        case restBaseline
        case recordFlick
        case recordRotation
        case training
        case testing
        case done
    }

    enum CaptureState {
        case waiting     // waiting for countdown
        case countdown   // 3-2-1 countdown before "go"
        case recording   // actively capturing gesture
        case cooldown    // brief pause between samples
    }

    var body: some View {
        VStack(spacing: 8) {
            switch phase {
            case .intro:       introView
            case .restBaseline: restView
            case .recordFlick:  recordView(gesture: "flick", label: "Wrist Flick", instruction: "Quickly snap your wrist (like flicking water off your hand), then relax.")
            case .recordRotation: recordView(gesture: "rotation", label: "Wrist Rotation", instruction: "Rotate your wrist outward like turning a doorknob, then rotate back. Slow and smooth.")
            case .training:     trainingView
            case .testing:      testingView
            case .done:         doneView
            }
        }
        .padding(.horizontal, 4)
    }

    // MARK: - Intro

    private var introView: some View {
        VStack(spacing: 8) {
            Image(systemName: "hand.raised.fingers.spread")
                .font(.largeTitle)
                .foregroundColor(.blue)

            Text("Gesture Calibration")
                .font(.headline)

            Text("The app will learn YOUR wrist flick and wrist rotation gestures. You'll do each gesture 20 times.")
                .font(.caption2)
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)

            Spacer().frame(height: 8)

            Button("Begin") {
                recorder.startListening()
                phase = .restBaseline
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    // MARK: - Rest Baseline

    private var restView: some View {
        VStack(spacing: 8) {
            Text("Step 1: Rest")
                .font(.headline)

            Text("Keep your wrist still and relaxed for a few seconds. This captures your resting baseline.")
                .font(.caption2)
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)

            Spacer().frame(height: 8)

            if countdownValue > 0 {
                Text("\(countdownValue)")
                    .font(.largeTitle)
                    .bold()
                    .foregroundColor(.orange)
                    .onAppear { startRestCountdown() }
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title)
                    .foregroundColor(.green)

                Text("Baseline captured!")
                    .font(.caption)
                    .foregroundColor(.green)

                Button("Next: Flick") {
                    currentGestureIndex = 0
                    captureState = .waiting
                    phase = .recordFlick
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
    }

    private func startRestCountdown() {
        countdownValue = 3
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { timer in
            DispatchQueue.main.async {
                countdownValue -= 1
                if countdownValue <= 0 {
                    timer.invalidate()
                    recorder.captureBaseline()
                    haptics.playCommit()
                }
            }
        }
    }

    // MARK: - Record Gestures

    private func recordView(gesture: String, label: String, instruction: String) -> some View {
        VStack(spacing: 6) {
            Text("Step \(gesture == "flick" ? "2" : "3"): \(label)")
                .font(.headline)

            // Progress
            Text("\(currentGestureIndex) / \(samplesPerGesture)")
                .font(.title3)
                .bold()
                .foregroundColor(.blue)

            progressBar

            switch captureState {
            case .waiting:
                VStack(spacing: 4) {
                    Text(instruction)
                        .font(.caption2)
                        .multilineTextAlignment(.center)
                        .foregroundColor(.secondary)

                    Button("Ready") {
                        startSampleCapture(gesture: gesture)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                }

            case .countdown:
                Text("\(countdownValue)")
                    .font(.largeTitle)
                    .bold()
                    .foregroundColor(.orange)

            case .recording:
                VStack(spacing: 4) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 24, height: 24)
                        .opacity(pulseOpacity)

                    Text("DO IT NOW")
                        .font(.caption)
                        .bold()
                        .foregroundColor(.red)
                }

            case .cooldown:
                Image(systemName: "checkmark")
                    .font(.title2)
                    .foregroundColor(.green)
            }

            if currentGestureIndex >= samplesPerGesture {
                Button(gesture == "flick" ? "Next: Rotation" : "Train Model") {
                    if gesture == "flick" {
                        currentGestureIndex = 0
                        captureState = .waiting
                        phase = .recordRotation
                    } else {
                        phase = .training
                        trainModel()
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
            }
        }
        .padding(.horizontal, 4)
    }

    @State private var pulseOpacity: Double = 1.0

    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.gray.opacity(0.3))
                    .frame(height: 6)

                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.blue)
                    .frame(
                        width: geo.size.width * CGFloat(currentGestureIndex) / CGFloat(samplesPerGesture),
                        height: 6
                    )
            }
        }
        .frame(height: 6)
    }

    private func startSampleCapture(gesture: String) {
        // 3-2-1 countdown
        captureState = .countdown
        countdownValue = 3

        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { timer in
            DispatchQueue.main.async {
                countdownValue -= 1
                haptics.playDot()

                if countdownValue <= 0 {
                    timer.invalidate()
                    // Start recording
                    captureState = .recording
                    recorder.beginCapture()
                    haptics.playDash()

                    // Pulse animation
                    withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) {
                        pulseOpacity = 0.3
                    }

                    // Auto-end after 1.5 seconds
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        endSampleCapture(gesture: gesture)
                    }
                }
            }
        }
    }

    private func endSampleCapture(gesture: String) {
        pulseOpacity = 1.0

        let sample = recorder.endCapture(label: gesture)

        if sample != nil {
            currentGestureIndex += 1
            haptics.playCommit()
        } else {
            haptics.playError()
        }

        // Brief cooldown, then ready for next
        captureState = .cooldown
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            if currentGestureIndex < samplesPerGesture {
                // Auto-start next sample (no need to tap Ready each time after the first)
                startSampleCapture(gesture: gesture)
            } else {
                captureState = .waiting
            }
        }
    }

    // MARK: - Training

    private var trainingView: some View {
        VStack(spacing: 8) {
            if trainError == nil {
                ProgressView()
                    .scaleEffect(1.5)

                Text("Training your model...")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title)
                    .foregroundColor(.orange)

                Text(trainError!)
                    .font(.caption)
                    .foregroundColor(.orange)
                    .multilineTextAlignment(.center)

                Button("Try Again") {
                    currentGestureIndex = 0
                    captureState = .waiting
                    recorder.reset()
                    phase = .recordFlick
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
    }

    private func trainModel() {
        trainError = nil

        // Small delay so the ProgressView renders
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let success = classifier.train(
                from: recorder.allSamples,
                minSamplesPerClass: 10
            )

            if success {
                haptics.playShortcutExpansion()
                phase = .testing
                recorder.captureBaseline()
            } else {
                trainError = "Not enough clean samples. Let's try recording again."
            }
        }
    }

    // MARK: - Testing

    private var testingView: some View {
        VStack(spacing: 6) {
            Text("Test Your Model")
                .font(.headline)

            Text("Try a few gestures to make sure it works. Tap 'Capture', do the gesture, see if it's recognized correctly.")
                .font(.caption2)
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)

            // Recent test results
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(Array(testResults.enumerated()), id: \.offset) { _, result in
                        Text(result)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundColor(result.contains("?") ? .orange : .green)
                    }
                }
            }
            .frame(height: 40)

            HStack(spacing: 8) {
                Button("Capture") {
                    runTestCapture()
                }
                .buttonStyle(.bordered)
                .tint(.blue)
                .disabled(captureState == .recording)

                Button("Done") {
                    phase = .done
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
            }

            if captureState == .recording {
                Text("DO THE GESTURE NOW")
                    .font(.caption)
                    .bold()
                    .foregroundColor(.red)
            }
        }
        .padding(.horizontal, 4)
    }

    private func runTestCapture() {
        captureState = .recording
        recorder.beginCapture()
        haptics.playDash()

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            // End capture without a label (test only)
            let features = recorder.endCapture(label: "test")?.features

            captureState = .waiting

            if let features = features,
               let result = classifier.classify(features) {
                testResults.append("\(result.predictedLabel) (\(Int(result.confidence * 100))%)")
                haptics.playCommit()
            } else {
                testResults.append("? (not recognized)")
                haptics.playError()
            }

            // Keep only last 5 results
            if testResults.count > 5 {
                testResults.removeFirst()
            }
        }
    }

    // MARK: - Done

    private var doneView: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.seal.fill")
                .font(.largeTitle)
                .foregroundColor(.green)

            Text("Calibration Complete!")
                .font(.headline)

            VStack(alignment: .leading, spacing: 2) {
                ForEach(classifier.profiles, id: \.label) { profile in
                    HStack {
                        Text(profile.label.capitalized)
                            .font(.caption)
                        Spacer()
                        Text("\(profile.sampleCount) samples")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(.horizontal)

            Spacer().frame(height: 6)

            Button("Start Using Gestures") {
                recorder.stopListening()
                onComplete(classifier)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
        }
        .padding()
    }
}
