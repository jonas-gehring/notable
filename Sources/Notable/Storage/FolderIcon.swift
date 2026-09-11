import AppKit
import UniformTypeIdentifiers

/// Notable's mark on the notes folder in Finder (Spec 27 §3.3).
///
/// **Composed at runtime, not shipped as a picture:** the current system folder
/// with Notable's waveform on its front. The folder's look changes between macOS
/// versions, and a folder baked from an older one looks foreign in Finder. The
/// image draws itself at whatever size Finder asks for, 16 to 1024 px.
///
/// Only thin AppKit here; *when* to set or remove is `FolderIconRule`.
@MainActor
enum FolderIcon {
    static func image() -> NSImage {
        let folder = NSWorkspace.shared.icon(for: .folder)
        return NSImage(size: NSSize(width: 512, height: 512), flipped: false) { rect in
            folder.draw(in: rect)
            let glyphHeight = rect.height * 0.26
            let tint = NSColor.systemBlue.blended(withFraction: 0.45, of: .black) ?? .systemBlue
            let configuration = NSImage.SymbolConfiguration(pointSize: glyphHeight, weight: .semibold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [tint.withAlphaComponent(0.8)]))
            guard let glyph = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration) else { return true }
            // The front panel of the macOS folder sits in the lower two thirds.
            let size = glyph.size
            let origin = NSPoint(x: rect.midX - size.width / 2, y: rect.minY + rect.height * 0.38 - size.height / 2)
            glyph.draw(in: NSRect(origin: origin, size: size))
            return true
        }
    }

    /// Finder keeps every custom folder icon as a hidden `Icon\r` file inside it.
    static func hasCustomIcon(_ folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent("Icon\r").path)
    }

    @discardableResult
    static func set(on folder: URL) -> Bool {
        NSWorkspace.shared.setIcon(image(), forFile: folder.path, options: [])
    }

    @discardableResult
    static func remove(from folder: URL) -> Bool {
        NSWorkspace.shared.setIcon(nil, forFile: folder.path, options: [])
    }
}
