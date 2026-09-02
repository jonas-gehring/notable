import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation

/// Captures the *other* participants: a global CoreAudio process tap
/// (macOS 14.4+) mixed down and resampled to 16 kHz mono. Requires the
/// "System Audio Recording" permission (NSAudioCaptureUsageDescription);
/// macOS prompts on first use.
final class SystemAudioTap: @unchecked Sendable {
    enum TapError: Error, LocalizedError {
        case osStatus(String, OSStatus)
        case noTapFormat

        var errorDescription: String? {
            switch self {
            case .osStatus(let call, let status):
                "System-Audio-Tap: \(call) fehlgeschlagen (OSStatus \(status)). Fehlt die Berechtigung „Systemaudio-Aufnahme“?"
            case .noTapFormat:
                "System-Audio-Tap: Format nicht lesbar."
            }
        }
    }

    private let downsampler = PCMDownsampler()

    /// Wird gerufen, wenn nach einem Output-Device-Wechsel der Neuaufbau
    /// endgültig scheitert (alle Retries erschöpft): Systemaudio läuft ab
    /// jetzt nicht mehr auf — der Owner muss das sichtbar machen.
    var onRebuildFailure: (@Sendable (Error) -> Void)?

    // Alle veränderlichen Felder sind Main-Queue-confined: der Listener ist
    // auf .main registriert, start()/stop() ruft der Owner vom Main-Actor,
    // Retries laufen über DispatchQueue.main.asyncAfter.
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var tapFormat: AVAudioFormat?
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var isCapturing = false
    private var rebuildInFlight = false

    private static let rebuildAttempts = 3
    private static let rebuildRetryDelay = DispatchTimeInterval.milliseconds(300)

    func start(spoolingTo spoolURL: URL? = nil) throws {
        try downsampler.reset(spoolingTo: spoolURL)
        do {
            try buildCapture()
        } catch {
            _ = downsampler.drain() // close a just-opened spool handle
            throw error
        }
        isCapturing = true
        installDeviceListener()
    }

    /// Builds tap → format → aggregate device → IO proc. Reused after an
    /// output-device change; must NOT touch the downsampler (the recording
    /// continues into the same buffer/spool).
    private func buildCapture() throws {
        // 1. Global tap: mixdown of all processes' output (excluding none).
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.name = "Notable System Audio Tap"
        description.muteBehavior = .unmuted
        description.isPrivate = true

        var tapID = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else {
            throw TapError.osStatus("AudioHardwareCreateProcessTap", status)
        }
        self.tapID = tapID

        // 2. Read the tap's stream format.
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd)
        guard status == noErr, let format = AVAudioFormat(streamDescription: &asbd) else {
            teardown()
            throw status == noErr ? TapError.noTapFormat : TapError.osStatus("kAudioTapPropertyFormat", status)
        }
        tapFormat = format

        // 3. Private aggregate device that carries only the tap.
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Notable-Tap-Aggregate",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[String: Any]](),
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true,
                ]
            ],
        ]
        var aggregateID = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregateID)
        guard status == noErr else {
            teardown()
            throw TapError.osStatus("AudioHardwareCreateAggregateDevice", status)
        }
        self.aggregateID = aggregateID

        // 4. IO proc: input buffers are the tapped system audio.
        var ioProcID: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, nil) {
            [downsampler, format] _, inInputData, _, _, _ in
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                bufferListNoCopy: inInputData,
                deallocator: nil
            ) else { return }
            downsampler.append(buffer)
        }
        guard status == noErr, let ioProcID else {
            teardown()
            throw TapError.osStatus("AudioDeviceCreateIOProcIDWithBlock", status)
        }
        self.ioProcID = ioProcID

        status = AudioDeviceStart(aggregateID, ioProcID)
        guard status == noErr else {
            teardown()
            throw TapError.osStatus("AudioDeviceStart", status)
        }
    }

    /// Stops capture, tears down tap + aggregate device, returns the samples.
    func stop() -> [Float] {
        isCapturing = false // entwertet Listener-Events und laufende Retries
        rebuildInFlight = false
        removeDeviceListener()
        teardown()
        return downsampler.drain()
    }

    /// The tap's stream format is fixed at creation. When the default output
    /// device changes mid-meeting (AirPods connect …), buffers would be
    /// misinterpreted — rebuild the capture chain against the new device.
    private func installDeviceListener() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, self.isCapturing, !self.rebuildInFlight else { return }
            self.teardown()
            self.attemptRebuild(remaining: Self.rebuildAttempts)
        }
        deviceListener = listener
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, .main, listener
        )
    }

    /// Neuaufbau nach Device-Wechsel, mit Retries: das neue Default-Device ist
    /// oft erst einen Moment später tappable. Downsampler/Spool bleiben
    /// unangetastet — bereits aufgenommenes Audio überlebt jeden Ausgang.
    /// Läuft auf der Main-Queue; scheitern alle Versuche, feuert
    /// `onRebuildFailure` genau einmal (ein späterer Device-Wechsel darf
    /// erneut versuchen).
    private func attemptRebuild(remaining: Int) {
        guard isCapturing else {
            rebuildInFlight = false // stop() kam dazwischen
            return
        }
        rebuildInFlight = true
        do {
            try buildCapture() // failure paths räumen via teardown() selbst auf
            // Die Sekunden ohne Tap sind echte Zeit: ohne Stille dafür
            // rutscht alles Folgende auf der Systemspur nach vorn und der
            // Merge mit der Mikrofonspur verschränkt die falschen Sprecher.
            downsampler.padGapToWallClock()
            rebuildInFlight = false
        } catch {
            if remaining > 1 {
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.rebuildRetryDelay) { [weak self] in
                    self?.attemptRebuild(remaining: remaining - 1)
                }
            } else {
                rebuildInFlight = false
                onRebuildFailure?(error)
            }
        }
    }

    private func removeDeviceListener() {
        guard let deviceListener else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, .main, deviceListener
        )
        self.deviceListener = nil
    }

    private func teardown() {
        if aggregateID != kAudioObjectUnknown {
            if let ioProcID {
                AudioDeviceStop(aggregateID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        ioProcID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        tapFormat = nil
    }
}
