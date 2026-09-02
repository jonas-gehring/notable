import CoreGraphics
import Foundation

/// Where the dictation HUD goes.
enum OverlayStyle: String, CaseIterable, Identifiable, Sendable {
    /// Today's behaviour: a capsule near the bottom edge.
    case bottom
    /// At the top: around the notch on a MacBook that has one, otherwise a pill
    /// just under the menu bar.
    case notch
    /// No panel at all — for whoever only wants the sound cue.
    case off

    static let storageKey = "overlayStyle"

    static var current: OverlayStyle {
        UserDefaults.standard.string(forKey: storageKey).flatMap(OverlayStyle.init(rawValue:)) ?? .bottom
    }

    var id: String { rawValue }

    var label: String {
        switch self {
        case .bottom: "Unten mittig (Standard)"
        case .notch: "Oben an der Notch"
        case .off: "Aus — nur Ton"
        }
    }
}

/// Works out the panel frame for an `OverlayStyle`. Pure: screen measurements in,
/// rectangles out, no `NSScreen` and no AppKit — which is the only way the cases
/// that actually hurt (menu bar hidden, external monitor narrower than the panel,
/// notch screen is not the main screen) can be tested at all.
enum NotchGeometry {
    /// The measurements taken off an `NSScreen`, and nothing else.
    struct Screen: Sendable, Equatable {
        /// Full screen frame in global (bottom-left origin) coordinates.
        var frame: CGRect
        /// The frame minus menu bar and Dock.
        var visibleFrame: CGRect
        /// `NSScreen.safeAreaInsets.top` — greater than zero exactly when there
        /// is a notch. 0 on every external display.
        var safeAreaTop: CGFloat
        /// `NSScreen.auxiliaryTopLeftArea` / `…RightArea`: the usable strips beside
        /// the notch. `nil` when the screen has none.
        var auxLeft: CGRect?
        var auxRight: CGRect?

        var hasNotch: Bool { safeAreaTop > 0 }
    }

    enum Placement: Sendable, Equatable {
        /// Two panels, one either side of the cut-out. The notch itself stays
        /// empty — that is the entire effect.
        case aroundNotch(left: CGRect, right: CGRect)
        /// One pill directly under the menu bar.
        case pillUnderMenuBar(CGRect)
        /// The existing bottom-centre capsule.
        case bottomCenter(CGRect)
    }

    /// Distance from the bottom of the visible frame, unchanged from the original
    /// implementation — a regression test pins it.
    static let bottomInset: CGFloat = 80

    static func placement(for screen: Screen, size: CGSize, style: OverlayStyle) -> Placement {
        switch style {
        case .bottom, .off:
            return .bottomCenter(bottomCenterFrame(for: screen, size: size))
        case .notch:
            if screen.hasNotch, let left = screen.auxLeft, let right = screen.auxRight,
               left.width > 0, right.width > 0 {
                return .aroundNotch(
                    left: clamped(CGRect(x: left.minX, y: left.minY, width: left.width, height: min(size.height, left.height)), to: screen.frame),
                    right: clamped(CGRect(x: right.minX, y: right.minY, width: right.width, height: min(size.height, right.height)), to: screen.frame)
                )
            }
            return .pillUnderMenuBar(pillFrame(for: screen, size: size))
        }
    }

    private static func bottomCenterFrame(for screen: Screen, size: CGSize) -> CGRect {
        let width = min(size.width, screen.visibleFrame.width)
        return clamped(
            CGRect(
                x: screen.visibleFrame.midX - width / 2,
                y: screen.visibleFrame.minY + bottomInset,
                width: width,
                height: size.height
            ),
            to: screen.visibleFrame
        )
    }

    /// Directly under the menu bar — i.e. at the top of the *visible* frame, which
    /// is where the menu bar already ends. With the menu bar auto-hidden the
    /// visible frame reaches the screen top and the pill follows it up.
    private static func pillFrame(for screen: Screen, size: CGSize) -> CGRect {
        // Never wider than the screen: a 380 pt panel on a narrow external display
        // must be clamped, not positioned at a negative x.
        let width = min(size.width, screen.visibleFrame.width)
        return clamped(
            CGRect(
                x: screen.visibleFrame.midX - width / 2,
                y: screen.visibleFrame.maxY - size.height,
                width: width,
                height: size.height
            ),
            to: screen.visibleFrame
        )
    }

    /// Keeps a frame inside `bounds`, shrinking before it moves.
    static func clamped(_ rect: CGRect, to bounds: CGRect) -> CGRect {
        let width = min(rect.width, bounds.width)
        let height = min(rect.height, bounds.height)
        let x = min(max(rect.minX, bounds.minX), bounds.maxX - width)
        let y = min(max(rect.minY, bounds.minY), bounds.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
