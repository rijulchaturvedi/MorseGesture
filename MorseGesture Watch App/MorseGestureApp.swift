import SwiftUI

@main
struct MorseGestureApp: App {
    @StateObject private var decoder = MorseDecoder()
    @StateObject private var inputManager = GestureInputManager()
    @StateObject private var haptics = HapticFeedbackManager()
    @StateObject private var speech = SpeechEngine()
    @StateObject private var shortcuts = PredictiveShortcuts()
    @StateObject private var accelDetector = AccelerometerGestureDetector()
    @StateObject private var accessibilityHandler = AccessibilityGestureHandler()
    @StateObject private var personalClassifier = PersonalGestureClassifier()

    @AppStorage("MorseGesture.onboardingComplete") private var onboardingComplete = false
    @AppStorage("MorseGesture.calibrationComplete") private var calibrationComplete = false

    var body: some Scene {
        WindowGroup {
            Group {
                if !onboardingComplete {
                    OnboardingView(isOnboardingComplete: $onboardingComplete)
                } else if !calibrationComplete {
                    GestureCalibrationView { trainedClassifier in
                        // Copy trained profiles into our shared classifier
                        trainedClassifier.profiles.forEach { _ in }
                        // Re-train our shared instance from the same data
                        accelDetector.personalClassifier = trainedClassifier
                        accelDetector.detectionMode = .personal
                        calibrationComplete = true
                    }
                } else {
                    ContentView()
                }
            }
            .environmentObject(decoder)
            .environmentObject(inputManager)
            .environmentObject(haptics)
            .environmentObject(speech)
            .environmentObject(shortcuts)
            .environmentObject(accelDetector)
            .environmentObject(accessibilityHandler)
            .environmentObject(personalClassifier)
            .onAppear {
                inputManager.configure(
                    decoder: decoder,
                    haptics: haptics,
                    shortcuts: shortcuts,
                    accelDetector: accelDetector,
                    accessibilityHandler: accessibilityHandler
                )

                // If calibration was previously done, load the saved classifier
                if calibrationComplete && personalClassifier.isReady {
                    accelDetector.personalClassifier = personalClassifier
                    accelDetector.detectionMode = .personal
                }

                // Start accelerometer for hybrid/accelerometer modes
                if inputManager.inputMode == .hybrid {
                    accelDetector.detectionMode = .clenchOnly
                    accelDetector.start()
                } else if inputManager.inputMode == .accelerometer {
                    accelDetector.start()
                }
            }
        }
    }
}
