import AVFoundation
import Foundation

/// Microphone capture into a 16 kHz mono Float32 buffer.
final class AudioRecorder: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let downsampler = PCMDownsampler()
    private var configObserver: NSObjectProtocol?

    /// Fired when the audio route changes mid-recording (device unplugged,
    /// AirPods connected …). The owner decides how to react.
    var onConfigurationChange: (@Sendable () -> Void)?

    var targetSampleRate: Int { PCMDownsampler.targetSampleRate }

    /// Echo cancellation (VPIO). Meetings need it: without headphones the
    /// remote voices come out of the speakers and back into this mic, and the
    /// echo does not merely duplicate them — it fills the pauses, so the VAD
    /// fuses the other side's words with the user's next sentence into one
    /// "Ich" segment. Measured; a post-hoc dedup cannot repair that.
    ///
    /// Deliberately OFF for dictation: VPIO spins up an output unit, adds IO
    /// latency and AGC to the mic path, and dictation's whole point is the
    /// 200 ms release→paste budget. Never make this a global setting.
    private(set) var voiceProcessing = false

    /// Set when VPIO was requested but the OS refused it — the caller must say
    /// so, because the transcript will then contain the speaker bleed.
    private(set) var voiceProcessingError: String?

    /// RMS of the latest audio chunk, for the overlay level meter.
    var level: Float { downsampler.currentLevel }

    /// Copy of everything captured so far, without stopping the engine.
    func snapshot() -> [Float] { downsampler.snapshot() }

    /// Writes silence for the wall-clock time this track missed.
    ///
    /// Exposed because sleep/wake is not a route change: the engine may come
    /// back without posting a configuration change, and the hole is then only
    /// visible from the outside.
    func padGapToWallClock() { downsampler.padGapToWallClock() }

    func start(spoolingTo spoolURL: URL? = nil, voiceProcessing: Bool = false) throws {
        try downsampler.reset(spoolingTo: spoolURL)
        self.voiceProcessing = voiceProcessing
        voiceProcessingError = nil

        try installTapAndStart(errorCode: 1)

        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            self?.onConfigurationChange?()
        }
    }

    /// Re-installs the tap and restarts the engine after a route change,
    /// WITHOUT resetting the sample buffer — the recording continues.
    func resume() throws {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try installTapAndStart(errorCode: 2)
        // The dead time between the route change and here is real time; the
        // track must carry it as silence or every later segment is stamped
        // too early relative to the system-audio track.
        downsampler.padGapToWallClock()
    }

    private func installTapAndStart(errorCode: Int) throws {
        let input = engine.inputNode

        if voiceProcessing, !input.isVoiceProcessingEnabled {
            do {
                // Must happen while the engine is stopped, and before the
                // format is read — VPIO changes the input format.
                try input.setVoiceProcessingEnabled(true)
                // VPIO's AGC pumps room noise up between turns, which is
                // exactly what the VAD then mistakes for speech.
                input.isVoiceProcessingAGCEnabled = false

                // VPIO is a full-duplex I/O unit: with only an input tap and no
                // active output render, it never pulls the mic and the tap gets
                // pure digital silence (measured: mic.pcm all zeros). Give it a
                // *muted* output render side to drive the I/O cycle — volume 0 so
                // nothing is played and there is no feedback path back into the mic.
                engine.mainMixerNode.outputVolume = 0
                engine.connect(engine.mainMixerNode, to: engine.outputNode, format: nil)
            } catch {
                // A meeting without echo cancellation is still worth recording —
                // but the caller has to warn, or the note silently gains a ghost.
                voiceProcessing = false
                voiceProcessingError = error.localizedDescription
            }
        }

        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else {
            throw NSError(
                domain: "Notable.AudioRecorder", code: errorCode,
                userInfo: [NSLocalizedDescriptionKey: errorCode == 1
                    ? String(localized: "Kein Aufnahmegerät verfügbar.")
                    : String(localized: "Kein Aufnahmegerät nach Gerätewechsel.")]
            )
        }

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [downsampler] buffer, _ in
            downsampler.append(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            // Leaving the tap installed would crash the next start() with a
            // double-install NSException.
            input.removeTap(onBus: 0)
            throw error
        }
    }

    /// Stops the engine and returns everything captured since `start()`.
    func stop() -> [Float] {
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
            self.configObserver = nil
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        return downsampler.drain()
    }
}
