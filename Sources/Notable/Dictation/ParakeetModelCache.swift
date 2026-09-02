import FluidAudio
import Foundation

/// One process-wide Parakeet v3 instance. Dictation and meeting processing
/// both need it, and each `ParakeetTranscriber.prepare()` loads its own full
/// copy of the CoreML weights — a meeting used to double the app's resident
/// memory for the duration of processing. Concurrent callers share the one
/// in-flight load instead of racing `AsrModels.downloadAndLoad()` on the
/// same cache directory.
actor ParakeetModelCache {
    static let shared = ParakeetModelCache()

    private var task: Task<ParakeetTranscriber, Error>?
    /// One observer, deliberately. Dictation and meeting processing share this
    /// cache, so a per-caller handler would report the same download twice and
    /// the progress would jump about.
    private var progressObserver: (@Sendable (Double) -> Void)?

    func setProgressObserver(_ observer: (@Sendable (Double) -> Void)?) {
        progressObserver = observer
    }

    func transcriber() async throws -> ParakeetTranscriber {
        if let task {
            do {
                return try await task.value
            } catch {
                // A failed load must not be cached — the next attempt
                // (e.g. after the network came back) has to retry.
                if self.task == task { self.task = nil }
                throw error
            }
        }
        // Built here, once, so the in-flight load reports to exactly one place.
        var handler: ProgressHandler?
        if let observer = progressObserver {
            handler = { progress in observer(progress.fractionCompleted) }
        }
        let progress = handler
        let task = Task<ParakeetTranscriber, Error> {
            let transcriber = ParakeetTranscriber()
            try await transcriber.prepare(progress: progress)
            return transcriber
        }
        self.task = task
        do {
            return try await task.value
        } catch {
            if self.task == task { self.task = nil }
            throw error
        }
    }
}
