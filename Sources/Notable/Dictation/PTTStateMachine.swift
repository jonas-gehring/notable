import Foundation

/// Push-to-talk semantics with hands-free lock:
/// - **Hold** (≥ tapThreshold) and release → classic PTT, transcribe on release.
/// - **Short tap** → recording locks on (hands-free); the next tap stops it.
/// - Esc cancels either mode (handled outside via reset()).
/// Pure and unit-tested; the controller maps actions to recording calls.
struct PTTStateMachine: Sendable {
    enum Phase: Equatable {
        case idle
        case held
        case locked
    }

    enum Action: Equatable {
        case start
        case finish
        case none
    }

    /// Presses shorter than this are taps (lock), longer are holds (PTT).
    var tapThreshold: TimeInterval = 0.35

    private(set) var phase: Phase = .idle
    private var pressedAt: TimeInterval = 0

    var isLocked: Bool { phase == .locked }

    mutating func keyDown(at time: TimeInterval) -> Action {
        switch phase {
        case .idle:
            phase = .held
            pressedAt = time
            return .start
        case .locked:
            // Any press while locked stops the recording; the matching
            // keyUp lands in .idle and is ignored.
            phase = .idle
            return .finish
        case .held:
            return .none
        }
    }

    mutating func keyUp(at time: TimeInterval) -> Action {
        guard phase == .held else { return .none }
        if time - pressedAt < tapThreshold {
            phase = .locked
            return .none
        }
        phase = .idle
        return .finish
    }

    /// Cancel (Esc) or any external stop.
    mutating func reset() {
        phase = .idle
    }
}
