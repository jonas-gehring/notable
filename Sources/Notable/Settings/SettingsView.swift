import SwiftUI

/// The settings window: four pages in a native `NavigationSplitView` sidebar
/// (resizable, standard macOS System-Settings look). Earlier this was a
/// hand-rolled top tab bar to dodge `TabView`'s titlebar-overflow inside a plain
/// `Window`; the sidebar is more native and never crowds long labels.
///
/// The frame and nothing else — every page is its own file.
struct SettingsView: View {
    /// The pages themselves live in `SettingsRoute.swift`, which is pure and
    /// therefore testable; this keeps the name they are referred to by.
    typealias Pane = SettingsPane

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
        .windowMinimum(WindowSize.settings)
        .windowFrameAutosave(WindowSize.settings)
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
        case .data: DataSettingsView()
        }
    }
}
