import XCTest
@testable import Notable

/// Issue #3. The panel itself cannot be unit-tested (it is an AppKit window that
/// must never become key), but where it goes can be — including the setups that
/// are awkward to reproduce by hand.
final class NotchGeometryTests: XCTestCase {
    private let panel = CGSize(width: 380, height: 68)

    /// A 14" MacBook Pro: 1512 × 982 points, 32 pt safe area, notch ≈ 200 pt wide.
    private var built_in: NotchGeometry.Screen {
        NotchGeometry.Screen(
            frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 944),
            safeAreaTop: 32,
            auxLeft: CGRect(x: 0, y: 950, width: 656, height: 32),
            auxRight: CGRect(x: 856, y: 950, width: 656, height: 32)
        )
    }

    /// An external 1080p display: no notch, no auxiliary areas.
    private var external: NotchGeometry.Screen {
        NotchGeometry.Screen(
            frame: CGRect(x: 1512, y: 0, width: 1920, height: 1080),
            visibleFrame: CGRect(x: 1512, y: 0, width: 1920, height: 1055),
            safeAreaTop: 0,
            auxLeft: nil,
            auxRight: nil
        )
    }

    // MARK: - Notch

    func testNotchScreenPlacesTwoAreasBesideTheCutout() {
        guard case .aroundNotch(let left, let right) =
            NotchGeometry.placement(for: built_in, size: panel, style: .notch)
        else { return XCTFail("erwartet: .aroundNotch") }

        XCTAssertLessThanOrEqual(left.maxX, right.minX, "die Bereiche dürfen sich nicht überlappen")
        // The cut-out between 656 and 856 stays empty — that is the whole point.
        XCTAssertLessThanOrEqual(left.maxX, 656)
        XCTAssertGreaterThanOrEqual(right.minX, 856)
        XCTAssertTrue(built_in.frame.contains(left))
        XCTAssertTrue(built_in.frame.contains(right))
    }

    func testNotchAreasNeverGrowTallerThanTheStrip() {
        guard case .aroundNotch(let left, _) =
            NotchGeometry.placement(for: built_in, size: CGSize(width: 380, height: 200), style: .notch)
        else { return XCTFail("erwartet: .aroundNotch") }
        XCTAssertEqual(left.height, 32, "die Anzeige darf nicht in die Menüleiste hineinwachsen")
    }

    // MARK: - No notch

    func testScreenWithoutNotchFallsBackToAPillUnderTheMenuBar() {
        guard case .pillUnderMenuBar(let frame) =
            NotchGeometry.placement(for: external, size: panel, style: .notch)
        else { return XCTFail("erwartet: .pillUnderMenuBar") }

        XCTAssertTrue(external.visibleFrame.contains(frame), "die Pille muss vollständig sichtbar sein")
        XCTAssertEqual(frame.maxY, external.visibleFrame.maxY, accuracy: 0.5)
        XCTAssertEqual(frame.midX, external.visibleFrame.midX, accuracy: 0.5)
    }

    /// A screen narrower than the panel: clamp, never position at a negative x.
    func testPanelWiderThanTheScreenIsClampedNotPushedOffscreen() {
        let narrow = NotchGeometry.Screen(
            frame: CGRect(x: 0, y: 0, width: 320, height: 480),
            visibleFrame: CGRect(x: 0, y: 0, width: 320, height: 455),
            safeAreaTop: 0, auxLeft: nil, auxRight: nil
        )
        guard case .pillUnderMenuBar(let frame) =
            NotchGeometry.placement(for: narrow, size: panel, style: .notch)
        else { return XCTFail("erwartet: .pillUnderMenuBar") }

        XCTAssertGreaterThanOrEqual(frame.minX, 0)
        XCTAssertLessThanOrEqual(frame.width, narrow.visibleFrame.width)
        XCTAssertTrue(narrow.visibleFrame.contains(frame))
    }

    /// With the menu bar auto-hidden the visible frame reaches the screen top and
    /// the pill has to follow it, not stay at the old menu-bar height.
    func testHiddenMenuBarMovesThePillUp() {
        var screen = external
        screen.visibleFrame = screen.frame
        guard case .pillUnderMenuBar(let frame) =
            NotchGeometry.placement(for: screen, size: panel, style: .notch)
        else { return XCTFail("erwartet: .pillUnderMenuBar") }
        XCTAssertEqual(frame.maxY, screen.frame.maxY, accuracy: 0.5)
    }

    /// A screen that is not at the origin — the notch display need not be the
    /// main display, and a frame computed in screen-local coordinates would land
    /// on the wrong monitor.
    func testOffsetScreenKeepsThePanelOnThatScreen() {
        guard case .pillUnderMenuBar(let frame) =
            NotchGeometry.placement(for: external, size: panel, style: .notch)
        else { return XCTFail("erwartet: .pillUnderMenuBar") }
        XCTAssertGreaterThanOrEqual(frame.minX, 1512)
    }

    // MARK: - Bottom (regression against the original implementation)

    /// Pins the pre-issue-#3 position: centred on `visibleFrame`, 80 pt up.
    func testBottomStyleReproducesTheOriginalPosition() {
        guard case .bottomCenter(let frame) =
            NotchGeometry.placement(for: external, size: panel, style: .bottom)
        else { return XCTFail("erwartet: .bottomCenter") }

        XCTAssertEqual(frame.minX, external.visibleFrame.midX - panel.width / 2, accuracy: 0.001)
        XCTAssertEqual(frame.minY, external.visibleFrame.minY + 80, accuracy: 0.001)
        XCTAssertEqual(frame.size, panel)
    }

    /// "Off" still computes a frame — the controller decides not to show it. The
    /// geometry has no business knowing about visibility.
    func testOffUsesTheBottomFrame() {
        XCTAssertEqual(
            NotchGeometry.placement(for: external, size: panel, style: .off),
            NotchGeometry.placement(for: external, size: panel, style: .bottom)
        )
    }

    // MARK: - Setting

    func testStyleDefaultsToBottom() {
        XCTAssertEqual(OverlayStyle(rawValue: "unsinn"), nil)
        XCTAssertEqual(OverlayStyle.allCases.first, .bottom)
    }
}
