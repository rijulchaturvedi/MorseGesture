import Combine
import Foundation
import WatchKit

/// Bridges watchOS AssistiveTouch hand gestures into the Morse input system.
///
/// watchOS AssistiveTouch (Settings > Accessibility > AssistiveTouch) provides
/// built-in recognition for four hand gestures:
///   - Pinch (quick thumb-to-index tap)
///   - Double Pinch
///   - Clench (full fist close)
///   - Double Clench
///
/// For MorseGesture, we map:
///   - Pinch → Dot
///   - Clench → Dash
///   - Double Pinch → Manual commit (end current character)
///   - Double Clench → Word space
///
/// HOW THIS WORKS:
/// AssistiveTouch gestures are delivered as accessibility actions at the
/// system level. On watchOS, the primary integration path is through
/// the accessibility action API on SwiftUI views.
///
/// The user must enable AssistiveTouch in Watch settings:
///   Settings > Accessibility > AssistiveTouch > ON
///   Then under "Hand Gestures" make sure gestures are enabled.
///
/// NOTE: As of watchOS 11, AssistiveTouch gestures are delivered as
/// system-level actions. This handler provides the SwiftUI accessibility
/// action modifiers and a callback interface to wire into GestureInputManager.
final class AccessibilityGestureHandler: ObservableObject {

    // MARK: - Types

    enum HandGesture: String, CaseIterable {
        case pinch        = "Pinch"
        case doublePinch  = "Double Pinch"
        case clench       = "Clench"
        case doubleClench = "Double Clench"
    }

    /// What Morse action each hand gesture maps to.
    enum MorseAction {
        case dot
        case dash
        case commitCharacter
        case wordSpace
        case delete
        case speak
    }

    // MARK: - Published State

    @Published var isEnabled: Bool = true

    /// Current gesture-to-action mapping (user-customizable).
    @Published var gestureMap: [HandGesture: MorseAction] = [
        .pinch:        .dot,
        .clench:       .dash,
        .doublePinch:  .commitCharacter,
        .doubleClench: .wordSpace,
    ]

    // MARK: - Callback

    /// Called when a mapped gesture is recognized.
    /// The GestureInputManager hooks into this.
    var onAction: ((MorseAction) -> Void)?

    // MARK: - Gesture Processing

    /// Call this when a hand gesture is received (from the SwiftUI
    /// accessibility action modifier).
    func handleGesture(_ gesture: HandGesture) {
        guard isEnabled else { return }
        guard let action = gestureMap[gesture] else { return }
        onAction?(action)
    }

    // MARK: - Customization

    /// Remap a gesture to a different action.
    func setMapping(_ gesture: HandGesture, to action: MorseAction) {
        gestureMap[gesture] = action
    }

    /// Reset to default mapping.
    func resetMapping() {
        gestureMap = [
            .pinch:        .dot,
            .clench:       .dash,
            .doublePinch:  .commitCharacter,
            .doubleClench: .wordSpace,
        ]
    }
}
