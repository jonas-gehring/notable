import Darwin
import FluidAudio
import XCTest

/// The pipeline has only ever been driven with clips of a few seconds. A real
/// meeting is 30–60 minutes. This builds a synthetic ~30-minute two-track
/// meeting and measures what actually happens after `stop()`: how long the user
/// waits for the note, and how much memory the process holds while producing it.
///
/// Everything is printed as `SCALE_PROBE` lines; the assertions at the end are
/// deliberately tied to what the app needs, not to what the code happens to do.
final class MeetingScaleTests: XCTestCase {
    /// Target length of the synthetic meeting. 30 min is half a realistic
    /// worst case and already exposes every growth term.
    private static let targetDuration: TimeInterval = 30 * 60
    private static let sampleRate = 16_000

    // MARK: - Sample material

    private struct Line {
        let voice: String?      // nil = mic track ("Ich")
        let mine: Bool
        let text: String
    }

    /// A handful of sentences, synthesized once, then repeated with variation.
    /// Calling `say` per turn would take longer than the pipeline run itself.
    private static let lines: [Line] = [
        Line(voice: nil, mine: true,
             text: "Good morning everyone, let us start with the quarterly revenue and how the regions did."),
        Line(voice: "Daniel", mine: false,
             text: "Sure, the northern region grew by eleven percent last month, and the southern one held steady."),
        Line(voice: nil, mine: true,
             text: "That is encouraging. What about the hiring budget for the platform team this quarter?"),
        Line(voice: "Samantha", mine: false,
             text: "The budget is still frozen until the workshop in Hamburg, which was moved to the end of October."),
        Line(voice: "Daniel", mine: false,
             text: "To add to that, the migration to the new database finished last weekend without any downtime."),
        Line(voice: "Samantha", mine: false,
             text: "And the customer feedback was excellent, so we should repeat the format in the coming spring."),
    ]

    private func speak(_ text: String, voice: String?) throws -> [Float] {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("notable-scale-\(UUID().uuidString).aiff")
        defer { try? FileManager.default.removeItem(at: url) }
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = (voice.map { ["-v", $0] } ?? []) + ["-r", "160", "-o", url.path, text]
        try say.run()
        say.waitUntilExit()
        guard say.terminationStatus == 0 else {
            throw XCTSkip("`say` mit Stimme \(voice ?? "Standard") nicht verfügbar")
        }
        return try AudioConverter().resampleAudioFile(path: url.path)
    }

    // MARK: - Memory probe

    private static func physFootprintBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? UInt64(info.phys_footprint) : 0
    }

    /// Polls `phys_footprint` on a background thread — the peak, and *when* it
    /// happens, is what decides whether an hour fits in RAM. The trace separates
    /// a one-shot diarizer spike from memory piling up across the ASR loop.
    private final class MemoryPeakSampler: @unchecked Sendable {
        private let lock = NSLock()
        private var peak: UInt64 = 0
        private var trace: [(t: TimeInterval, bytes: UInt64)] = []
        private var running = true
        private let started = Date()

        func start() {
            Thread.detachNewThread { [self] in
                while true {
                    lock.lock()
                    let go = running
                    lock.unlock()
                    guard go else { return }
                    let now = MeetingScaleTests.physFootprintBytes()
                    let elapsed = Date().timeIntervalSince(started)
                    lock.lock()
                    peak = max(peak, now)
                    trace.append((elapsed, now))
                    lock.unlock()
                    usleep(25_000)
                }
            }
        }

        struct Result {
            var peak: UInt64
            var peakAt: TimeInterval
            /// One sample every ~2 s, for the shape of the curve.
            var curve: [(t: TimeInterval, bytes: UInt64)]
            var final: UInt64
        }

        func stop() -> Result {
            lock.lock()
            running = false
            let final = MeetingScaleTests.physFootprintBytes()
            let samples = trace
            let top = max(peak, final)
            lock.unlock()

            let peakAt = samples.first { $0.bytes == top }?.t
                ?? samples.max { $0.bytes < $1.bytes }?.t ?? 0
            var curve: [(t: TimeInterval, bytes: UInt64)] = []
            var nextTick: TimeInterval = 0
            for sample in samples where sample.t >= nextTick {
                curve.append(sample)
                nextTick = sample.t + 2
            }
            return Result(peak: top, peakAt: peakAt, curve: curve, final: final)
        }
    }

    private static func mb(_ bytes: UInt64) -> Double { Double(bytes) / 1_048_576 }

    // MARK: - The probe

    func testThirtyMinuteMeetingScales() async throws {
        let sampleRate = Self.sampleRate

        // 1. Synthesize the sentence pool once.
        let buildStart = Date()
        let clips = try Self.lines.map { (line: $0, audio: try speak($0.text, voice: $0.voice)) }
        let sayDuration = Date().timeIntervalSince(buildStart)

        // 2. Assemble the long tracks: interleaved turns, the other side silent —
        //    exactly how the mic and the system tap see a call (mirrors
        //    MeetingConversationTests). Pauses vary so turn boundaries are not
        //    perfectly periodic.
        let neededSamples = Int(Self.targetDuration * Double(sampleRate))
        var micTrack: [Float] = []
        var systemTrack: [Float] = []
        micTrack.reserveCapacity(neededSamples + sampleRate)
        systemTrack.reserveCapacity(neededSamples + sampleRate)

        var turnIndex = 0
        var spokenSamples = 0
        while micTrack.count < neededSamples {
            let clip = clips[turnIndex % clips.count]
            // 0.4 s … 1.1 s of pause, cycling — no two consecutive gaps equal.
            let pauseSamples = sampleRate * (4 + (turnIndex % 8)) / 10
            let pause = [Float](repeating: 0, count: pauseSamples)
            let silence = [Float](repeating: 0, count: clip.audio.count)

            micTrack += (clip.line.mine ? clip.audio : silence) + pause
            systemTrack += (clip.line.mine ? silence : clip.audio) + pause
            spokenSamples += clip.audio.count
            turnIndex += 1
        }

        let trackSeconds = Double(micTrack.count) / Double(sampleRate)
        let trackBytes = UInt64(micTrack.count * MemoryLayout<Float>.size)
        print(String(format: "SCALE_PROBE build: say=%.1f s, turns=%d, track=%.1f s (%.1f min), " +
                             "speech=%.1f s, per-track RAM=%.1f MB, both=%.1f MB",
                     sayDuration, turnIndex, trackSeconds, trackSeconds / 60,
                     Double(spokenSamples) / Double(sampleRate),
                     Self.mb(trackBytes), Self.mb(trackBytes * 2)))

        // 3. Warm the model exactly as the app does — the cache hands dictation
        //    and the meeting the same instance, so loading is not part of the wait.
        let transcriber = ParakeetTranscriber()
        try await transcriber.prepare()

        let baseline = Self.physFootprintBytes()
        print(String(format: "SCALE_PROBE memory: baseline (both tracks + warm ASR models) = %.1f MB",
                     Self.mb(baseline)))

        // 4. The real thing, end to end, with a memory-peak sampler running.
        //    This is exactly the wait the user sees after stop(). It runs first
        //    and alone: nothing this test allocates may pollute the peak.
        let sampler = MemoryPeakSampler()
        sampler.start()
        let processStart = Date()
        let segments = try await MeetingPipeline.process(
            micSamples: micTrack,
            systemSamples: systemTrack,
            transcriber: transcriber
        )
        let processDuration = Date().timeIntervalSince(processStart)
        let memory = sampler.stop()
        let peak = memory.peak

        let words = segments.reduce(0) { $0 + $1.text.split(separator: " ").count }
        let speakers = Set(segments.compactMap(\.speaker))
        print(String(format: "SCALE_PROBE process: %.2f s wall clock for %.1f min of audio (%.0fx real time)",
                     processDuration, trackSeconds / 60, trackSeconds / max(processDuration, 0.001)))
        print("SCALE_PROBE transcript: \(segments.count) segments, \(words) words, speakers \(speakers.sorted())")
        print(String(format: "SCALE_PROBE memory: peak=%.1f MB (baseline %.1f MB → pipeline adds %.1f MB " +
                             "on top of the %.1f MB of raw tracks)",
                     Self.mb(peak), Self.mb(baseline), Self.mb(peak) - Self.mb(baseline),
                     Self.mb(trackBytes * 2)))
        print(String(format: "SCALE_PROBE memory: peak reached %.0f %% into the run (%.1f s of %.1f s), " +
                             "footprint at return = %.1f MB",
                     100 * memory.peakAt / max(processDuration, 0.001), memory.peakAt, processDuration,
                     Self.mb(memory.final)))
        print("SCALE_PROBE memory curve (s → MB): " + memory.curve
            .map { String(format: "%.0f→%.0f", $0.t, Self.mb($0.bytes)) }
            .joined(separator: " "))
        print(String(format: "SCALE_PROBE extrapolation 60 min (all terms are linear in length): " +
                             "wait ≈ %.0f s, raw tracks ≈ %.0f MB, peak ≈ %.0f MB",
                     processDuration * 2, Self.mb(trackBytes * 2) * 2,
                     (Self.mb(peak) - Self.mb(trackBytes * 2)) + 2 * Self.mb(trackBytes * 2)))

        // 5. Attribution. MeetingPipeline.process is a straight line and carries
        //    no instrumentation, so the phases are re-run here with the same
        //    calls in the same order to say where the wall clock went. Scoped so
        //    its buffers are gone before the numbers are printed.
        let phases = try await measurePhases(mic: micTrack, system: systemTrack, transcriber: transcriber)

        print(String(format: "SCALE_PROBE vad: mic=%.2f s (%d regions), system=%.2f s (%d regions), " +
                             "compaction=%.2f s → compact system track %.1f s",
                     phases.micVad, phases.micRegions, phases.systemVad, phases.systemRegions,
                     phases.compaction, phases.compactSeconds))
        print(String(format: "SCALE_PROBE diarization: %.2f s (model load %.2f s), %d segments, %d speakers",
                     phases.diarization, phases.diarizerModelLoad, phases.diarizedSegments,
                     phases.diarizedSpeakers))
        print(String(format: "SCALE_PROBE asr: %d sequential calls, %.2f s total, %.3f s mean, %.3f s slowest, " +
                             "%.0f s of audio → RTF %.0fx",
                     phases.asrCalls, phases.asrTotal, phases.asrTotal / Double(max(phases.asrCalls, 1)),
                     phases.asrSlowest, phases.asrAudio, phases.asrAudio / max(phases.asrTotal, 0.001)))
        print(String(format: "SCALE_PROBE asr batched counterfactual: same %.0f s of audio in %d calls of ≤60 s " +
                             "→ %.2f s instead of %.2f s (%.1fx faster; %.0f s of the wait is per-call overhead)",
                     phases.asrAudio, phases.batchedCalls, phases.batchedTotal, phases.asrTotal,
                     phases.asrTotal / max(phases.batchedTotal, 0.001),
                     phases.asrTotal - phases.batchedTotal))
        print(String(format: "SCALE_PROBE asr fixed cost per call ≈ %.0f ms (measured: (%.1f s − %.1f s) / %d calls)",
                     1000 * (phases.asrTotal - phases.batchedTotal) / Double(max(phases.asrCalls, 1)),
                     phases.asrTotal, phases.batchedTotal, phases.asrCalls))
        let accounted = phases.micVad + phases.systemVad + phases.compaction
            + phases.diarization + phases.asrTotal
        print(String(format: "SCALE_PROBE breakdown of the %.1f s wait (attributed over %.1f s of re-run phases): " +
                             "asr %.0f %%, diarization %.0f %%, vad %.0f %%",
                     processDuration, accounted,
                     100 * phases.asrTotal / accounted,
                     100 * phases.diarization / accounted,
                     100 * (phases.micVad + phases.systemVad) / accounted))

        // MARK: - Assertions
        //
        // The bounds below are what a menu-bar app needs, not what this code
        // happens to deliver. The real target is a 60-minute meeting; every cost
        // here is linear in length, so the 30-minute probe gets half the budget.

        // (a) The transcript is plausible: roughly one segment per turn, both
        //     tracks present, both remote voices kept apart. Catches degeneration
        //     at length (lost tail, collapsed speakers), as opposed to slowness.
        XCTAssertGreaterThan(segments.count, turnIndex / 2,
                             "Zu wenige Segmente für \(turnIndex) Redebeiträge — die Pipeline verliert Inhalt bei Länge")
        XCTAssertLessThan(segments.count, turnIndex * 3,
                          "Segmentzahl explodiert gegenüber \(turnIndex) Redebeiträgen")
        XCTAssertTrue(speakers.contains("Ich"), "Mikrofonspur fehlt im Transkript")
        XCTAssertGreaterThanOrEqual(
            speakers.filter { $0.hasPrefix("Sprecher") }.count, 2,
            "Diarisierung kollabiert über 30 Minuten: \(speakers.sorted())"
        )

        // (b) The wait after stop(). The status line says "Verarbeite Aufnahme…"
        //     and there is no progress indicator; on top of this comes the
        //     summarization round trip. A 60-minute meeting must produce its note
        //     inside a minute → the 30-minute probe inside 30 s.
        // Gemessen gerissen: 79 % der Wartezeit sind ASR, und davon sind ~34 s
        // reiner Fixkosten-Overhead (88 ms pro Aufruf × ~390 Aufrufe), weil
        // Parakeet jeden Aufruf auf 15 s paddet. Gruppierung gleicher Sprecher
        // (MeetingPipeline.groupedSpecs) holt nur einen Teil davon — die
        // Redebeiträge wechseln sich ab. Der Rest bräuchte sprecherübergreifendes
        // Bündeln mit Aufteilung per Token-Zeitstempel; bewusst offen.
        XCTExpectFailure("Bekannt: ASR-Fixkosten pro Segment, siehe SCALE_PROBE-Aufschlüsselung.") {
            XCTAssertLessThan(
                processDuration, 30,
                "Wartezeit nach stop() für 30 min Meeting: \(Int(processDuration)) s " +
                "→ hochgerechnet \(Int(processDuration * 2)) s für 60 min. Budget: 30 s / 60 s."
            )
        }

        // (c) Peak memory. Both raw tracks live as [Float] in RAM (16000 · 4 B/s
        //     per track ≈ 110 MB per 30 min per track), and on top of that the
        //     diarizer is handed the whole compacted speech track at once — the
        //     memory curve above shows the peak inside diarization, not in the ASR
        //     loop (which is flat). On the 16 GB machine this app is built for,
        //     sharing RAM with the video call it just recorded, an hour-long
        //     meeting must stay clear of half a gigabyte → the 30-minute probe
        //     must stay under ~380 MB, since both terms are linear in length.
        // Ebenfalls gerissen. Die Kurve zeigt: der Peak liegt IN der Diarisierung
        // (ein Vorab-Spike, danach ist die ASR-Schleife flach) — plus beide
        // Rohspuren, die als [Float] im RAM liegen, obwohl dieselben PCM-Daten
        // bereits im Spool auf der Platte stehen. Kein Leck, keine Akkumulation.
        XCTExpectFailure("Bekannt: Diarisierungs-Spike + beide Rohspuren doppelt im RAM (Spool).") {
            XCTAssertLessThan(
                Self.mb(peak), 380,
                "Spitzenspeicher für 30 min: \(Int(Self.mb(peak))) MB " +
                "→ hochgerechnet \(Int(Self.mb(peak) + Self.mb(trackBytes * 2))) MB für 60 min."
            )
        }
    }

    // MARK: - Phase attribution

    private struct Phases {
        var micVad: TimeInterval = 0
        var micRegions = 0
        var systemVad: TimeInterval = 0
        var systemRegions = 0
        var compaction: TimeInterval = 0
        var compactSeconds: Double = 0
        var diarizerModelLoad: TimeInterval = 0
        var diarization: TimeInterval = 0
        var diarizedSegments = 0
        var diarizedSpeakers = 0
        var asrCalls = 0
        var asrTotal: TimeInterval = 0
        var asrAudio: Double = 0
        var asrSlowest: TimeInterval = 0
        /// Counterfactual: the same audio through few long calls instead of
        /// many short ones. Isolates the fixed per-call cost of Parakeet.
        var batchedCalls = 0
        var batchedTotal: TimeInterval = 0
    }

    /// Re-runs the pipeline's phases with timers around each. Mirrors
    /// MeetingPipeline.process step for step.
    private func measurePhases(
        mic: [Float],
        system: [Float],
        transcriber: ParakeetTranscriber
    ) async throws -> Phases {
        let sampleRate = Self.sampleRate
        var phases = Phases()

        var started = Date()
        let micSpeech = try await VadManager().segmentSpeech(mic)
        phases.micVad = Date().timeIntervalSince(started)
        phases.micRegions = micSpeech.count

        started = Date()
        let systemSpeech = try await VadManager().segmentSpeech(system)
        phases.systemVad = Date().timeIntervalSince(started)
        phases.systemRegions = systemSpeech.count

        started = Date()
        var compact: [Float] = []
        var regions: [MeetingPipeline.SpeechRegion] = []
        let padding = [Float](repeating: 0,
                              count: Int(MeetingPipeline.compactionPadding * Double(sampleRate)))
        for segment in systemSpeech {
            let from = max(0, min(Int(segment.startTime * Double(sampleRate)), system.count))
            let to = max(from, min(Int(segment.endTime * Double(sampleRate)), system.count))
            guard to > from else { continue }
            if !compact.isEmpty { compact += padding }
            regions.append(MeetingPipeline.SpeechRegion(
                compactStart: Double(compact.count) / Double(sampleRate),
                originalStart: segment.startTime,
                duration: Double(to - from) / Double(sampleRate)
            ))
            compact += system[from..<to]
        }
        phases.compaction = Date().timeIntervalSince(started)
        phases.compactSeconds = Double(compact.count) / Double(sampleRate)

        started = Date()
        let models = try await DiarizerModels.downloadIfNeeded()
        phases.diarizerModelLoad = Date().timeIntervalSince(started)
        let diarizer = DiarizerManager()
        diarizer.initialize(models: models)
        let result = try diarizer.performCompleteDiarization(compact, sampleRate: sampleRate)
        diarizer.cleanup()
        phases.diarization = Date().timeIntervalSince(started)
        phases.diarizedSegments = result.segments.count
        phases.diarizedSpeakers = Set(result.segments.map(\.speakerId)).count

        let systemSegments = result.segments.flatMap { segment in
            MeetingPipeline.mapToOriginal(
                start: TimeInterval(segment.startTimeSeconds),
                end: TimeInterval(segment.endTimeSeconds),
                regions: regions
            ).map { (segment.speakerId, $0.start, $0.end) }
        }
        let specs = MeetingPipeline.orderedSpecs(
            micSegments: micSpeech.map { ($0.startTime, $0.endTime) },
            systemSegments: systemSegments
        )

        for spec in specs where spec.end - spec.start >= MeetingPipeline.minimumSegmentDuration {
            let source = spec.track == .microphone ? mic : system
            let startIndex = max(0, min(Int(spec.start * Double(sampleRate)), source.count))
            let endIndex = max(startIndex, min(Int(spec.end * Double(sampleRate)), source.count))
            guard endIndex > startIndex else { continue }
            let slice = Array(source[startIndex..<endIndex])
            let callStart = Date()
            _ = try await transcriber.transcribe(samples: slice, sampleRate: sampleRate)
            let elapsed = Date().timeIntervalSince(callStart)
            phases.asrCalls += 1
            phases.asrTotal += elapsed
            phases.asrSlowest = max(phases.asrSlowest, elapsed)
            phases.asrAudio += Double(slice.count) / Double(sampleRate)
        }

        // Same audio, same order, but glued into ≤ 60 s chunks. If this is much
        // faster than the loop above, the wait is dominated by per-call overhead
        // rather than by decoding — i.e. the fix is batching, not a faster model.
        var chunk: [Float] = []
        let chunkLimit = 60 * sampleRate
        var chunks: [[Float]] = []
        for spec in specs where spec.end - spec.start >= MeetingPipeline.minimumSegmentDuration {
            let source = spec.track == .microphone ? mic : system
            let startIndex = max(0, min(Int(spec.start * Double(sampleRate)), source.count))
            let endIndex = max(startIndex, min(Int(spec.end * Double(sampleRate)), source.count))
            guard endIndex > startIndex else { continue }
            if chunk.count + (endIndex - startIndex) > chunkLimit, !chunk.isEmpty {
                chunks.append(chunk)
                chunk = []
            }
            chunk += source[startIndex..<endIndex]
        }
        if !chunk.isEmpty { chunks.append(chunk) }

        let batchStart = Date()
        for chunk in chunks {
            _ = try await transcriber.transcribe(samples: chunk, sampleRate: sampleRate)
        }
        phases.batchedTotal = Date().timeIntervalSince(batchStart)
        phases.batchedCalls = chunks.count

        return phases
    }
}
