import PlatenCore
import SwiftUI

/// The settings sheet on iOS, opened from the gear button in the overlay.
/// It holds what the overlay's own popovers do not: text size, font, line
/// spacing and appearance are in the Aa popover beside the gear, so they are
/// not repeated here. The Mac's File Types tab has no iOS counterpart.
/// Changes apply to the open book straight away.
struct ReaderSettingsView: View {
    @ObservedObject var settings = ReaderSettings.shared
    /// Hyphenation does not apply to fixed-layout books.
    let isFixedLayout: Bool
    let done: () -> Void

    @State private var confirmClear = false

    /// Page Curl is not drawn on iOS yet, so it is not offered; a stored
    /// "Page Curl" (the default) shows and behaves as Slide until it is.
    private var pageTurn: Binding<PageTurnStyle> {
        Binding(get: { settings.pageTurnStyle == .none ? .none : .slide },
                set: { settings.pageTurnStyle = $0 })
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Layout") {
                    Picker("New Books Open In", selection: $settings.defaultLayout) {
                        ForEach(ReadingLayout.allCases) { Text($0.label).tag($0) }
                    }
                    Picker("Line Width", selection: $settings.lineWidth) {
                        ForEach(LineWidth.allCases) { Text($0.label).tag($0) }
                    }
                    Picker("Page Turn", selection: pageTurn) {
                        Text(PageTurnStyle.slide.label).tag(PageTurnStyle.slide)
                        Text(PageTurnStyle.none.label).tag(PageTurnStyle.none)
                    }
                    Toggle("Show Pages Left in Chapter", isOn: $settings.showPagesLeftInChapter)
                    Toggle("Hyphenate Text", isOn: $settings.hyphenate)
                        .disabled(isFixedLayout)
                }

                Section {
                    Button("Clear Reading Positions and Bookmarks…", role: .destructive) { confirmClear = true }
                } footer: {
                    Text("Platen keeps only where you are in each book and your bookmarks, on this device.")
                }
            }
            .navigationTitle(Text("Settings"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: done)
                }
            }
            .confirmationDialog("Clear all reading positions and bookmarks?", isPresented: $confirmClear,
                                titleVisibility: .visible) {
                Button("Clear", role: .destructive) { try? PositionStore.shared.removeAll() }
            } message: {
                Text("This cannot be undone.")
            }
        }
    }
}
