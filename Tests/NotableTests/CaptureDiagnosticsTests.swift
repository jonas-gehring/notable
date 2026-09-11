import XCTest

/// Spec 23, Stufe 0: the silence warning names the real cause, and the
/// diagnostics that make that possible never cost a meeting its recovery.
final class CaptureDiagnosticsTests: XCTestCase {
    private let builtIn = CaptureDiagnostics.Device(name: "MacBook Pro Microphone", uid: "BuiltInMicrophoneDevice", transport: "builtIn")
    private let airPods = CaptureDiagnostics.Device(name: "AirPods Pro", uid: "bt-1", transport: "bluetooth")
    private let teamsAudio = CaptureDiagnostics.Device(name: "Microsoft Teams Audio", uid: "ms", transport: "virtual")

    private func diagnostics(
        recorded: CaptureDiagnostics.Device?, lidClosed: Bool,
        callApp: String? = nil, callDevices: [CaptureDiagnostics.Device] = []
    ) -> CaptureDiagnostics {
        CaptureDiagnostics(at: Date(), event: "start", recorded: recorded, reason: nil,
                           defaultInput: builtIn, defaultOutput: nil, lidClosed: lidClosed,
                           callApp: callApp, callInputDevices: callDevices, echoCancellation: false)
    }

    // MARK: - SilenceDiagnosis

    /// The only case where the old text was right — and now the only case it appears.
    func testMissingPermissionOutranksEverything() {
        let cause = SilenceDiagnosis.cause(of: diagnostics(recorded: builtIn, lidClosed: true), micAuthorized: false)
        XCTAssertEqual(cause, String(localized: "Mikrofon-Berechtigung für Notable prüfen (Systemeinstellungen → Datenschutz & Sicherheit → Mikrofon)."))
    }

    func testClosedLidNamesTheCallDevice() throws {
        let d = diagnostics(recorded: builtIn, lidClosed: true, callApp: "Microsoft Teams", callDevices: [airPods])
        let cause = try XCTUnwrap(SilenceDiagnosis.cause(of: d, micAuthorized: true))
        XCTAssertTrue(cause.hasPrefix(String(localized: "Deckel geschlossen — das eingebaute Mikrofon ist dann abgeschaltet.")))
        XCTAssertTrue(cause.contains("Microsoft Teams"))
        XCTAssertTrue(cause.contains("AirPods Pro"))
        XCTAssertFalse(cause.contains("Berechtigung"), "Die Berechtigung ist erteilt — sie zu nennen führt in die Irre")
    }

    func testClosedLidWithoutACallStillSaysWhy() {
        let cause = SilenceDiagnosis.cause(of: diagnostics(recorded: builtIn, lidClosed: true), micAuthorized: true)
        XCTAssertEqual(cause, String(localized: "Deckel geschlossen — das eingebaute Mikrofon ist dann abgeschaltet."))
    }

    func testADifferentCallDeviceNamesBoth() throws {
        let d = diagnostics(recorded: builtIn, lidClosed: false, callApp: "Zoom", callDevices: [teamsAudio, airPods])
        let cause = try XCTUnwrap(SilenceDiagnosis.cause(of: d, micAuthorized: true))
        XCTAssertTrue(cause.contains("MacBook Pro Microphone"))
        XCTAssertTrue(cause.contains("AirPods Pro"), "der virtuelle Treiber ist kein Mikrofon")
        XCTAssertFalse(cause.contains("Teams Audio"))
    }

    func testNoEvidenceMeansNoGuess() {
        XCTAssertNil(SilenceDiagnosis.cause(of: nil, micAuthorized: true))
        let d = diagnostics(recorded: airPods, lidClosed: false, callApp: "Zoom", callDevices: [airPods])
        XCTAssertEqual(SilenceDiagnosis.cause(of: d, micAuthorized: true),
                       String(localized: "Aufgenommen wurde „\(airPods.name)“."))
    }

    // MARK: - Meta, as crash recovery reads it

    private func tempBase() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("notable-spool-\(UUID().uuidString)", isDirectory: true)
    }

    /// Every spool written before Spec 23 has no `diagnostics` key.
    func testMetaWithoutDiagnosticsStillDecodes() throws {
        let json = #"{"startedAt":1234,"eventTitle":"Standup","eventID":"ev-1"}"#
        let meta = try JSONDecoder().decode(SpoolStore.Meta.self, from: Data(json.utf8))
        XCTAssertEqual(meta.eventTitle, "Standup")
        XCTAssertNil(meta.diagnostics)
    }

    /// A diagnostic field that no longer parses must not make recovery skip the meeting.
    func testUnreadableDiagnosticsDoNotCostTheMeeting() throws {
        let json = #"{"startedAt":1234,"diagnostics":[{"what":"ever"}]}"#
        let meta = try JSONDecoder().decode(SpoolStore.Meta.self, from: Data(json.utf8))
        XCTAssertEqual(meta.startedAt, Date(timeIntervalSinceReferenceDate: 1234))
        XCTAssertNil(meta.diagnostics)
    }

    /// The calendar lookup and the diagnostics both write the meta; neither may
    /// drop the other's fields.
    func testUpdateMetaKeepsWhatTheOtherWriterPutThere() throws {
        let base = tempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let session = try SpoolStore.create(meta: SpoolStore.Meta(startedAt: Date(timeIntervalSince1970: 99)), base: base)

        let entry = diagnostics(recorded: airPods, lidClosed: true)
        SpoolStore.updateMeta(session) { $0.diagnostics = [entry] }
        SpoolStore.updateMeta(session) { $0.eventTitle = "Sync" }

        let orphan = try XCTUnwrap(SpoolStore.orphans(base: base).first)
        XCTAssertEqual(orphan.meta.eventTitle, "Sync")
        XCTAssertEqual(orphan.meta.diagnostics?.first?.recorded, airPods)
        XCTAssertEqual(orphan.meta.startedAt, Date(timeIntervalSince1970: 99))
    }
}
