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
        // Plain rows on the popover's glass, sized to fit (as Layout and Aa).
        PopoverRows(width: 330) {
            // Scroll or pages, for every book (the Layout button changes
            // the same setting).
            LabeledContent("Layout") {
                Picker("Layout", selection: Binding(
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
                .labelsHidden().fixedSize()
            }
            .popoverRow()
            PopoverDivider()
            LabeledContent("Line Width") {
                Picker("Line Width", selection: $settings.lineWidth) {
                    ForEach(LineWidth.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden().fixedSize()
            }
            .popoverRow()
            PopoverDivider()
            LabeledContent("Page Turn") {
                Picker("Page Turn", selection: $settings.pageTurnStyle) {
                    ForEach(PageTurnStyle.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden().fixedSize()
            }
            .popoverRow()
            PopoverDivider()
            Toggle("Show Pages Left in Chapter", isOn: $settings.showPagesLeftInChapter)
                .popoverRow()
            PopoverDivider()
            VStack(alignment: .leading, spacing: 2) {
                Toggle("Hyphenate Text", isOn: $settings.hyphenate)
                Text(isFixedLayout
                     ? "Breaks long words at the ends of lines. Not used in this book: its pages are laid out by the publisher."
                     : "Breaks long words at the ends of lines, so justified text has fewer wide gaps between words.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 8)
            .popoverRow()
            .disabled(isFixedLayout)
            PopoverDivider()
            Button("Clear Reading Positions and Bookmarks…", role: .destructive) { confirmClear = true }
                .popoverRow()
            Text("Platen keeps only where you are in each book and your bookmarks, on this device.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
        }
        // Switches in the system's green: the reader's own tint follows the
        // page (black, or white in dark mode), which made an "on" switch
        // white on white.
        .tint(Color(uiColor: .systemGreen))
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
