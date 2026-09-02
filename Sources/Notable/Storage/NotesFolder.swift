import AppKit
import Foundation
import SwiftUI

/// The user-chosen folder for Markdown notes — the product surface.
/// Not sandboxed, so a plain path in UserDefaults is sufficient.
@MainActor
final class NotesFolderManager: ObservableObject {
    static let defaultsKey = "notesFolderPath"

    @Published private(set) var folderURL: URL

    init() {
        if let path = UserDefaults.standard.string(forKey: Self.defaultsKey) {
            folderURL = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            folderURL = FileManager.default
                .urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Notable", isDirectory: true)
        }
    }

    func ensureExists() throws {
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = folderURL
        panel.prompt = "Ordner wählen"
        panel.message = "Ordner für Meeting-Notizen (Markdown)"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        folderURL = url
        UserDefaults.standard.set(url.path, forKey: Self.defaultsKey)
    }
}
