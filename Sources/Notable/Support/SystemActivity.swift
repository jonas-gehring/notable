import CoreGraphics
import Foundation

/// Whether someone is at the Mac — what `UpdateWindow` needs to tell "a window
/// is open" from "a window is in use". Neither read needs a permission.
enum SystemActivity {
    /// Seconds since the last keyboard or mouse event in this login session.
    static var idleSeconds: TimeInterval {
        // `kCGAnyInputEventType` is ~0; Swift has no named case for it.
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    static var isScreenLocked: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return session["CGSSessionScreenIsLocked"] as? Bool ?? false
    }
}
