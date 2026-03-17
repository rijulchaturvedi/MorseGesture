import Foundation
import Combine

/// Manages input timing and gesture-to-action mapping for Morse code entry.
///
/// - After configurable seconds of inactivity, the current dot/dash buffer
///   is auto-committed as a character.
/// - After a longer gap, a word space is inserted.
/// - Detected gestures (flick, tilt, clench) are mapped to Morse actions
///   (dot, dash, commit, space, delete) via user-configurable bindings.
final class GestureInputManager: ObservableObject {

    // MARK: - Morse Actions

    /// The actions a gesture can be mapped to.
    enum MorseAction: String, CaseIterable, Codable {
        case dot       = "Dot"
        case dash      = "Dash"
        case commit    = "Commit"
        case space     = "Space"
        case delete    = "Delete"
        case none      = "None"
    }

    // MARK: - Configurable Timing

    @Published var characterTimeout: TimeInterval = 2.5
    @Published var wordSpaceTimeout: TimeInterval = 4.5
    @Published var autoCommitEnabled: Bool = true

    // MARK: - Input Mode

    enum InputMode: String, CaseIterable {
        case tap           = "Tap"
        case hybrid        = "Double Tap + Clench"
        case accelerometer = "Accelerometer"
        case assistive     = "AssistiveTouch"
    }

    @Published var inputMode: InputMode = .accelerometer

    // MARK: - Gesture Mapping

    /// User-configurable mapping from detected gestures to Morse actions.
    /// Persisted via UserDefaults.
    @Published var gestureMap: [AccelerometerGestureDetector.DetectedGesture: MorseAction] = [:] {
        didSet { saveGestureMap() }
    }

    private let gestureMapKey = "MorseGesture.gestureMap"

    /// Default mapping: flick = dot, rotation = dash.
    /// Flick and rotation are on completely different signal domains
    /// (magnitude spike vs. gravity vector rotation), eliminating
    /// cross-triggering.
    static let defaultGestureMap: [AccelerometerGestureDetector.DetectedGesture: MorseAction] = [
        .flick:    .dot,
        .rotation: .dash,
        .tiltHold: .dash,
        .clench:   .dash,
    ]

    // MARK: - Internal State

    @Published private(set) var lastInputTime: Date = .distantPast
    @Published private(set) var isIdle: Bool = true

    private weak var decoder: MorseDecoder?
    private weak var haptics: HapticFeedbackManager?
    private weak var shortcuts: PredictiveShortcuts?
    private var accelDetector: AccelerometerGestureDetector?
    private var accessibilityHandler: AccessibilityGestureHandler?

    private var characterTimer: Timer?
    private var wordSpaceTimer: Timer?

    // MARK: - Init

    init() {
        loadGestureMap()
    }

    // MARK: - Configuration

    func configure(
        decoder: MorseDecoder,
        haptics: HapticFeedbackManager,
        shortcuts: PredictiveShortcuts,
        accelDetector: AccelerometerGestureDetector? = nil,
        accessibilityHandler: AccessibilityGestureHandler? = nil
    ) {
        self.decoder = decoder
        self.haptics = haptics
        self.shortcuts = shortcuts
        self.accelDetector = accelDetector
        self.accessibilityHandler = accessibilityHandler

        // Wire accelerometer callbacks through the gesture map
        accelDetector?.onGesture = { [weak self] gesture in
            self?.executeGestureMapping(gesture)
        }

        // Wire accessibility gesture callbacks
        accessibilityHandler?.onAction = { [weak self] action in
            switch action {
            case .dot:             self?.handleDot()
            case .dash:            self?.handleDash()
            case .commitCharacter: self?.manualCommit()
            case .wordSpace:       self?.manualWordSpace()
            case .delete:          self?.handleDelete()
            case .speak:           break
            }
        }
    }

    // MARK: - Gesture Mapping Execution

    /// Look up the user's mapping for a detected gesture and execute it.
    private func executeGestureMapping(_ gesture: AccelerometerGestureDetector.DetectedGesture) {
        let action = gestureMap[gesture] ?? .none
        switch action {
        case .dot:    handleDot()
        case .dash:   handleDash()
        case .commit: manualCommit()
        case .space:  manualWordSpace()
        case .delete: handleDelete()
        case .none:   break
        }
    }

    /// Update the mapping for a specific gesture.
    func setMapping(_ gesture: AccelerometerGestureDetector.DetectedGesture, to action: MorseAction) {
        gestureMap[gesture] = action
    }

    /// Reset to default mappings.
    func resetGestureMap() {
        gestureMap = Self.defaultGestureMap
    }

    // MARK: - Persistence

    private func loadGestureMap() {
        guard let data = UserDefaults.standard.data(forKey: gestureMapKey),
              let saved = try? JSONDecoder().decode(
                  [AccelerometerGestureDetector.DetectedGesture: MorseAction].self,
                  from: data
              ) else {
            gestureMap = Self.defaultGestureMap
            return
        }
        gestureMap = saved
    }

    private func saveGestureMap() {
        if let data = try? JSONEncoder().encode(gestureMap) {
            UserDefaults.standard.set(data, forKey: gestureMapKey)
        }
    }

    // MARK: - Input Mode Switching

    func setInputMode(_ mode: InputMode) {
        accelDetector?.stop()
        inputMode = mode
        switch mode {
        case .tap:
            break
        case .hybrid:
            // In hybrid mode, accelerometer runs for clench detection only.
            // Dot comes from Apple's Double Tap (.handGestureShortcut).
            accelDetector?.detectionMode = .clenchOnly
            accelDetector?.start()
        case .accelerometer:
            accelDetector?.start()
        case .assistive:
            break
        }
    }

    // MARK: - Input Events

    func handleDot() {
        guard let decoder = decoder else { return }
        decoder.inputDot()
        haptics?.playDot()
        restartTimers()
        isIdle = false
        lastInputTime = Date()
    }

    func handleDash() {
        guard let decoder = decoder else { return }
        decoder.inputDash()
        haptics?.playDash()
        restartTimers()
        isIdle = false
        lastInputTime = Date()
    }

    func manualCommit() {
        guard let decoder = decoder else { return }
        cancelTimers()
        decoder.commitCharacter()
        checkShortcutExpansion()
        startWordSpaceTimer()
    }

    func manualWordSpace() {
        guard let decoder = decoder else { return }
        cancelTimers()
        decoder.commitWordSpace()
    }

    func handleDelete() {
        decoder?.deleteLast()
        restartTimers()
    }

    // MARK: - Timers

    private func restartTimers() {
        cancelTimers()
        guard autoCommitEnabled else { return }
        startCharacterTimer()
    }

    private func startCharacterTimer() {
        characterTimer = Timer.scheduledTimer(
            withTimeInterval: characterTimeout,
            repeats: false
        ) { [weak self] _ in
            DispatchQueue.main.async {
                self?.onCharacterTimeout()
            }
        }
    }

    private func startWordSpaceTimer() {
        wordSpaceTimer = Timer.scheduledTimer(
            withTimeInterval: wordSpaceTimeout - characterTimeout,
            repeats: false
        ) { [weak self] _ in
            DispatchQueue.main.async {
                self?.onWordSpaceTimeout()
            }
        }
    }

    private func cancelTimers() {
        characterTimer?.invalidate()
        characterTimer = nil
        wordSpaceTimer?.invalidate()
        wordSpaceTimer = nil
    }

    // MARK: - Timeout Handlers

    private func onCharacterTimeout() {
        guard let decoder = decoder else { return }
        guard !decoder.currentBuffer.isEmpty else { return }
        decoder.commitCharacter()
        haptics?.playCommit()
        checkShortcutExpansion()
        startWordSpaceTimer()
    }

    private func onWordSpaceTimeout() {
        guard let decoder = decoder else { return }
        decoder.commitWordSpace()
        isIdle = true
    }

    // MARK: - Shortcut Expansion

    private func checkShortcutExpansion() {
        guard let decoder = decoder,
              let shortcuts = shortcuts else { return }

        let text = decoder.decodedText.uppercased()

        for shortcut in shortcuts.activeShortcuts {
            let code = shortcut.code.uppercased()
            if text.hasSuffix(code) {
                let startIndex = text.index(text.endIndex, offsetBy: -code.count)
                let prefix = String(decoder.decodedText[decoder.decodedText.startIndex..<startIndex])
                let expanded = prefix + shortcut.expansion
                decoder.setDecodedText(expanded)
                haptics?.playShortcutExpansion()
                break
            }
        }
    }

    deinit {
        cancelTimers()
    }
}
