import AppKit
import XCTest
@testable import Notable

/// The overlay panel's invariants — the ones that used to be a comment and a
/// manual check.
///
/// **"Must never become key" is the load-bearing one.** Dictation works by
/// synthesizing ⌘V into whatever field the user was in; the moment this panel
/// takes focus, that field is Notable's and the text goes nowhere. It is also
/// exactly the kind of rule a later refactor breaks without any visible symptom
/// until someone dictates into Slack.
@MainActor
final class DictationOverlayTests: XCTestCase {
    private var previousStyle: String?

    override func setUp() {
        super.setUp()
        previousStyle = UserDefaults.standard.string(forKey: OverlayStyle.storageKey)
    }

    override func tearDown() {
        UserDefaults.standard.set(previousStyle, forKey: OverlayStyle.storageKey)
        super.tearDown()
    }

    private func controller(style: OverlayStyle) -> DictationOverlayController {
        UserDefaults.standard.set(style.rawValue, forKey: OverlayStyle.storageKey)
        return DictationOverlayController()
    }

    // MARK: - The invariant

    func testPanelCanNeverBecomeKey() throws {
        for style in [OverlayStyle.bottom, .notch] {
            let overlay = controller(style: style)
            overlay.show(.recording)
            let panel = try XCTUnwrap(overlay.panel, style.rawValue)

            XCTAssertFalse(panel.canBecomeKey, "\(style.rawValue): darf nie key werden")
            XCTAssertFalse(panel.isKeyWindow, style.rawValue)
            overlay.hide()
        }
    }

    /// Showing the overlay must not take focus away from whatever window has it.
    func testShowingDoesNotStealTheKeyWindow() throws {
        let before = NSApp?.keyWindow
        let overlay = controller(style: .bottom)
        overlay.show(.recording)
        XCTAssertTrue(NSApp?.keyWindow === before, "das Overlay hat den Fokus übernommen")
        overlay.hide()
    }

    func testPanelStaysOutOfEveryEventPath() throws {
        let overlay = controller(style: .notch)
        overlay.show(.recording)
        let panel = try XCTUnwrap(overlay.panel)

        // Deliberately *not* a control surface: a clickable panel in the
        // dictation path is the class of bug the key rule exists to prevent.
        XCTAssertTrue(panel.ignoresMouseEvents)
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertTrue(panel.styleMask.contains(.borderless))
        XCTAssertFalse(panel.hidesOnDeactivate)
        XCTAssertEqual(panel.level, .statusBar)
        XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        overlay.hide()
    }

    // MARK: - The style setting

    /// "Wirkt beim nächsten Diktat ohne Neustart" — the same controller has to
    /// pick up a changed setting.
    func testStyleChangeTakesEffectWithoutARestart() throws {
        let overlay = controller(style: .bottom)
        overlay.show(.recording)
        let first = try XCTUnwrap(overlay.panel)
        overlay.hide()

        UserDefaults.standard.set(OverlayStyle.notch.rawValue, forKey: OverlayStyle.storageKey)
        overlay.show(.recording)
        let second = try XCTUnwrap(overlay.panel)

        XCTAssertTrue(first === second, "dasselbe Panel, nur eine andere View")
        XCTAssertFalse(second.canBecomeKey, "auch nach dem Wechsel")
        overlay.hide()
    }

    /// "Aus" means no panel for the ordinary states — but a failure still has to
    /// reach the user, because that is not a display preference.
    func testOffHidesEverythingExceptFailuresAndNotices() throws {
        let overlay = controller(style: .off)

        overlay.show(.recording)
        XCTAssertFalse(overlay.panel?.isVisible ?? false, "Aufnahme bleibt unsichtbar")

        overlay.show(.transcribing)
        XCTAssertFalse(overlay.panel?.isVisible ?? false, "Transkription bleibt unsichtbar")

        overlay.show(.error("Einfügen fehlgeschlagen"))
        XCTAssertTrue(overlay.panel?.isVisible ?? false, "ein Fehlschlag muss sichtbar sein")

        overlay.show(.notice("Parakeet v3 aktiv"))
        XCTAssertTrue(overlay.panel?.isVisible ?? false, "der Modelltausch auch")
        overlay.hide()
    }

    // MARK: - Placement

    /// The geometry is tested purely; this checks that its answer actually
    /// reaches the panel instead of being computed and dropped.
    func testPlacementIsAppliedToThePanel() throws {
        let overlay = controller(style: .bottom)
        overlay.show(.recording)
        let panel = try XCTUnwrap(overlay.panel)

        let screens = NSScreen.screens
        try XCTSkipIf(screens.isEmpty, "kein Bildschirm im Testlauf")
        XCTAssertTrue(
            screens.contains { $0.frame.intersects(panel.frame) },
            "Panel liegt auf keinem Bildschirm: \(panel.frame)"
        )
        overlay.hide()
    }

    func testHideClearsTheTransientState() {
        let overlay = controller(style: .bottom)
        overlay.show(.recording)
        overlay.updateLevel(0.5)
        overlay.updatePartial("halber Satz")
        overlay.updateLocked(true)
        overlay.hide()
        XCTAssertFalse(overlay.panel?.isVisible ?? false)
    }
}
