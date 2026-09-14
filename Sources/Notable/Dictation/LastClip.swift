import Foundation

/// The dictation that did not make it (Spec 30 §3.7).
///
/// Dictation audio used to exist only as a `[Float]` inside the task that
/// transcribed it. A missing model, a failed transcription or a blocked paste
/// ended that task — and the dictation with it. Wispr Flow keeps failed
/// dictations in its history and lets them be retried; this is the local
/// equivalent, deliberately smaller: **one** failed clip, the most recent one,
/// until the next failure replaces it or a retry succeeds.
struct LastClip: Codable, Equatable, Sendable {
    var recordedAt: Date
    var duration: TimeInterval
    /// What went wrong, in the words the user was shown.
    var failure: String
    var targetBundleID: String?
    /// The transcript, when one exists — a blocked paste or a changed target
    /// failed *after* the words were there, and retrying those should not need
    /// the recognizer again.
    var text: String?
}

/// Where the clip lives and how it gets there.
///
/// Every recording that goes to transcription is stashed first as
/// `pending-<generation>.i16`, so two jobs in flight (Spec 29) never write the
/// same file. Success deletes the job's own stash; failure renames it to
/// `last.i16` next to `last.json`, replacing whatever failed before. Stashes a
/// crash left behind are removed at launch — they belong to dictations whose
/// outcome nobody is waiting for any more.
///
/// Int16 through `SpoolAudio`, the same format meetings spool in: 32 KB/s, a
/// minute of dictation under 2 MB. It is not a posten in `StorageFootprint` and
/// no retention rule touches it — its lifetime is in its name.
enum LastClipStore {
    static var directory: URL {
        ModelInventory.applicationRoot.appendingPathComponent("spool-dictation", isDirectory: true)
    }

    static func pendingURL(_ generation: Int, in directory: URL = directory) -> URL {
        directory.appendingPathComponent("pending-\(generation).\(SpoolAudio.Format.int16.fileExtension)")
    }

    static func audioURL(in directory: URL = directory) -> URL {
        directory.appendingPathComponent("last.\(SpoolAudio.Format.int16.fileExtension)")
    }

    static func metaURL(in directory: URL = directory) -> URL {
        directory.appendingPathComponent("last.json")
    }

    /// Writes a recording before it is transcribed. Throws only for disk
    /// errors; the caller logs and carries on — a dictation must never fail
    /// because its safety copy could not be written.
    static func stash(_ samples: [Float], generation: Int, in directory: URL = directory) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var scratch: [Int16] = []
        let data = samples.withUnsafeBufferPointer {
            SpoolAudio.encode($0, as: .int16, scratch: &scratch)
        }
        try data.write(to: pendingURL(generation, in: directory), options: .atomic)
    }

    /// The job succeeded or was cancelled on purpose: its stash goes.
    static func discard(generation: Int, in directory: URL = directory) {
        try? FileManager.default.removeItem(at: pendingURL(generation, in: directory))
    }

    /// The job failed: its stash becomes the last clip.
    ///
    /// Meta is written after the audio is in place, so a `last.json` never
    /// points at audio that is not there. Without a stash (it could not be
    /// written) only a clip that carries its text is kept — metadata for audio
    /// that does not exist would offer a retry that cannot work.
    static func keep(_ clip: LastClip, generation: Int, in directory: URL = directory) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let pending = pendingURL(generation, in: directory)
        let audio = audioURL(in: directory)
        let hasAudio = manager.fileExists(atPath: pending.path)
        guard hasAudio || clip.text != nil else { return }

        try? manager.removeItem(at: audio)
        if hasAudio {
            try manager.moveItem(at: pending, to: audio)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(clip).write(to: metaURL(in: directory), options: .atomic)
    }

    /// The waiting clip, if there is one.
    static func pending(in directory: URL = directory) -> LastClip? {
        guard let data = try? Data(contentsOf: metaURL(in: directory)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let clip = try? decoder.decode(LastClip.self, from: data) else { return nil }
        let audioExists = FileManager.default.fileExists(atPath: audioURL(in: directory).path)
        return audioExists || clip.text != nil ? clip : nil
    }

    /// The waiting clip's audio; empty when only its text was kept.
    static func samples(in directory: URL = directory) -> [Float] {
        SpoolAudio.read(audioURL(in: directory))
    }

    /// Retried successfully, or dismissed.
    static func clear(in directory: URL = directory) {
        try? FileManager.default.removeItem(at: audioURL(in: directory))
        try? FileManager.default.removeItem(at: metaURL(in: directory))
    }

    /// Removes stashes of jobs that never finished — a crash or a quit mid-job.
    static func removeStrayStashes(in directory: URL = directory) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where name.hasPrefix("pending-") {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }
}
