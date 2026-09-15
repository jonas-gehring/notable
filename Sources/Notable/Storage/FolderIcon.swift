import AppKit
import UniformTypeIdentifiers

/// Notable's mark on the notes folder in Finder (Spec 27 §3.3).
///
/// **Composed at runtime, not shipped as a picture:** the current system folder
/// with Notable's full app icon on its front — the way iCloud Drive shows
/// Numbers, Pages or Obsidian. The folder's look changes between macOS versions,
/// and a folder baked from an older one looks foreign in Finder. The image draws
/// itself at whatever size Finder asks for, 16 to 1024 px.
///
/// Version 1 put a small tinted waveform symbol into the lower third; the owner
/// asked for the whole app icon instead (2026-09-15). Where it sits is
/// `FolderIconLayout`; *when* to set, replace or remove is `FolderIconRule`.
@MainActor
enum FolderIcon {
    /// Bumped whenever the picture changes, so a folder still carrying an older
    /// Notable icon gets the current one (`FolderIconRule`).
    static let designVersion = 2

    static func image() -> NSImage {
        let folder = NSWorkspace.shared.icon(for: .folder)
        let appIcon: NSImage = NSApp?.applicationIconImage ?? NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
        return NSImage(size: NSSize(width: 512, height: 512), flipped: false) { rect in
            folder.draw(in: rect)
            appIcon.draw(in: FolderIconLayout.appIconFrame(in: rect))
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
