import SwiftUI

struct SettingsView: View {
    /// The seven settings pages, shown in a native `NavigationSplitView` sidebar
    /// (resizable, standard macOS System-Settings look). Earlier this was a
    /// hand-rolled top tab bar to dodge `TabView`'s titlebar-overflow inside a
    /// plain `Window`; the sidebar is more native and never crowds long labels.
    enum Pane: String, CaseIterable, Identifiable {
        case general, dictation, meetings, menubar, summary, storage, permissions
        var id: String { rawValue }

        var label: String {
            let key: String.LocalizationValue = switch self {
            case .general: "Allgemein"
            case .dictation: "Diktat"
            case .meetings: "Meetings"
            case .menubar: "Menüleiste"
            case .summary: "Zusammenfassung"
            case .storage: "Speicherplatz"
            case .permissions: "Berechtigungen"
            }
            return String(localized: key)
        }

        var icon: String {
            switch self {
            case .general: "gearshape"
            case .dictation: "mic"
            case .meetings: "person.2.wave.2"
            case .menubar: "menubar.rectangle"
            case .summary: "text.justify.left"
            case .storage: "internaldrive"
            case .permissions: "lock.shield"
            }
        }
    }

    @State private var selection: Pane? = .general
    @ObservedObject private var route = AppContainer.shared.settingsRoute

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(Pane.allCases) { pane in
                    Label(pane.label, systemImage: pane.icon)
                        .tag(pane)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        } detail: {
            content
                .navigationTitle((selection ?? .general).label)
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 700, minHeight: 460)
        // Both, because the window may be opening for the first time or may
        // already be standing open behind something else.
        .task { if let requested = route.consume() { selection = requested } }
        .onChange(of: route.requested) { _, requested in
            if let requested { selection = route.consume() ?? requested }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch selection ?? .general {
        case .general: GeneralSettingsView()
        case .dictation: DictationSettingsView()
        case .meetings: MeetingsSettingsView()
        case .menubar: MenuBarSettingsView()
        case .summary: SummarizationSettingsView()
        case .storage: StorageSettingsView()
        case .permissions: PermissionsSettingsView()
        }
    }
}
