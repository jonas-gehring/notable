import AVFoundation
import Combine
import Foundation

/// Five seconds of "Sprecher 2" (Spec 36 §3.2, Spec 24 §8.3).
///
/// The speaker dialog shows a name, a number of turns and a duration — and
/// nobody can tell **who** "Sprecher 2" is. Whoever corrects a name today has to
/// remember the meeting. So the dialog gets an ear: the loudest passage of that
/// cluster, at most five seconds, out of the archived track.
///
/// The loudest, not the first: the first turn of a cluster is regularly "Mhm."
/// or half a word the VAD caught, and a sample that says nothing is worse than
/// none — it costs a click and leaves the question open.
///
/// The pure halves (picking the window, finding the archived session) are here
/// and tested; the reading and playing sit in ``SpeakerSamplePlayer``.
enum SpeakerSample {
    static let maximumSeconds: TimeInterval = 5

    struct Window: Equatable, Sendable {
        var start: TimeInterval
        var end: TimeInterval

        var duration: TimeInterval { max(0, end - start) }
    }

    /// The loudest window of at most `length` seconds inside the cluster's
    /// segments.
    ///
    /// - Parameter loudness: RMS of the track between two times. Injected, so
    ///   the choice is testable without audio.
    static func loudest(
        in segments: [(start: TimeInterval, end: TimeInterval)],
        length: TimeInterval = maximumSeconds,
        loudness: (TimeInterval, TimeInterval) -> Float
    ) -> Window? {
        var best: (window: Window, level: Float)?
        for segment in segments where segment.end > segment.start {
            var windows: [Window] = []
            if segment.end - segment.start <= length {
                windows = [Window(start: segment.start, end: segment.end)]
            } else {
                // Half-window steps: a loud passage straddling a boundary is
                // still caught whole by the neighbouring window.
                var start = segment.start
                while start < segment.end {
                    windows.append(Window(start: start, end: min(start + length, segment.end)))
                    start += length / 2
                }
            }
            for window in windows where window.duration > 0 {
                let level = loudness(window.start, window.end)
                if best == nil || level > best!.level { best = (window, level) }
            }
        }
        return best?.window
    }

    /// Root-mean-square of a slice, the measure the whole app judges level by.
    static func rms(_ samples: [Float], from start: Int, to end: Int) -> Float {
        let lower = max(0, min(start, samples.count))
        let upper = max(lower, min(end, samples.count))
        guard upper > lower else { return 0 }
        var sum: Float = 0
        for index in lower ..< upper { sum += samples[index] * samples[index] }
        return (sum / Float(upper - lower)).squareRoot()
    }

    /// One candidate from `spool-archive`.
    struct ArchivedSession: Equatable, Sendable {
        var directory: URL
        var startedAt: Date
        /// What ``SpoolStore/markNoteWritten(_:noteURL:)`` recorded.
        var notePath: String?
    }

    /// Which archived session belongs to a recording.
    ///
    /// The spool's directory is a UUID of its own and no column links the two,
    /// so the join is the start instant — `produceNote` stamps the same `Date`
    /// into the recording row and into `meta.json`. The note path is the
    /// tie-breaker for the case that two recordings started in the same second;
    /// it is only *a* tie-breaker, because a note that was renamed afterwards no
    /// longer carries the path the marker holds.
    static func session(
        startedAt: Date,
        markdownPath: String?,
        in candidates: [ArchivedSession],
        tolerance: TimeInterval = 2
    ) -> URL? {
        let near = candidates.filter { abs($0.startedAt.timeIntervalSince(startedAt)) <= tolerance }
        if near.count > 1, let path = markdownPath, let exact = near.first(where: { $0.notePath == path }) {
            return exact.directory
        }
        return near.min { abs($0.startedAt.timeIntervalSince(startedAt)) < abs($1.startedAt.timeIntervalSince(startedAt)) }?
            .directory
    }

    /// Which track a cluster was recorded on: the local user is the microphone,
    /// everyone else is the system tap.
    static func track(for cluster: String) -> SpoolStore.Track {
        cluster == SpeakerNameResolver.micSpeakerLabel ? .mic : .system
    }
}

/// Plays one speaker's sample. `@MainActor` — it is a button's state.
@MainActor
final class SpeakerSamplePlayer: ObservableObject {
    /// The cluster currently sounding, for the button's symbol.
    @Published private(set) var playing: String?
    @Published private(set) var failure: String?
    /// Nil when the archive no longer holds this meeting — retention deleted it,
    /// or the meeting predates the archive. The button is then disabled and says
    /// so, rather than doing nothing.
    @Published private(set) var archive: URL?
    @Published private(set) var isSearching = true

    private var player: AVAudioPlayer?
    private var temporaryFile: URL?

    deinit {
        if let temporaryFile { try? FileManager.default.removeItem(at: temporaryFile) }
    }

    /// Looks for the recording's archived session. Cheap: a directory listing
    /// and one small JSON per session.
    func prepare(for recording: RecordingStore.Recording) async {
        let startedAt = recording.startedAt
        let path = recording.markdownPath
        let found = await Task.detached(priority: .utility) { () -> URL? in
            let candidates = SpoolStore.archived().map { entry in
                SpeakerSample.ArchivedSession(
                    directory: entry.session.directory,
                    startedAt: entry.meta.startedAt,
                    notePath: SpoolStore.noteWrittenPath(entry.session)
                )
            }
            return SpeakerSample.session(startedAt: startedAt, markdownPath: path, in: candidates)
        }.value
        archive = found
        isSearching = false
    }

    /// Reads the track, picks the loudest passage of this cluster and plays it.
    ///
    /// The whole track is decoded for it — an hour of speech is ~115 MB as
    /// Int16 — because the loudest passage may sit anywhere in it and the
    /// cluster's turns are spread over the whole meeting. It is a deliberate,
    /// one-off action on a personal machine, and nothing is kept afterwards.
    func play(cluster: String, segments: [(start: TimeInterval, end: TimeInterval)]) {
        guard let archive else { return }
        stop()
        failure = nil
        let track = SpeakerSample.track(for: cluster)
        let session = SpoolStore.Session(directory: archive)
        guard let source = session.recordedURL(track) else {
            failure = String(localized: "Audio nicht mehr vorhanden")
            return
        }
        playing = cluster
        Task {
            let prepared = await Task.detached(priority: .userInitiated) { () -> URL? in
                Self.clip(from: source, segments: segments)
            }.value
            guard playing == cluster else { return }
            guard let prepared else {
                failure = String(localized: "Audio nicht mehr vorhanden")
                playing = nil
                return
            }
            do {
                let player = try AVAudioPlayer(contentsOf: prepared)
                self.player = player
                temporaryFile = prepared
                player.play()
                // No delegate: the only thing the end of a five-second sample
                // changes is the symbol on the button.
                let seconds = player.duration
                try? await Task.sleep(for: .seconds(seconds))
                if playing == cluster { playing = nil }
            } catch {
                failure = error.localizedDescription
                playing = nil
            }
        }
    }

    func stop() {
        player?.stop()
        player = nil
        playing = nil
        if let temporaryFile { try? FileManager.default.removeItem(at: temporaryFile) }
        temporaryFile = nil
    }

    /// Off the main actor: read, pick, write a small WAV to play from.
    private nonisolated static func clip(
        from source: URL, segments: [(start: TimeInterval, end: TimeInterval)]
    ) -> URL? {
        let rate = Double(PCMDownsampler.targetSampleRate)
        let samples = SpoolAudio.read(source)
        guard !samples.isEmpty else { return nil }
        let window = SpeakerSample.loudest(in: segments) { start, end in
            SpeakerSample.rms(samples, from: Int(start * rate), to: Int(end * rate))
        }
        guard let window else { return nil }
        let from = max(0, min(Int(window.start * rate), samples.count))
        let to = max(from, min(Int(window.end * rate), samples.count))
        guard to > from else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("notable-speaker-\(UUID().uuidString).wav")
        do {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: rate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
            ]
            let file = try AVAudioFile(forWriting: url, settings: settings,
                                       commonFormat: .pcmFormatInt16, interleaved: true)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                frameCapacity: AVAudioFrameCount(to - from)),
                  let channel = buffer.int16ChannelData else { return nil }
            for index in from ..< to { channel[0][index - from] = SpoolAudio.encode(samples[index]) }
            buffer.frameLength = AVAudioFrameCount(to - from)
            try file.write(from: buffer)
            return url
        } catch {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
    }
}
