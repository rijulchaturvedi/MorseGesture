import SwiftUI

struct ContentView: View {
    @EnvironmentObject var decoder: MorseDecoder
    @EnvironmentObject var inputManager: GestureInputManager
    @EnvironmentObject var haptics: HapticFeedbackManager
    @EnvironmentObject var speech: SpeechEngine
    @EnvironmentObject var shortcuts: PredictiveShortcuts
    @EnvironmentObject var accelDetector: AccelerometerGestureDetector
    @EnvironmentObject var accessibilityHandler: AccessibilityGestureHandler

    @State private var showShortcuts = false
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 6) {
                // Decoded text display
                textDisplay

                // Live preview of current buffer
                bufferPreview

                // Dot / Dash input zones
                inputButtons

                // Action bar: speak, delete, space, clear
                actionBar
            }
            .padding(.horizontal, 4)
            .padding(.top, 6)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showShortcuts = true
                    } label: {
                        Image(systemName: "list.bullet")
                            .font(.caption2)
                    }
                    .accessibilityLabel("Shortcuts")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gear")
                            .font(.caption2)
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .sheet(isPresented: $showShortcuts) {
                shortcutsSheet
            }
            .sheet(isPresented: $showSettings) {
                settingsSheet
            }
        }
    }

    // MARK: - Text Display

    private var textDisplay: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                Text(decoder.decodedText.isEmpty ? "Tap to begin" : decoder.decodedText)
                    .font(.body)
                    .foregroundColor(decoder.decodedText.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 2)
                    .id("text")
            }
            .frame(height: 36)
            .onChange(of: decoder.decodedText) { _ in
                proxy.scrollTo("text", anchor: .bottom)
            }
        }
    }

    // MARK: - Buffer Preview

    private var bufferPreview: some View {
        HStack(spacing: 4) {
            // Show the raw Morse buffer
            Text(decoder.currentBuffer.isEmpty ? " " : decoder.currentBuffer)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.orange)

            if !decoder.livePreview.isEmpty {
                Text("→")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text(decoder.livePreview)
                    .font(.caption)
                    .foregroundColor(.green)
                    .bold()
            }
        }
        .frame(height: 16)
    }

    // MARK: - Input Buttons

    private var inputButtons: some View {
        HStack(spacing: 8) {
            // DOT zone (left) — responds to Double Tap (pinch) via handGestureShortcut
            Button {
                inputManager.handleDot()
            } label: {
                VStack(spacing: 2) {
                    Circle()
                        .fill(Color.blue)
                        .frame(width: 16, height: 16)
                    Text("DOT")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.blue.opacity(0.15))
                )
            }
            .buttonStyle(.plain)
            .handGestureShortcut(.primaryAction)
            .accessibilityLabel("Dot")
            .accessibilityHint("Double tap pinch gesture. Adds a dot to the current Morse character.")

            // DASH zone (right)
            Button {
                inputManager.handleDash()
            } label: {
                VStack(spacing: 2) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.red)
                        .frame(width: 28, height: 8)
                    Text("DASH")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.red.opacity(0.15))
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dash")
            .accessibilityHint("Clench gesture. Adds a dash to the current Morse character.")
        }
        .frame(height: 56)
    }

    // MARK: - Action Bar

    private var actionBar: some View {
        HStack(spacing: 6) {
            // Speak
            Button {
                speech.speak(decoder.decodedText)
            } label: {
                Image(systemName: speech.isSpeaking ? "speaker.wave.3.fill" : "speaker.wave.2")
                    .font(.caption)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.green)
            .disabled(decoder.decodedText.isEmpty)
            .accessibilityLabel("Speak decoded text")

            // Delete
            Button {
                inputManager.handleDelete()
                haptics.playDelete()
            } label: {
                Image(systemName: "delete.left")
                    .font(.caption)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.orange)
            .accessibilityLabel("Delete last")

            // Space
            Button {
                inputManager.manualWordSpace()
            } label: {
                Image(systemName: "space")
                    .font(.caption)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Insert space")

            // Clear all
            Button {
                decoder.reset()
            } label: {
                Image(systemName: "xmark.circle")
                    .font(.caption)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.red)
            .disabled(decoder.decodedText.isEmpty && decoder.currentBuffer.isEmpty)
            .accessibilityLabel("Clear all text")
        }
    }

    // MARK: - Shortcuts Sheet

    private var shortcutsSheet: some View {
        NavigationStack {
            List {
                ForEach(PredictiveShortcuts.Shortcut.Category.allCases, id: \.self) { category in
                    let filtered = shortcuts.activeShortcuts.filter { $0.category == category }
                    if !filtered.isEmpty {
                        Section(category.rawValue.capitalized) {
                            ForEach(filtered) { shortcut in
                                HStack {
                                    Text(shortcut.code)
                                        .font(.system(.body, design: .monospaced))
                                        .foregroundColor(.orange)
                                        .frame(width: 40, alignment: .leading)
                                    Text("→")
                                        .foregroundColor(.secondary)
                                    Text(shortcut.expansion)
                                        .font(.caption)
                                        .lineLimit(2)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Shortcuts")
        }
    }

    // MARK: - Settings Sheet

    private var settingsSheet: some View {
        NavigationStack {
            List {
                Section("Input Mode") {
                    Picker("Mode", selection: $inputManager.inputMode) {
                        ForEach(GestureInputManager.InputMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .font(.caption)
                    .onChange(of: inputManager.inputMode) { newMode in
                        inputManager.setInputMode(newMode)
                    }

                    if inputManager.inputMode == .hybrid {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Dot: Apple Double Tap (pinch)")
                                .font(.caption2)
                                .foregroundColor(.blue)
                            Text("Dash: Accelerometer clench")
                                .font(.caption2)
                                .foregroundColor(.red)
                            HStack {
                                Circle()
                                    .fill(accelDetector.isActive ? Color.green : Color.red)
                                    .frame(width: 8, height: 8)
                                Text(accelDetector.debugState)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }

                        Button("Calibrate Baseline") {
                            accelDetector.calibrateBaseline()
                        }
                        .font(.caption)
                        .foregroundColor(.blue)
                    }

                    if inputManager.inputMode == .accelerometer {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Circle()
                                    .fill(accelDetector.isActive ? Color.green : Color.red)
                                    .frame(width: 8, height: 8)
                                Text(accelDetector.debugState)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            Text("Accel: \(accelDetector.currentMagnitude, specifier: "%.2f")g")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundColor(.secondary)
                            Text("Tilt: \(accelDetector.currentTiltDegrees, specifier: "%.1f")°")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundColor(.secondary)
                            Text("Var: \(accelDetector.currentVariance, specifier: "%.4f")")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundColor(.secondary)
                        }

                        Picker("Sensitivity", selection: Binding(
                            get: { AccelerometerGestureDetector.Sensitivity.normal },
                            set: { accelDetector.applySensitivity($0) }
                        )) {
                            ForEach(AccelerometerGestureDetector.Sensitivity.allCases, id: \.self) { level in
                                Text(level.rawValue).tag(level)
                            }
                        }
                        .font(.caption)

                        Button("Calibrate Baseline") {
                            accelDetector.calibrateBaseline()
                        }
                        .font(.caption)
                        .foregroundColor(.blue)
                    }
                }

                if inputManager.inputMode == .accelerometer || inputManager.inputMode == .hybrid {
                    Section("Gesture Mapping") {
                        ForEach(AccelerometerGestureDetector.DetectedGesture.allCases, id: \.self) { gesture in
                            HStack {
                                Text(gesture.rawValue)
                                    .font(.caption)
                                    .frame(width: 70, alignment: .leading)
                                Spacer()
                                Picker("", selection: Binding(
                                    get: {
                                        inputManager.gestureMap[gesture] ?? .none
                                    },
                                    set: { newAction in
                                        inputManager.setMapping(gesture, to: newAction)
                                    }
                                )) {
                                    ForEach(GestureInputManager.MorseAction.allCases, id: \.self) { action in
                                        Text(action.rawValue).tag(action)
                                    }
                                }
                                .font(.caption)
                            }
                        }

                        Button("Reset to Defaults") {
                            inputManager.resetGestureMap()
                        }
                        .font(.caption)
                        .foregroundColor(.orange)
                    }
                }

                Section("Input Timing") {
                    VStack(alignment: .leading) {
                        Text("Char timeout: \(inputManager.characterTimeout, specifier: "%.1f")s")
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

                    Toggle("Auto-commit", isOn: $inputManager.autoCommitEnabled)
                        .font(.caption)
                }

                Section("Speech") {
                    VStack(alignment: .leading) {
                        Text("Rate: \(speech.rate, specifier: "%.1f")")
                            .font(.caption)
                        Slider(value: $speech.rate, in: 0.1...1.0, step: 0.1)
                    }

                    VStack(alignment: .leading) {
                        Text("Pitch: \(speech.pitch, specifier: "%.1f")")
                            .font(.caption)
                        Slider(value: $speech.pitch, in: 0.5...2.0, step: 0.1)
                    }
                }

                Section("Haptics") {
                    Toggle("Haptic feedback", isOn: $haptics.isEnabled)
                        .font(.caption)
                }

                Section {
                    Button("Reset Shortcuts") {
                        shortcuts.resetToDefaults()
                    }
                    .foregroundColor(.orange)

                    Button("Replay Tutorial") {
                        UserDefaults.standard.set(false, forKey: "MorseGesture.onboardingComplete")
                    }
                    .foregroundColor(.blue)

                    Button("Recalibrate Gestures") {
                        UserDefaults.standard.set(false, forKey: "MorseGesture.calibrationComplete")
                    }
                    .foregroundColor(.blue)

                    if accelDetector.detectionMode == .personal {
                        HStack {
                            Circle()
                                .fill(Color.green)
                                .frame(width: 8, height: 8)
                            Text("Personal ML active")
                                .font(.caption2)
                                .foregroundColor(.green)
                        }
                    }
                }

                Section {
                    VStack(spacing: 4) {
                        Text("MorseGesture")
                            .font(.caption)
                            .fontWeight(.semibold)
                        Text("Designed & Developed by")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                        Text("Rijul Chaturvedi")
                            .font(.caption2)
                            .fontWeight(.medium)
                            .foregroundColor(.blue)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle("Settings")
        }
    }
}

// MARK: - Preview

#Preview {
    ContentView()
        .environmentObject(MorseDecoder())
        .environmentObject(GestureInputManager())
        .environmentObject(HapticFeedbackManager())
        .environmentObject(SpeechEngine())
        .environmentObject(PredictiveShortcuts())
        .environmentObject(AccelerometerGestureDetector())
        .environmentObject(PersonalGestureClassifier())
        .environmentObject(AccessibilityGestureHandler())
}
