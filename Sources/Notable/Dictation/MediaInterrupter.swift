import AppKit
import AudioToolbox
import CoreAudio
import Foundation

/// Silences whatever is playing for the duration of a dictation (Spec 08 B).
///
/// Both switches default to **off**: this reaches outside Notable — into another
/// app's playback and into the system's output volume — and that is not something
/// to do to someone who did not ask.
///
/// **The rule that shapes everything here: only ever undo your own doing.** If
/// nothing was playing, nothing is resumed; if the user muted the Mac himself, it
/// stays muted afterwards. The state is captured before the intervention and
/// compared against, never assumed.
@MainActor
final class MediaInterrupter {
    enum Key {
        static let pausePlayback = "pauseMediaDuringDictation"
        static let muteOutput = "muteSystemAudioDuringDictation"
    }

    /// What this instance actually did, so it can undo exactly that much.
    private var didPause = false
    private var previousVolume: Float32?

    static func isPauseEnabled(_ store: UserDefaults = .standard) -> Bool {
        store.bool(forKey: Key.pausePlayback)
    }

    static func isMuteEnabled(_ store: UserDefaults = .standard) -> Bool {
        store.bool(forKey: Key.muteOutput)
    }

    /// Called when a recording starts.
    func begin(store: UserDefaults = .standard) {
        if Self.isPauseEnabled(store), Self.somethingIsPlaying() {
            Self.sendPlayPauseKey()
            didPause = true
        }
        if Self.isMuteEnabled(store), let volume = Self.outputVolume(), volume > 0 {
            previousVolume = volume
            Self.setOutputVolume(0)
        }
    }

    /// Called when the recording ends — including when it was cancelled.
    func end() {
        if didPause {
            Self.sendPlayPauseKey()
            didPause = false
        }
        if let previousVolume {
            // Only if nothing else changed it in the meantime; the user turning
            // the volume up mid-dictation outranks our restore.
            if Self.outputVolume() == 0 {
                Self.setOutputVolume(previousVolume)
            }
            self.previousVolume = nil
        }
    }

    // MARK: - Playback

    /// Is any app currently playing audio?
    ///
    /// Reuses the per-process CoreAudio flags the meeting detector already relies
    /// on — no new mechanism, and no AppleScript poking at Music or Spotify by
    /// name.
    static func somethingIsPlaying() -> Bool {
        isPlaying(AudioProcessMonitor.snapshot())
    }

    /// Pure half, so the "don't resume what wasn't playing" rule is testable
    /// without CoreAudio. An unavailable snapshot counts as "nothing playing":
    /// pressing play/pause on a guess could just as easily *start* a podcast.
    static func isPlaying(_ snapshot: AudioProcessSnapshot) -> Bool {
        guard snapshot.isAvailable else { return false }
        return snapshot.entries.contains { $0.isRunningOutput }
    }

    /// `NX_KEYTYPE_PLAY` as a system-defined event — the same thing the F8 key
    /// sends, so it reaches whichever app owns playback without Notable needing
    /// to know which one that is.
    static func sendPlayPauseKey() {
        for isDown in [true, false] {
            let data1 = Int((16 << 16) | ((isDown ? 0x0A : 0x0B) << 8))
            guard let event = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: data1,
                data2: -1
            ) else { return }
            event.cgEvent?.post(tap: .cghidEventTap)
        }
    }

    // MARK: - Output volume

    private static var defaultOutputDevice: AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device
        )
        return status == noErr && device != 0 ? device : nil
    }

    private static var volumeAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )

    static func outputVolume() -> Float32? {
        guard let device = defaultOutputDevice else { return nil }
        var volume: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(device, &volumeAddress, 0, nil, &size, &volume)
        return status == noErr ? volume : nil
    }

    static func setOutputVolume(_ volume: Float32) {
        guard let device = defaultOutputDevice else { return }
        var value = max(0, min(1, volume))
        let size = UInt32(MemoryLayout<Float32>.size)
        _ = AudioObjectSetPropertyData(device, &volumeAddress, 0, nil, size, &value)
    }
}
