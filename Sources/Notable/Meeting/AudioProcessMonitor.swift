import CoreAudio
import Foundation

/// Who is *currently* using audio, per process.
///
/// This is the signal that makes "the call ended" measurable. The old detector
/// asked "is Zoom running?" — true all day for Teams and Slack, so the end event
/// never fired and an auto-started recording ran until it was stopped by hand.
/// A per-process input flag instead means "Teams has the microphone open right
/// now", and it stays valid *while we record*, because our own capture lives in a
/// different process (filtered out by PID) rather than in the same global
/// "someone is using the mic" bit.
///
/// The snapshot type is pure so the priority rules can be unit-tested without
/// CoreAudio; only `AudioProcessMonitor.snapshot()` touches the hardware.
struct AudioProcessSnapshot: Sendable, Equatable {
    struct Entry: Sendable, Equatable {
        var pid: pid_t
        var bundleID: String?
        var isRunningInput: Bool
        var isRunningOutput: Bool

        /// Any live stream — used for the *end* signal. Muting can release the
        /// microphone while the remote side keeps playing, and that is still a
        /// running call.
        var isActive: Bool { isRunningInput || isRunningOutput }
    }

    var entries: [Entry]
    /// False when CoreAudio returned nothing at all (API error). Callers must
    /// then fall back to the legacy heuristic instead of concluding "no call".
    var isAvailable: Bool

    static let unavailable = AudioProcessSnapshot(entries: [], isAvailable: false)

    /// The first entry for a bundle id that has the microphone open.
    ///
    /// Matching is by prefix on purpose: Electron and Chromium apps do their
    /// audio in helper processes (`com.google.Chrome.helper`,
    /// `com.microsoft.teams2.helper`), and those are the processes that actually
    /// hold the streams. An exact match would see nothing at all for Chrome,
    /// Teams, and Slack — i.e. for most calls.
    func inputEntry(bundleID: String) -> Entry? {
        entries.first { Self.matches($0.bundleID, bundleID) && $0.isRunningInput }
    }

    /// The first bundle id from `bundleIDs` — in the given order, so callers
    /// express priority — that has the microphone open.
    func firstInput(bundleIDs: [String]) -> Entry? {
        for id in bundleIDs {
            if let entry = inputEntry(bundleID: id) { return entry }
        }
        return nil
    }

    /// Microphone check across several process bundle ids — one app's audio may
    /// live under more than one (Safari: `com.apple.Safari` *and*
    /// `com.apple.WebKit`).
    func inputEntry(anyOf bundleIDs: [String]) -> Entry? {
        for id in bundleIDs {
            if let entry = inputEntry(bundleID: id) { return entry }
        }
        return nil
    }

    /// True while the process has *any* stream running. The end signal, kept
    /// deliberately more permissive than the start signal.
    func isActive(bundleID: String) -> Bool {
        entries.contains { Self.matches($0.bundleID, bundleID) && $0.isActive }
    }

    func isActive(anyOf bundleIDs: [String]) -> Bool {
        bundleIDs.contains { isActive(bundleID: $0) }
    }

    static func matches(_ processBundleID: String?, _ appBundleID: String) -> Bool {
        guard let processBundleID else { return false }
        return processBundleID == appBundleID || processBundleID.hasPrefix(appBundleID + ".")
    }
}

/// Reads the CoreAudio process-object list (macOS 14.0+, the same API family
/// `SystemAudioTap` builds its process tap from). Read-only: listing processes
/// and their run flags needs no TCC grant — only *tapping* them does.
enum AudioProcessMonitor {
    static func snapshot(excluding ownPID: pid_t = getpid()) -> AudioProcessSnapshot {
        guard let processIDs = processObjectIDs(), !processIDs.isEmpty else {
            return .unavailable
        }

        var entries: [AudioProcessSnapshot.Entry] = []
        entries.reserveCapacity(processIDs.count)
        for objectID in processIDs {
            let pid = pid(of: objectID) ?? -1
            guard pid != ownPID else { continue }
            let input = flag(objectID, kAudioProcessPropertyIsRunningInput)
            let output = flag(objectID, kAudioProcessPropertyIsRunningOutput)
            // Idle processes are the vast majority; keeping only the live ones
            // makes the snapshot small and the debug output readable.
            guard input || output else { continue }
            entries.append(
                AudioProcessSnapshot.Entry(
                    pid: pid,
                    bundleID: bundleID(of: objectID),
                    isRunningInput: input,
                    isRunningOutput: output
                )
            )
        }
        return AudioProcessSnapshot(entries: entries, isAvailable: true)
    }

    // MARK: - CoreAudio plumbing

    private static func processObjectIDs() -> [AudioObjectID]? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr, size > 0 else { return nil }

        var ids = [AudioObjectID](repeating: AudioObjectID(kAudioObjectUnknown),
                                  count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids
        ) == noErr else { return nil }
        return ids
    }

    private static func flag(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value) == noErr else {
            return false
        }
        return value != 0
    }

    private static func pid(of objectID: AudioObjectID) -> pid_t? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: pid_t = -1
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value
    }

    private static func bundleID(of objectID: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value) == noErr,
              let cf = value?.takeRetainedValue()
        else { return nil }
        let string = cf as String
        return string.isEmpty ? nil : string
    }
}
