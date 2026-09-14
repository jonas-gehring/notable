import AppKit
import Carbon.HIToolbox
import Foundation
import os

/// A released recording on its way to the paste. A value, so a retried clip
/// (Spec 30 §3.7) runs through exactly the same path as a fresh one.
struct DictationJob: Sendable {
    let generation: Int
    let samples: [Float]
    let sampleRate: Int
    let duration: TimeInterval
    let startedAt: Date
    let releasedAt: ContinuousClock.Instant
    let targetBundleID: String?
    /// Which key started it: plain, enhanced, or a command (Spec 32 Stufe 2).
    let role: HotkeyRole
    /// The target field at the release, when reading it is allowed.
    let target: TargetCapture?
    let notice: String?
}

/// From transcript to pasted text: the rules, the on-device stage, the CLI
/// enhancement, the paste and the save (Spec 29–32).
///
/// Taken out of `DictationController` in Spec 29 §9: the controller decides
/// *when* a job runs and whether it is still wanted; this says *what* happens
/// to its text.
@MainActor
enum DictationTextStages {
    private static let log = Logger(subsystem: "de.jonasgehring.notable", category: "dictation")

    struct Input {
        let transcript: String
        let tokens: [TimedToken]?
        let category: AppCategory
        let role: HotkeyRole
        let capture: TargetCapture?
        let localMode: LocalPolish.Mode
    }

    struct Text {
        var toPaste: String
        /// The rule-polished text, set whenever a model changed it.
        var rawText: String?
        /// Which stage shaped the text last: "rules", "local" or "cli".
        var polisher = "rules"
        var polishMs: Int?
        /// A stage that fell back to the rules says so after the paste.
        var notice: String?
        /// When the rules were done — the end of the latency measurement. Any
        /// model stage books its own time (`polish_ms`), the CLI none.
        let polishedAt: ContinuousClock.Instant
    }

    enum Outcome {
        case cancelled
        case failed(DictationFailure)
        case produced(Text)
    }

    /// Runs the stages. `isLive` is asked after every await; `show` puts a
    /// state on the HUD, delayed or at once.
    static func produce(
        _ input: Input,
        isLive: () -> Bool,
        show: (DictationOverlayController.OverlayState, _ delayed: Bool) -> Void
    ) async -> Outcome {
        // Off the main actor: `polish` is pure. Pauses are read off the raw
        // transcript, whose sentences the tokens spell (Spec 31 §3.5).
        let options = PolishProfile.options(for: input.category)
        let transcript = input.transcript
        let tokens = input.tokens
        let polished = await Task.detached(priority: .userInitiated) {
            var withPauses = options
            withPauses.sentencePauses = tokens.flatMap {
                SpeechPauses.sentenceBoundaryPauses(tokens: $0, text: transcript)
            }
            return TextPolisher.polish(transcript, options: withPauses)
        }.value
        guard isLive() else { return .cancelled }
        if let failure = DictationPipeline.afterTranscript(polished) { return .failed(failure) }

        let trimmed = polished.trimmingCharacters(in: .whitespacesAndNewlines)
        if input.role == .command {
            return await command(trimmed, selection: input.capture?.selection, isLive: isLive, show: show)
        }
        var text = Text(toPaste: trimmed, polishedAt: .now)

        // On the device, nothing leaves it (Spec 32).
        if LocalPolish.shouldRun(mode: input.localMode, category: input.category, text: trimmed) {
            show(.formatting, true)
            if let result = await localPolish(trimmed, category: input.category, context: input.capture?.context) {
                guard isLive() else { return .cancelled }
                text.polishMs = result.milliseconds
                if result.didPolish {
                    text.rawText = trimmed
                    text.toPaste = result.text
                    text.polisher = "local"
                }
                text.notice = result.failure
            }
        }

        // The only place dictation text may leave the device, and only because
        // *this* recording was started with the enhancement hotkey.
        if input.role == .enhanced, EnhancementSettings.isEnabled {
            show(.enhancing, false)
            let result = await DictationEnhancer.forDictation().enhance(
                text.toPaste, profile: EnhancementSettings.profile(for: input.category)
            )
            // Booked even when the guardrails rejected the answer: the row counts
            // how often dictation text left the device, not what it cost.
            await UsageRecorder.record(
                result.usage,
                provider: DictationEnhancer.dictationProvider.id,
                purpose: .dictationEnhance,
                recordingID: nil,
                countEvenWhenUnknown: true
            )
            guard isLive() else { return .cancelled }
            if result.didEnhance {
                text.rawText = text.rawText ?? trimmed
                text.toPaste = result.text
                text.polisher = "cli"
            }
            text.notice = result.failure ?? text.notice
        }
        return .produced(text)
    }

    enum Delivery {
        case pasted
        /// The text is on the pasteboard instead, and this says why.
        case notPasted(DictationFailure)
    }

    /// Pastes into the target frozen at the release — or not, when another app
    /// is in front by now (⌘V would land there) or a password field has secure
    /// input on.
    static func deliver(_ text: String, target: String?) -> Delivery {
        let front = NSWorkspace.shared.frontmostApplication
        switch DictationPipeline.paste(
            target: target,
            frontmost: front?.bundleIdentifier,
            frontmostName: front?.localizedName,
            secureInput: IsSecureEventInputEnabled()
        ) {
        case .clipboard(let failure):
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            return .notPasted(failure)
        case .paste:
            do {
                try Paster.insert(text)
                return .pasted
            } catch {
                // Without Accessibility the synthesized ⌘V goes nowhere; `Paster`
                // left the text on the pasteboard.
                return .notPasted(.pasteBlocked)
            }
        }
    }

    /// Saves the dictation. False when it could not be saved — the text is
    /// pasted either way, but history and statistics would silently miss it.
    static func save(_ text: Text, job: DictationJob, engine: String, latencyMs: Int?, sourceApp: String?) async -> Bool {
        do {
            try await RecordingStore.shared.saveDictation(
                text: text.toPaste,
                startedAt: job.startedAt,
                duration: job.duration,
                engine: engine,
                latencyMs: latencyMs,
                // Stays in SQLite and never goes into a prompt.
                sourceApp: sourceApp,
                // "Enhanced" counts text that left the device — the CLI only.
                enhanced: text.polisher == "cli",
                rawText: text.rawText,
                polisher: text.polisher,
                polishMs: text.polishMs
            )
            return true
        } catch {
            log.error("Diktat nicht gespeichert: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    static func milliseconds(from start: ContinuousClock.Instant, to end: ContinuousClock.Instant) -> Int {
        let elapsed = start.duration(to: end)
        return Int(Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15)
    }

    // MARK: - On-device stage

    /// Warms the local model when its mode is on, rather than on the first dictation.
    static func prewarmLocalModel() {
        #if canImport(FoundationModels)
        guard #available(macOS 26, *), LocalPolish.Mode.current() != .off else { return }
        Task { await LocalPolisher.shared.prewarm() }
        #endif
    }

    /// Nil means the stage does not exist on this system — not that it failed.
    private static func localPolish(_ text: String, category: AppCategory, context: String?) async -> LocalPolishResult? {
        #if canImport(FoundationModels)
        guard #available(macOS 26, *) else { return nil }
        return await LocalPolisher.shared.polish(text, category: category, context: context)
        #else
        return nil
        #endif
    }

    /// A spoken command on the selection, run by the on-device model (Spec 04
    /// on the device). The answer is pasted like a dictation: with the selection
    /// still active, ⌘V replaces it — the same path, the same target check.
    /// Nothing is pasted when the model is missing or its answer is unusable.
    private static func command(
        _ spoken: String,
        selection: String?,
        isLive: () -> Bool,
        show: (DictationOverlayController.OverlayState, _ delayed: Bool) -> Void
    ) async -> Outcome {
        let availability = LocalModelAvailability.current
        guard availability.isAvailable else { return .failed(.localModelUnavailable(reason: availability.reason)) }
        #if canImport(FoundationModels)
        guard #available(macOS 26, *) else { return .failed(.localModelUnavailable(reason: availability.reason)) }
        show(.commanding, false)
        let result = await LocalPolisher.shared.runCommand(spoken, selection: selection)
        guard isLive() else { return .cancelled }
        guard result.didPolish else { return .failed(.commandFailed) }
        var text = Text(toPaste: result.text, polishedAt: .now)
        text.rawText = spoken
        text.polisher = "command"
        text.polishMs = result.milliseconds
        return .produced(text)
        #else
        return .failed(.localModelUnavailable(reason: availability.reason))
        #endif
    }

    /// Looks at the field once more after the paste and learns from a corrected
    /// word (Spec 06 Quelle C) — only with consent, only a few words, and only as
    /// a suggestion: `PersonalDictionary` still waits for the user to accept it.
    static let correctionDelay: Duration = .seconds(30)

    static func watchForCorrections(_ pasted: String, capture: TargetCapture?) {
        guard let capture, let element = capture.element, let start = capture.insertionPoint else { return }
        Task { @MainActor in
            try? await Task.sleep(for: correctionDelay)
            guard LocalPolish.readsTargetText(), let value = TargetTextAccess.currentValue(of: element) else { return }
            for pair in TargetTextRules.corrections(pasted: pasted, fieldText: value, start: start) {
                PersonalDictionary.recordCorrection(heard: pair.heard, corrected: pair.corrected)
            }
        }
    }
}
