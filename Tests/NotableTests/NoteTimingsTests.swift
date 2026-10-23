import XCTest

/// The stop-to-note numbers in `meta.json` (P1). They are only worth anything
/// if they survive the trip through the spool, and recovery reads the same
/// file — so a broken timings block must never cost the meeting.
final class NoteTimingsTests: XCTestCase {
    func testMillisecondsFromDuration() {
        XCTAssertEqual(NoteTimings.milliseconds(.seconds(2)), 2000)
        XCTAssertEqual(NoteTimings.milliseconds(.milliseconds(1234)), 1234)
        XCTAssertEqual(NoteTimings.milliseconds(.microseconds(1999)), 1)
        XCTAssertEqual(NoteTimings.milliseconds(.zero), 0)
    }

    func testSummaryNamesEveryStepAndTheRest() {
        var timings = NoteTimings()
        timings.audioSeconds = 3720
        timings.modelMs = 1200
        timings.segmentationMs = 19800
        timings.transcriptionMs = 40010
        timings.pipelineMs = 61020
        timings.namingMs = 3100
        timings.summaryMs = 18900
        timings.totalMs = 84210

        XCTAssertEqual(timings.otherMs, 1190)
        XCTAssertEqual(
            timings.summary,
            "gesamt 84210 ms · audio 3720 s · pipeline 61020 ms (modell 1200, segmente 19800, asr 40010) · "
                + "namen 3100 ms · zusammenfassung 18900 ms · rest 1190 ms"
        )
    }

    /// Steps measured on separate clocks can add up to a hair more than the
    /// total; the rest is then zero, not negative.
    func testRestIsNeverNegative() {
        var timings = NoteTimings()
        timings.pipelineMs = 100
        timings.totalMs = 99
        XCTAssertEqual(timings.otherMs, 0)
    }

    func testMetaRoundTripCarriesTheTimings() throws {
        var timings = NoteTimings()
        timings.pipelineMs = 5000
        timings.totalMs = 7000
        var meta = SpoolStore.Meta(startedAt: Date(timeIntervalSince1970: 1234))
        meta.timings = timings

        let decoded = try JSONDecoder().decode(SpoolStore.Meta.self, from: JSONEncoder().encode(meta))
        XCTAssertEqual(decoded.timings, timings)
    }

    /// A meta written before the field existed, one whose block is garbage, and
    /// one from a version with other step names — all still decode, because
    /// recovery decodes this file and a measurement must never cost a meeting.
    func testMetaDecodesLenientlyAroundTheTimings() throws {
        let old = #"{"startedAt": 0}"#
        XCTAssertNil(try JSONDecoder().decode(SpoolStore.Meta.self, from: Data(old.utf8)).timings)

        let garbage = #"{"startedAt": 0, "timings": "schnell"}"#
        XCTAssertNil(try JSONDecoder().decode(SpoolStore.Meta.self, from: Data(garbage.utf8)).timings)

        let other = #"{"startedAt": 0, "timings": {"totalMs": 900, "pipelineMs": "x", "embeddingMs": 4}}"#
        let decoded = try JSONDecoder().decode(SpoolStore.Meta.self, from: Data(other.utf8)).timings
        XCTAssertEqual(decoded?.totalMs, 900)
        XCTAssertEqual(decoded?.pipelineMs, 0)
    }
}
