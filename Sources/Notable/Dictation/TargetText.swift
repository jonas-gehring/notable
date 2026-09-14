import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation

/// What was in the target field when the key was released — read only with the
/// user's consent (`LocalPolish.readsTargetText`), only through Accessibility,
/// and never sent anywhere (Spec 32 Stufe 2).
///
/// This is the first time Notable reads text it did not record itself. Nothing
/// of it is stored or logged: the context goes into the on-device prompt, the
/// selection into an on-device command, the field is looked at once more for a
/// correction, and then it is gone.
struct TargetCapture: @unchecked Sendable {
    /// Up to `TargetTextRules.contextRadius` characters before the caret.
    var context: String?
    /// The text selected at the release, if any.
    var selection: String?
    /// Where the pasted text starts, in UTF-16 units — the selection's location.
    var insertionPoint: Int?
    /// The focused element, to look at the field again for a correction.
    var element: AXUIElement?
}

/// The pure half: what a context is, and what counts as a correction.
enum TargetTextRules {
    static let contextRadius = 500
    /// More substitutions than this is a rewrite, not a correction of a mishearing.
    static let maximumCorrections = 3

    /// The text before the caret, cut to whole words at the front and trimmed.
    static func context(in value: String, caret: Int, radius: Int = contextRadius) -> String? {
        let utf16 = Array(value.utf16)
        guard caret > 0, caret <= utf16.count else { return nil }
        let start = max(0, caret - radius)
        var text = String(decoding: utf16[start ..< caret], as: UTF16.self)
        if start > 0, let space = text.firstIndex(where: \.isWhitespace) {
            text = String(text[space...])
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Word substitutions between what Notable pasted at `start` and what the
    /// field holds there now (Spec 06 Quelle C).
    ///
    /// Deliberately narrow, because a wrong "correction" teaches the dictionary a
    /// mistake: at least three pasted words, the same number of words in the
    /// field, the first or the last word unchanged — so it is the same passage —
    /// and at most three substitutions, never more than a third of the words.
    /// Anything else is the user rewriting, which says nothing about mishearing.
    static func corrections(pasted: String, fieldText: String, start: Int) -> [(heard: String, corrected: String)] {
        let pastedWords = pasted.split(whereSeparator: \.isWhitespace).map(String.init)
        guard pastedWords.count >= 3 else { return [] }
        let utf16 = Array(fieldText.utf16)
        guard start >= 0, start < utf16.count else { return [] }
        let tail = String(decoding: utf16[start...], as: UTF16.self)
        let fieldWords = Array(tail.split(whereSeparator: \.isWhitespace).prefix(pastedWords.count)).map(String.init)
        guard fieldWords.count == pastedWords.count else { return [] }
        let sameStart = pastedWords.first?.lowercased() == fieldWords.first?.lowercased()
        let sameEnd = pastedWords.last?.lowercased() == fieldWords.last?.lowercased()
        guard sameStart || sameEnd else { return [] }
        let pairs = WordDiff.substitutions(
            from: pastedWords.joined(separator: " "), to: fieldWords.joined(separator: " ")
        )
        guard pairs.count <= maximumCorrections, pairs.count * 3 <= pastedWords.count else { return [] }
        return pairs
    }
}

/// The Accessibility half. Never in a password field, never without consent.
@MainActor
enum TargetTextAccess {
    /// Reads the focused field at the release. `wantsContext` is false for a
    /// command, which needs the selection but not the text before it.
    static func capture(wantsContext: Bool) -> TargetCapture? {
        guard LocalPolish.readsTargetText(), AXIsProcessTrusted(), !IsSecureEventInputEnabled() else { return nil }
        let system = AXUIElementCreateSystemWide()
        // Read on the key release, on the main actor: a hung target app must not
        // hold the dictation for the default six seconds.
        AXUIElementSetMessagingTimeout(system, 0.25)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID()
        else { return nil }
        let element = unsafeDowncast(focused, to: AXUIElement.self)
        guard string(element, kAXSubroleAttribute) != kAXSecureTextFieldSubrole else { return nil }

        var capture = TargetCapture(element: element)
        if let selection = string(element, kAXSelectedTextAttribute), !selection.isEmpty {
            capture.selection = selection
        }
        if let range = selectedRange(element) {
            capture.insertionPoint = range.location
            if wantsContext, let value = string(element, kAXValueAttribute) {
                capture.context = TargetTextRules.context(in: value, caret: range.location)
            }
        }
        return capture
    }

    static func currentValue(of element: AXUIElement) -> String? {
        string(element, kAXValueAttribute)
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func selectedRange(_ element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        var range = CFRange()
        guard AXValueGetValue(unsafeDowncast(value, to: AXValue.self), .cfRange, &range) else { return nil }
        return range
    }
}
