import Combine
import Foundation
import WatchKit

/// Provides distinct Taptic Engine feedback patterns for each input event.
///
/// Pattern design:
/// - Dot: short, light click (mirrors the brevity of a dot)
/// - Dash: longer, heavier thump (mirrors the weight of a dash)
/// - Commit: subtle confirmation tap
/// - Shortcut expansion: rising pattern to signal text replacement
final class HapticFeedbackManager: ObservableObject {

    // MARK: - Published Settings

    /// Master toggle for haptic feedback.
    @Published var isEnabled: Bool = true

    // MARK: - Feedback Patterns

    /// Short click for a dot input.
    func playDot() {
        guard isEnabled else { return }
        WKInterfaceDevice.current().play(.click)
    }

    /// Heavier thump for a dash input.
    func playDash() {
        guard isEnabled else { return }
        WKInterfaceDevice.current().play(.directionUp)
    }

    /// Subtle confirmation when a character is auto-committed.
    func playCommit() {
        guard isEnabled else { return }
        WKInterfaceDevice.current().play(.success)
    }

    /// Rising pattern when a shortcut expands into full text.
    func playShortcutExpansion() {
        guard isEnabled else { return }
        let device = WKInterfaceDevice.current()
        // Three-tap rising pattern
        device.play(.click)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            device.play(.directionUp)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            device.play(.success)
        }
    }

    /// Error feedback (e.g. unrecognized pattern).
    func playError() {
        guard isEnabled else { return }
        WKInterfaceDevice.current().play(.failure)
    }

    /// Feedback for delete/backspace.
    func playDelete() {
        guard isEnabled else { return }
        WKInterfaceDevice.current().play(.retry)
    }
}
