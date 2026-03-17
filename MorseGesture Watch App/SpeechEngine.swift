import AVFoundation
import Combine
import Foundation

/// Wraps AVSpeechSynthesizer for text-to-speech output on watchOS.
///
/// Configurable rate, pitch, and volume so users can tune output
/// to their preference. Supports speaking the full decoded text
/// or just the most recently committed character.
final class SpeechEngine: ObservableObject {

    // MARK: - Published Settings

    /// Speech rate (0.0 to 1.0). Default is slightly slower than normal.
    @Published var rate: Float = 0.4

    /// Pitch multiplier (0.5 to 2.0). Default is normal.
    @Published var pitch: Float = 1.0

    /// Volume (0.0 to 1.0).
    @Published var volume: Float = 1.0

    /// Whether the engine is currently speaking.
    @Published private(set) var isSpeaking: Bool = false

    /// Voice identifier. Nil uses the system default.
    @Published var voiceIdentifier: String? = nil

    // MARK: - Private

    private let synthesizer = AVSpeechSynthesizer()
    private let delegateHandler = SpeechDelegateHandler()

    init() {
        synthesizer.delegate = delegateHandler
        delegateHandler.onFinish = { [weak self] in
            DispatchQueue.main.async {
                self?.isSpeaking = false
            }
        }
    }

    // MARK: - Public Methods

    /// Speak the given text.
    func speak(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        // Stop any current speech first
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }

        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = rate
        utterance.pitchMultiplier = pitch
        utterance.volume = volume

        if let id = voiceIdentifier, let voice = AVSpeechSynthesisVoice(identifier: id) {
            utterance.voice = voice
        } else {
            utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        }

        isSpeaking = true
        synthesizer.speak(utterance)
    }

    /// Speak a single character (useful for per-character feedback).
    func speakCharacter(_ char: Character) {
        // Use the NATO phonetic alphabet for single letters for clarity
        let phonetic = Self.natoAlphabet[char] ?? String(char)
        speak(phonetic)
    }

    /// Stop speaking immediately.
    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
    }

    // MARK: - NATO Phonetic Alphabet

    static let natoAlphabet: [Character: String] = [
        "A": "Alpha",   "B": "Bravo",    "C": "Charlie",  "D": "Delta",
        "E": "Echo",    "F": "Foxtrot",  "G": "Golf",     "H": "Hotel",
        "I": "India",   "J": "Juliet",   "K": "Kilo",     "L": "Lima",
        "M": "Mike",    "N": "November", "O": "Oscar",    "P": "Papa",
        "Q": "Quebec",  "R": "Romeo",    "S": "Sierra",   "T": "Tango",
        "U": "Uniform", "V": "Victor",   "W": "Whiskey",  "X": "X-ray",
        "Y": "Yankee",  "Z": "Zulu"
    ]
}

// MARK: - Delegate Handler

private class SpeechDelegateHandler: NSObject, AVSpeechSynthesizerDelegate {
    var onFinish: (() -> Void)?

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        onFinish?()
    }
}
