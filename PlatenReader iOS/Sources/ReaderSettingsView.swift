import PlatenCore
import SwiftUI
import UIKit

/// The settings on iOS, in a popover from the gear button among the
/// overlay's buttons (the same style as Contents, Layout and Aa). It holds
/// what the other popovers do not: text size, font, line spacing and
/// appearance are in Aa, so they are not repeated here. The Mac's File Types
/// tab has no iOS counterpart. Changes apply to the open book straight away.
struct ReaderSettingsView: View {
    @ObservedObject var settings = ReaderSettings.shared
    /// Hyphenation does not apply to fixed-layout books (or PDFs).
    let isFixedLayout: Bool

    @State private var confirmClear = false

    var body: some View {
        Form {
            Section("Layout") {
                Picker("New Books Open In", selection: Binding(
                    get: {
                        let layout = settings.defaultLayout
                        return layout == .twoPages && UIDevice.current.userInterfaceIdiom == .phone ? .onePage : layout
                    },
                    set: { settings.defaultLayout = $0 })) {
                    // iPhone: books always show one page, so no Two Pages.
                    ForEach(ReadingLayout.allCases.filter {
                        $0 != .twoPages || UIDevice.current.userInterfaceIdiom != .phone
                    }) { Text($0.label).tag($0) }
                }
                Picker("Line Width", selection: $settings.lineWidth) {
                    ForEach(LineWidth.allCases) { Text($0.label).tag($0) }
                }
                Picker("Page Turn", selection: $settings.pageTurnStyle) {
                    ForEach(PageTurnStyle.allCases) { Text($0.label).tag($0) }
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
        .formStyle(.grouped)
        // A form in a popover has no height of its own on iOS.
        .frame(width: 340, height: 460)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Settings"))
        .confirmationDialog("Clear all reading positions and bookmarks?", isPresented: $confirmClear,
                            titleVisibility: .visible) {
            Button("Clear", role: .destructive) { try? PositionStore.shared.removeAll() }
        } message: {
            Text("This cannot be undone.")
        }
    }
}
