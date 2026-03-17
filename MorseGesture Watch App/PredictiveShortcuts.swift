import Combine
import Foundation

/// Manages Morse shortcut codes that expand into common phrases.
///
/// For example, typing "HL" in Morse expands to "HELP".
/// Shortcuts are persisted via UserDefaults so users can
/// customize them.
///
/// Future: integrate with on-device Foundation Models for
/// context-aware expansion and error correction.
final class PredictiveShortcuts: ObservableObject {

    // MARK: - Types

    struct Shortcut: Identifiable, Codable, Equatable {
        var id: String { code }
        let code: String       // e.g. "HL"
        let expansion: String  // e.g. "HELP"
        let category: Category

        enum Category: String, Codable, CaseIterable {
            case emergency
            case medical
            case daily
            case custom
        }
    }

    // MARK: - Published State

    @Published var activeShortcuts: [Shortcut] = []

    // MARK: - Defaults

    static let defaultShortcuts: [Shortcut] = [
        // Emergency
        Shortcut(code: "HL",  expansion: "HELP",                    category: .emergency),
        Shortcut(code: "911", expansion: "CALL 911",                category: .emergency),
        Shortcut(code: "SOS", expansion: "SOS EMERGENCY",           category: .emergency),
        Shortcut(code: "DN",  expansion: "DANGER",                  category: .emergency),
        Shortcut(code: "FI",  expansion: "FIRE",                    category: .emergency),

        // Medical
        Shortcut(code: "DR",  expansion: "CALL DOCTOR",             category: .medical),
        Shortcut(code: "PN",  expansion: "PAIN",                    category: .medical),
        Shortcut(code: "MD",  expansion: "NEED MEDICATION",         category: .medical),
        Shortcut(code: "BR",  expansion: "TROUBLE BREATHING",       category: .medical),
        Shortcut(code: "NR",  expansion: "NEED NURSE",              category: .medical),

        // Daily
        Shortcut(code: "TY",  expansion: "THANK YOU",               category: .daily),
        Shortcut(code: "YS",  expansion: "YES",                     category: .daily),
        Shortcut(code: "NO",  expansion: "NO",                      category: .daily),
        Shortcut(code: "PL",  expansion: "PLEASE",                  category: .daily),
        Shortcut(code: "WA",  expansion: "WATER",                   category: .daily),
        Shortcut(code: "FD",  expansion: "FOOD",                    category: .daily),
        Shortcut(code: "HO",  expansion: "HOT",                     category: .daily),
        Shortcut(code: "CO",  expansion: "COLD",                    category: .daily),
        Shortcut(code: "TB",  expansion: "NEED TO GO TO BATHROOM",  category: .daily),
        Shortcut(code: "LU",  expansion: "I LOVE YOU",              category: .daily),
    ]

    // MARK: - Persistence Key

    private let storageKey = "MorseGesture.shortcuts"

    // MARK: - Init

    init() {
        loadShortcuts()
    }

    // MARK: - Public Methods

    /// Add a custom shortcut.
    func addShortcut(code: String, expansion: String) {
        let shortcut = Shortcut(
            code: code.uppercased(),
            expansion: expansion.uppercased(),
            category: .custom
        )
        // Replace if code already exists
        activeShortcuts.removeAll { $0.code == shortcut.code }
        activeShortcuts.append(shortcut)
        saveShortcuts()
    }

    /// Remove a shortcut by code.
    func removeShortcut(code: String) {
        activeShortcuts.removeAll { $0.code == code.uppercased() }
        saveShortcuts()
    }

    /// Reset to default shortcuts.
    func resetToDefaults() {
        activeShortcuts = Self.defaultShortcuts
        saveShortcuts()
    }

    /// Look up expansion for a given code.
    func expansion(for code: String) -> String? {
        activeShortcuts.first { $0.code == code.uppercased() }?.expansion
    }

    // MARK: - Persistence

    private func loadShortcuts() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let saved = try? JSONDecoder().decode([Shortcut].self, from: data) else {
            // First launch: use defaults
            activeShortcuts = Self.defaultShortcuts
            return
        }
        activeShortcuts = saved
    }

    private func saveShortcuts() {
        if let data = try? JSONEncoder().encode(activeShortcuts) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    // MARK: - Foundation Model Integration (Stub)

    // TODO: Phase 2 - On-device Foundation Model for predictive expansion
    //
    // The idea: instead of exact-match shortcuts, use a small on-device
    // model to predict the intended phrase from partial or error-prone
    // Morse input.
    //
    // Key differences from keyboard autocorrect:
    //   - Error patterns are timing-based (extra dots from tremor,
    //     merged dashes from slow release) not spatial
    //   - Training data would need to come from actual ALS patient
    //     input sessions
    //   - Latency budget is tight: predictions must arrive before the
    //     next character commit (~1.5s)
    //
    // func predictExpansion(morseSequence: String, context: String) async -> String? {
    //     // Use Apple's Foundation Models framework (watchOS 26+)
    //     // let session = LanguageModelSession()
    //     // let prompt = "Given Morse input '\(morseSequence)' in context '\(context)', predict intended phrase:"
    //     // let response = try await session.respond(to: prompt)
    //     // return response.content
    // }
}
