import AVFoundation
import XCTest
@testable import Notable

/// Spec 31 §3.5 against the real model — the part `SpeechPausesTests` cannot
/// prove with synthetic tokens: that Parakeet's `tokenTimings` actually spell its
/// `text`, so the mapping yields pauses instead of silently falling back.
///
/// Audio is synthesized with `say`: two sentences with a long silence between
/// them. Skipped when the model is not on disk or `say` has no voice — it
/// downloads nothing.
final class SpeechPausesModelTests: XCTestCase {
    func testParakeetTokensSpellTheTextAndShowThePause() async throws {
        try XCTSkipUnless(ParakeetTranscriber.modelsArePresent, "Parakeet v3 ist nicht geladen")

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpeechPausesModelTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // `[[slnc 1500]]` is say's own pause command: a measured gap, not a guess.
        let audio = directory.appendingPathComponent("speech.aiff")
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-v", "Anna", "-o", audio.path,
                         "Wir treffen uns morgen im Büro. [[slnc 1500]] Bitte bring die Unterlagen mit."]
        try say.run()
        say.waitUntilExit()
        try XCTSkipUnless(say.terminationStatus == 0, "say hat keine deutsche Stimme")

        let samples = try Self.resampled(audio)
        let transcriber = ParakeetTranscriber()
        try await transcriber.prepare()
        let result = try await transcriber.transcribeDetailed(samples: samples, sampleRate: 16_000)

        let tokens = try XCTUnwrap(result.tokens, "Parakeet lieferte keine tokenTimings")
        XCTAssertFalse(tokens.isEmpty)
        let pauses = SpeechPauses.sentenceBoundaryPauses(tokens: tokens, text: result.text)
        let unwrapped = try XCTUnwrap(pauses, "Tokens buchstabieren den Text nicht: \(result.text)")
        print("SPEECH_PAUSES_MODEL text=\(result.text) pauses=\(unwrapped)")
        XCTAssertTrue(unwrapped.contains(true), "Die 1,5-s-Pause wurde nicht erkannt: \(unwrapped)")
    }

    /// Reads an audio file and converts it to 16 kHz mono Float32.
    private static func resampled(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let target = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false))
        let converter = try XCTUnwrap(AVAudioConverter(from: file.processingFormat, to: target))
        let input = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: input)
        let capacity = AVAudioFrameCount(Double(input.frameLength) * 16_000 / file.processingFormat.sampleRate) + 1024
        let output = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity))
        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .endOfStream
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return input
        }
        if let error { throw error }
        let channel = try XCTUnwrap(output.floatChannelData)
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(output.frameLength)))
    }
}
