import SwiftUI

/// Interactive onboarding that teaches Morse input step by step.
///
/// Flow:
///   1. Welcome — what the app does
///   2. Learn Dot — practice tapping dot
///   3. Learn Dash — practice tapping dash
///   4. First Letter — spell "E" (one dot)
///   5. Second Letter — spell "T" (one dash)
///   6. Try a Word — spell "SOS" (... --- ...)
///   7. Timing — explain auto-commit and adjust speed
///   8. Ready — launch into the main app
struct OnboardingView: View {
    @EnvironmentObject var decoder: MorseDecoder
    @EnvironmentObject var inputManager: GestureInputManager
    @EnvironmentObject var haptics: HapticFeedbackManager

    @Binding var isOnboardingComplete: Bool

    @State private var step: OnboardingStep = .welcome
    @State private var practiceBuffer: String = ""
    @State private var practiceDecoded: String = ""
    @State private var showSuccess: Bool = false
    @State private var dotCount: Int = 0
    @State private var dashCount: Int = 0

    enum OnboardingStep: Int, CaseIterable {
        case welcome
        case learnDot
        case learnDash
        case firstLetter   // E = .
        case secondLetter  // T = -
        case tryWord       // SOS = ... --- ...
        case timing
        case ready
    }

    var body: some View {
        TabView(selection: $step) {
            welcomeView.tag(OnboardingStep.welcome)
            learnDotView.tag(OnboardingStep.learnDot)
            learnDashView.tag(OnboardingStep.learnDash)
            firstLetterView.tag(OnboardingStep.firstLetter)
            secondLetterView.tag(OnboardingStep.secondLetter)
            tryWordView.tag(OnboardingStep.tryWord)
            timingView.tag(OnboardingStep.timing)
            readyView.tag(OnboardingStep.ready)
        }
        .tabViewStyle(.verticalPage)
    }

    // MARK: - Step 1: Welcome

    private var welcomeView: some View {
        VStack(spacing: 8) {
            Text("MorseGesture")
                .font(.headline)
                .foregroundColor(.blue)

            Text("Communicate using Morse code with simple gestures.")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)

            Spacer().frame(height: 8)

            Text("Scroll down to start learning")
                .font(.caption2)
                .foregroundColor(.secondary)

            Image(systemName: "chevron.down")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
    }

    // MARK: - Step 2: Learn Dot

    private var learnDotView: some View {
        VStack(spacing: 8) {
            Text("This is a Dot")
                .font(.headline)

            Text("A short tap. In Morse code, a dot is the shorter signal.")
                .font(.caption2)
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)

            Spacer().frame(height: 4)

            Button {
                haptics.playDot()
                dotCount += 1
                if dotCount >= 3 {
                    showSuccess = true
                }
            } label: {
                VStack(spacing: 4) {
                    Circle()
                        .fill(Color.blue)
                        .frame(width: 30, height: 30)
                    Text("DOT")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.blue.opacity(0.15))
                )
            }
            .buttonStyle(.plain)

            Text("Tap it \(max(0, 3 - dotCount)) more time\(3 - dotCount == 1 ? "" : "s")")
                .font(.caption2)
                .foregroundColor(showSuccess ? .green : .orange)

            if showSuccess {
                Text("Great! Scroll down.")
                    .font(.caption2)
                    .foregroundColor(.green)
            }
        }
        .padding()
        .onAppear {
            dotCount = 0
            showSuccess = false
        }
    }

    // MARK: - Step 3: Learn Dash

    private var learnDashView: some View {
        VStack(spacing: 8) {
            Text("This is a Dash")
                .font(.headline)

            Text("A longer signal. On screen, tap the red zone. With gestures, you can tilt your wrist or clench.")
                .font(.caption2)
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)

            Spacer().frame(height: 4)

            Button {
                haptics.playDash()
                dashCount += 1
                if dashCount >= 3 {
                    showSuccess = true
                }
            } label: {
                VStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.red)
                        .frame(width: 44, height: 12)
                    Text("DASH")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.red.opacity(0.15))
                )
            }
            .buttonStyle(.plain)

            Text("Tap it \(max(0, 3 - dashCount)) more time\(3 - dashCount == 1 ? "" : "s")")
                .font(.caption2)
                .foregroundColor(showSuccess ? .green : .orange)

            if showSuccess {
                Text("Nice! Scroll down.")
                    .font(.caption2)
                    .foregroundColor(.green)
            }
        }
        .padding()
        .onAppear {
            dashCount = 0
            showSuccess = false
        }
    }

    // MARK: - Step 4: First Letter (E = .)

    private var firstLetterView: some View {
        VStack(spacing: 8) {
            Text("Your First Letter")
                .font(.headline)

            Text("The letter E is just one dot.")
                .font(.caption)
                .foregroundColor(.secondary)

            morseReference("E", code: ".")

            Spacer().frame(height: 4)

            practiceButtons

            Text("Buffer: \(practiceBuffer.isEmpty ? "-" : practiceBuffer)")
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.orange)

            if practiceDecoded.contains("E") {
                successBadge("You typed E!")
            } else {
                Text("Tap DOT once, then wait.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .onAppear { resetPractice() }
    }

    // MARK: - Step 5: Second Letter (T = -)

    private var secondLetterView: some View {
        VStack(spacing: 8) {
            Text("Next: Letter T")
                .font(.headline)

            Text("The letter T is just one dash.")
                .font(.caption)
                .foregroundColor(.secondary)

            morseReference("T", code: "-")

            Spacer().frame(height: 4)

            practiceButtons

            Text("Buffer: \(practiceBuffer.isEmpty ? "-" : practiceBuffer)")
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.orange)

            if practiceDecoded.contains("T") {
                successBadge("You typed T!")
            } else {
                Text("Tap DASH once, then wait.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .onAppear { resetPractice() }
    }

    // MARK: - Step 6: Try a Word (SOS)

    private var tryWordView: some View {
        VStack(spacing: 6) {
            Text("Try: SOS")
                .font(.headline)

            VStack(spacing: 2) {
                morseReference("S", code: "...")
                morseReference("O", code: "---")
                morseReference("S", code: "...")
            }

            Text("Wait between letters. The app auto-commits after \(inputManager.characterTimeout, specifier: "%.1f")s.")
                .font(.caption2)
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)

            Spacer().frame(height: 2)

            practiceButtons

            HStack(spacing: 4) {
                Text("Buffer:")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text(practiceBuffer.isEmpty ? "-" : practiceBuffer)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.orange)
            }

            Text(practiceDecoded.isEmpty ? " " : practiceDecoded)
                .font(.system(.body, design: .monospaced))
                .foregroundColor(.primary)
                .frame(height: 20)

            if practiceDecoded.uppercased().contains("SOS") {
                successBadge("SOS! Well done!")
            }
        }
        .padding(.horizontal, 4)
        .onAppear { resetPractice() }
    }

    // MARK: - Step 7: Timing

    private var timingView: some View {
        VStack(spacing: 8) {
            Text("Adjust Your Speed")
                .font(.headline)

            Text("The app waits before committing a character. Slower = more time to input dots and dashes.")
                .font(.caption2)
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)

            Spacer().frame(height: 4)

            VStack(alignment: .leading) {
                Text("Character delay: \(inputManager.characterTimeout, specifier: "%.1f")s")
                    .font(.caption)
                Slider(
                    value: $inputManager.characterTimeout,
                    in: 1.0...6.0,
                    step: 0.5
                )
            }

            VStack(alignment: .leading) {
                Text("Word space: \(inputManager.wordSpaceTimeout, specifier: "%.1f")s")
                    .font(.caption)
                Slider(
                    value: $inputManager.wordSpaceTimeout,
                    in: 2.0...10.0,
                    step: 0.5
                )
            }

            Text("You can change these anytime in Settings.")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding()
    }

    // MARK: - Step 8: Ready

    private var readyView: some View {
        ScrollView {
            VStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title2)
                    .foregroundColor(.green)

                Text("You're Ready!")
                    .font(.headline)

                Text("Common letters:")
                    .font(.caption2)
                    .foregroundColor(.secondary)

                VStack(alignment: .leading, spacing: 2) {
                    morseReference("E", code: ".")
                    morseReference("T", code: "-")
                    morseReference("A", code: ".-")
                    morseReference("I", code: "..")
                    morseReference("N", code: "-.")
                    morseReference("S", code: "...")
                }

                Button {
                    isOnboardingComplete = true
                    UserDefaults.standard.set(true, forKey: "MorseGesture.onboardingComplete")
                } label: {
                    Text("Start Communicating")
                        .font(.caption)
                        .bold()
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .padding(.top, 4)
            }
            .padding(.horizontal)
        }
    }

    // MARK: - Shared Components

    private var practiceButtons: some View {
        HStack(spacing: 8) {
            Button {
                practiceBuffer.append(".")
                haptics.playDot()
                schedulePracticeCommit()
            } label: {
                VStack(spacing: 2) {
                    Circle()
                        .fill(Color.blue)
                        .frame(width: 14, height: 14)
                    Text("DOT")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.blue.opacity(0.15))
                )
            }
            .buttonStyle(.plain)

            Button {
                practiceBuffer.append("-")
                haptics.playDash()
                schedulePracticeCommit()
            } label: {
                VStack(spacing: 2) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.red)
                        .frame(width: 22, height: 7)
                    Text("DASH")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.red.opacity(0.15))
                )
            }
            .buttonStyle(.plain)
        }
        .frame(height: 44)
    }

    private func morseReference(_ letter: String, code: String) -> some View {
        HStack(spacing: 6) {
            Text(letter)
                .font(.system(.caption, design: .monospaced))
                .bold()
                .frame(width: 16, alignment: .trailing)
            HStack(spacing: 3) {
                ForEach(Array(code.enumerated()), id: \.offset) { _, char in
                    if char == "." {
                        Circle()
                            .fill(Color.blue)
                            .frame(width: 8, height: 8)
                    } else {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(Color.red)
                            .frame(width: 18, height: 8)
                    }
                }
            }
            Text(code)
                .font(.system(.caption2, design: .monospaced))
                .foregroundColor(.secondary)
        }
    }

    private func successBadge(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .bold()
            .foregroundColor(.green)
    }

    // MARK: - Practice Timer

    @State private var practiceTimer: Timer? = nil

    private func schedulePracticeCommit() {
        practiceTimer?.invalidate()
        practiceTimer = Timer.scheduledTimer(
            withTimeInterval: inputManager.characterTimeout,
            repeats: false
        ) { _ in
            DispatchQueue.main.async {
                commitPracticeBuffer()
            }
        }
    }

    private func commitPracticeBuffer() {
        guard !practiceBuffer.isEmpty else { return }
        if let char = MorseDecoder.decodeTable[practiceBuffer] {
            practiceDecoded.append(char)
        } else {
            practiceDecoded.append(contentsOf: "[" + practiceBuffer + "]")
        }
        practiceBuffer = ""
        haptics.playCommit()
    }

    private func resetPractice() {
        practiceBuffer = ""
        practiceDecoded = ""
        practiceTimer?.invalidate()
        practiceTimer = nil
        showSuccess = false
    }
}
