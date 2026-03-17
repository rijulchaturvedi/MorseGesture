import Foundation
import Combine

/// Core Morse code encoding/decoding engine.
/// Maintains a buffer of dots and dashes, commits characters,
/// and builds up decoded text.
final class MorseDecoder: ObservableObject {

    // MARK: - Published State

    /// The fully decoded text so far.
    @Published var decodedText: String = ""

    /// The current uncommitted Morse buffer (e.g. ".-" while typing 'A').
    @Published var currentBuffer: String = ""

    /// A live preview of what the current buffer would decode to.
    @Published var livePreview: String = ""

    // MARK: - Morse Tables

    /// International Morse Code: character -> dot/dash pattern.
    static let encodeTable: [Character: String] = [
        "A": ".-",    "B": "-...",  "C": "-.-.",  "D": "-..",
        "E": ".",      "F": "..-.",  "G": "--.",   "H": "....",
        "I": "..",     "J": ".---",  "K": "-.-",   "L": ".-..",
        "M": "--",     "N": "-.",    "O": "---",   "P": ".--.",
        "Q": "--.-",   "R": ".-.",   "S": "...",   "T": "-",
        "U": "..-",    "V": "...-",  "W": ".--",   "X": "-..-",
        "Y": "-.--",   "Z": "--..",
        "1": ".----",  "2": "..---", "3": "...--", "4": "....-",
        "5": ".....",  "6": "-....", "7": "--...", "8": "---..",
        "9": "----.",  "0": "-----",
        ".": ".-.-.-", ",": "--..--", "?": "..--..", "!": "-.-.--",
        "'": ".----.", "/": "-..-.",  "(": "-.--.",  ")": "-.--.-",
        "&": ".-...",  ":": "---...", ";": "-.-.-.", "=": "-...-",
        "+": ".-.-.",  "-": "-....-", "_": "..--.-", "\"": ".-..-.",
        "$": "...-..-","@": ".--.-."
    ]

    /// Reverse lookup: dot/dash pattern -> character.
    static let decodeTable: [String: Character] = {
        var table = [String: Character]()
        for (char, code) in encodeTable {
            table[code] = char
        }
        return table
    }()

    // MARK: - Input Methods

    /// Append a dot to the current buffer.
    func inputDot() {
        currentBuffer.append(".")
        updateLivePreview()
    }

    /// Append a dash to the current buffer.
    func inputDash() {
        currentBuffer.append("-")
        updateLivePreview()
    }

    /// Commit the current buffer as a decoded character.
    /// If the buffer matches a known Morse pattern, the character is appended
    /// to `decodedText`. Otherwise the raw buffer is appended as-is in brackets.
    @discardableResult
    func commitCharacter() -> Character? {
        guard !currentBuffer.isEmpty else { return nil }

        let decoded = Self.decodeTable[currentBuffer]
        if let char = decoded {
            decodedText.append(char)
        } else {
            // Unknown pattern: show raw Morse so the user can see what happened
            decodedText.append(contentsOf: "[" + currentBuffer + "]")
        }

        let committed = decoded
        currentBuffer = ""
        livePreview = ""
        return committed
    }

    /// Insert a word space into the decoded text.
    func commitWordSpace() {
        // Auto-commit any pending buffer first
        commitCharacter()
        // Avoid double spaces
        if !decodedText.isEmpty && !decodedText.hasSuffix(" ") {
            decodedText.append(" ")
        }
    }

    /// Replace the entire decoded text (used by shortcut expansion).
    func setDecodedText(_ text: String) {
        decodedText = text
    }

    /// Clear all state.
    func reset() {
        decodedText = ""
        currentBuffer = ""
        livePreview = ""
    }

    /// Delete the last character from decoded text (backspace).
    func deleteLast() {
        if !currentBuffer.isEmpty {
            currentBuffer.removeLast()
            updateLivePreview()
        } else if !decodedText.isEmpty {
            decodedText.removeLast()
        }
    }

    // MARK: - Batch Encode/Decode

    /// Encode a plaintext string into Morse code (space-separated, "/" for word breaks).
    static func encode(_ text: String) -> String {
        text.uppercased().map { char -> String in
            if char == " " {
                return "/"
            } else if let code = encodeTable[char] {
                return code
            } else {
                return "?"
            }
        }.joined(separator: " ")
    }

    /// Decode a Morse string (space-separated symbols, "/" for word breaks).
    static func decode(_ morse: String) -> String {
        morse.split(separator: " ").map { token -> String in
            let s = String(token)
            if s == "/" {
                return " "
            } else if let char = decodeTable[s] {
                return String(char)
            } else {
                return "[" + s + "]"
            }
        }.joined()
    }

    // MARK: - Private

    private func updateLivePreview() {
        if let char = Self.decodeTable[currentBuffer] {
            livePreview = String(char)
        } else if currentBuffer.isEmpty {
            livePreview = ""
        } else {
            // Show partial matches or just the raw buffer
            livePreview = currentBuffer
        }
    }
}
