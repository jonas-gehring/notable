import FluidAudio
import Foundation

/// What Notable has downloaded onto the disk, and what state each of it is in.
///
/// The models are by a wide margin the largest thing Notable puts on the disk —
/// 1,1 GB when this was written — and until now they appeared nowhere in the
/// app: not in the storage pane, not in an error, nowhere. Nothing checked them
/// either, and nothing ever removed one, so an aborted download stayed forever
/// and a directory FluidAudio renamed between two versions stayed next to its
/// replacement, byte for byte.
///
/// **Which name is current is a list, not a pattern.** The list is FluidAudio's
/// own (`Repo.folderName`, `ModelNames.*.requiredModels`), so a rename in the
/// library moves "current" along with it and the old directory becomes orphaned
/// by itself — which is exactly what happened to `silero-vad-coreml` and
/// `speaker-diarization-coreml`. Guessing from a pattern would be the wrong
/// failure mode: it would eventually delete a model that is in use.
enum ModelInventory {
    enum State: Sendable, Equatable {
        /// Needed by the current engine or by the meeting pipeline.
        case inUse
        /// Complete, but nothing currently selected needs it.
        case available
        /// The directory is there, files it must contain are not.
        case incomplete
        /// No code path knows this name any more.
        case orphaned

        /// Whether removing it is offered. Never for something in use, and
        /// never automatically — see ``removable(in:)``.
        var isRemovable: Bool { self == .orphaned || self == .incomplete }

        var label: String {
            let key: String.LocalizationValue = switch self {
            case .inUse: "in Benutzung"
            case .available: "vorhanden, nicht gewählt"
            case .incomplete: "unvollständig"
            case .orphaned: "verwaist"
            }
            return String(localized: key)
        }
    }

    struct Entry: Identifiable, Sendable, Equatable {
        let name: String
        let url: URL
        let bytes: Int64
        let state: State
        /// The required files that were missing, for an `.incomplete` entry.
        let missing: [String]

        var id: String { url.path }
    }

    /// One model Notable knows by name — directory, label, and the files that
    /// have to be inside it for it to count as complete.
    struct Known: Sendable, Equatable {
        let directory: String
        let name: String
        let requiredFiles: Set<String>
    }

    // MARK: - The scan

    /// Classifies every directory under `root`. Pure: hand it a directory and a
    /// list of known names and it answers without asking anything else, which
    /// is what makes it testable without a gigabyte of weights on disk.
    static func scan(
        root: URL,
        known: [Known],
        inUse: Set<String>,
        fileManager: FileManager = .default
    ) -> [Entry] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [] }

        let byDirectory = Dictionary(known.map { ($0.directory, $0) }, uniquingKeysWith: { first, _ in first })

        return entries
            .filter { isModelDirectory($0) }
            .map { url -> Entry in
                let directory = url.lastPathComponent
                let bytes = SpoolInventory.size(of: url, fileManager: fileManager)
                guard let model = byDirectory[directory] else {
                    return Entry(name: directory, url: url, bytes: bytes, state: .orphaned, missing: [])
                }
                let present = Set((try? fileManager.contentsOfDirectory(atPath: url.path)) ?? [])
                let missing = model.requiredFiles.subtracting(present).sorted()
                let state: State = missing.isEmpty
                    ? (inUse.contains(directory) ? .inUse : .available)
                    : .incomplete
                return Entry(name: model.name, url: url, bytes: bytes, state: state, missing: missing)
            }
            .sorted { ($0.state.order, -$0.bytes) < ($1.state.order, -$1.bytes) }
    }

    /// Whisper's cache has no manifest to check against, so its entries are
    /// never `.incomplete` — an unverifiable claim is worse than none.
    ///
    /// The layout is WhisperKit's: `<base>/models/argmaxinc/whisperkit-coreml/openai_whisper-<size>`.
    static func scanWhisper(
        root: URL,
        inUse: Set<String>,
        fileManager: FileManager = .default
    ) -> [Entry] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [] }

        return entries
            .filter { isModelDirectory($0) }
            .map { url in
                let directory = url.lastPathComponent
                let size = WhisperModelSize.allCases.first { directory == whisperDirectory(for: $0) }
                return Entry(
                    // "Whisper base" is the model's name in every language.
                    name: size.map { "Whisper \($0.rawValue)" } ?? directory,
                    url: url,
                    bytes: SpoolInventory.size(of: url, fileManager: fileManager),
                    state: size == nil ? .orphaned : (inUse.contains(directory) ? .inUse : .available),
                    missing: []
                )
            }
            .sorted { ($0.state.order, -$0.bytes) < ($1.state.order, -$1.bytes) }
    }

    /// A directory, and not a hidden one. WhisperKit keeps a `.cache` folder
    /// next to its models; listing that as a model — and then offering to
    /// delete it as orphaned — would be confidently wrong about something the
    /// library owns.
    private static func isModelDirectory(_ url: URL) -> Bool {
        guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return false }
        return !url.lastPathComponent.hasPrefix(".")
    }

    // MARK: - Removal

    struct Removal: Sendable, Equatable {
        var entries: [Entry] = []

        var isEmpty: Bool { entries.isEmpty }
        var bytes: Int64 { entries.reduce(0) { $0 + $1.bytes } }
    }

    /// What could be freed. Nothing here happens without a confirmation: a
    /// gigabyte deleted unasked is irreversible, for the same reason the
    /// retention sweep is opt-in.
    static func removable(in entries: [Entry]) -> Removal {
        Removal(entries: entries.filter { $0.state.isRemovable })
    }

    /// Deletes the directories in a plan. Returns what could not be removed,
    /// in the user's language — a cleanup that silently does nothing is the
    /// failure mode this app has already paid for once.
    @discardableResult
    static func remove(_ plan: Removal, fileManager: FileManager = .default) -> [String] {
        plan.entries.compactMap { entry in
            do {
                try fileManager.removeItem(at: entry.url)
                return nil
            } catch {
                return "\(entry.name): \(error.localizedDescription)"
            }
        }
    }

    /// Removes the directory of a model that is present but missing files it
    /// must contain, so the next load downloads it again.
    ///
    /// A half-downloaded model "exists" as far as FluidAudio's presence check
    /// is concerned (`AsrModels.modelsExist` asks about presence, not
    /// completeness), so "erneut versuchen" used to re-read the same broken
    /// slot forever and the only way out was to delete the app. This removes
    /// **only** a directory the inventory calls `incomplete` — a known name
    /// with named files missing — and only the one belonging to the engine
    /// being retried.
    @discardableResult
    static func discardIncomplete(for engine: ASREngineID, root: URL = modelsRoot) -> [String] {
        let directories: [String]
        switch engine {
        case .parakeetV3: directories = [Repo.parakeetV3.folderName]
        case .unifiedEnglish: directories = [Repo.parakeetUnified.folderName]
        // Whisper has no manifest, so it is never provably incomplete and
        // nothing here may delete it. See ``scanWhisper``.
        case .whisper: return []
        }
        let broken = scan(
            root: root, known: knownModels, inUse: inUseDirectories(engine: engine)
        ).filter { $0.state == .incomplete && directories.contains($0.url.lastPathComponent) }
        guard !broken.isEmpty else { return [] }
        _ = remove(Removal(entries: broken))
        return broken.map(\.name)
    }

    // MARK: - The live inventory

    // MARK: - Where the models live

    /// `~/Library/Application Support/Notable`.
    ///
    /// Everything Notable puts on the disk lives under here. That was not true
    /// for the models: FluidAudio's `defaultModelsDirectory()` decides on
    /// `Application Support/FluidAudio/Models`, and Notable simply never passed
    /// a destination — although every one of the four load calls takes one. So
    /// the largest thing the app wrote to disk sat in a folder named after a
    /// library the user has never heard of. See ``ModelStorageMigration``.
    static var applicationRoot: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Notable", isDirectory: true)
    }

    /// `…/Notable/Models` — the directory that holds one folder per model.
    static var modelsRoot: URL { applicationRoot.appendingPathComponent("Models", isDirectory: true) }

    /// One model's own directory.
    ///
    /// **The four FluidAudio entry points want three different levels**, which
    /// is worth writing down once rather than rediscovering at each call site:
    /// `AsrModels.downloadAndLoad(to:)` and `DiarizerModels.downloadIfNeeded(to:)`
    /// want *this* (the model's own folder), `StreamingUnifiedAsrManager.loadModels(to:)`
    /// wants ``modelsRoot`` and appends the folder itself, and
    /// `VadManager(modelDirectory:)` wants ``applicationRoot`` and appends
    /// `"Models"` itself.
    static func directory(_ repo: Repo) -> URL {
        modelsRoot.appendingPathComponent(repo.folderName, isDirectory: true)
    }

    /// Where FluidAudio put the models before Notable started telling it where
    /// to put them: `~/Library/Application Support/FluidAudio/Models`.
    ///
    /// Nothing reads this any more. It is still scanned, so that whatever the
    /// migration could not move stays visible and removable instead of turning
    /// into a gigabyte nobody can see — which is the exact failure this whole
    /// spec is about.
    static var legacyRoot: URL { MLModelConfigurationUtils.defaultModelsDirectory() }

    /// Where Notable tells WhisperKit to keep its models.
    ///
    /// WhisperKit's own default is `~/Documents/huggingface` — the user's
    /// Documents folder, which on macOS is behind its own TCC prompt and is the
    /// folder most likely to be synced to a cloud drive. Neither is a place for
    /// a gigabyte of model weights, and a settings page that triggers a
    /// Documents permission dialog just to count them would be worse still.
    static var whisperDownloadBase: URL { modelsRoot }

    static var whisperRoot: URL {
        whisperDownloadBase
            .appendingPathComponent("models/argmaxinc/whisperkit-coreml", isDirectory: true)
    }

    static func whisperDirectory(for size: WhisperModelSize) -> String {
        "openai_whisper-\(size.modelName)"
    }

    /// The models Notable itself asks FluidAudio for. Must be revisited
    /// whenever the package version moves — same rule as the API prices next to
    /// `model` in the summarization provider.
    static var knownModels: [Known] {
        [
            Known(
                directory: Repo.parakeetV3.folderName,
                name: String(localized: "Parakeet TDT v3 — Diktat und Meetings"),
                requiredFiles: ModelNames.ASR.requiredModelsV3()
            ),
            Known(
                directory: Repo.parakeetUnified.folderName,
                name: String(localized: "Parakeet Unified — Englisch, Streaming"),
                requiredFiles: ModelNames.ParakeetUnified.requiredModels(variant: nil)
            ),
            Known(
                directory: Repo.diarizer.folderName,
                name: String(localized: "Sprechertrennung"),
                requiredFiles: ModelNames.Diarizer.requiredModels
            ),
            Known(
                directory: Repo.vad.folderName,
                name: String(localized: "Spracherkennung im Audiosignal (VAD)"),
                requiredFiles: ModelNames.VAD.requiredModels
            ),
        ]
    }

    /// Everything the currently selected engine and the meeting pipeline need.
    ///
    /// Parakeet v3 is always in use even when dictation runs on something else:
    /// the meeting pipeline is on it unconditionally.
    static func inUseDirectories(engine: ASREngineID = .current) -> Set<String> {
        var names: Set<String> = [
            Repo.parakeetV3.folderName,
            Repo.diarizer.folderName,
            Repo.vad.folderName,
        ]
        if engine == .unifiedEnglish { names.insert(Repo.parakeetUnified.folderName) }
        return names
    }

    /// Everything on disk, both roots. Walks directories, so it belongs on a
    /// background task.
    static func current(engine: ASREngineID = .current) -> [Entry] {
        let whisperInUse: Set<String> = engine == .whisper
            ? [whisperDirectory(for: .current)]
            : []
        return scan(root: modelsRoot, known: knownModels, inUse: inUseDirectories(engine: engine))
            // With no known names, every directory in the old root comes back
            // orphaned — which is exactly what it is: nothing loads from there.
            + scan(root: legacyRoot, known: [], inUse: [])
            + scanWhisper(root: whisperRoot, inUse: whisperInUse)
    }
}

private extension ModelInventory.State {
    /// Display order: what matters first, what can go last.
    var order: Int {
        switch self {
        case .inUse: 0
        case .available: 1
        case .incomplete: 2
        case .orphaned: 3
        }
    }
}
