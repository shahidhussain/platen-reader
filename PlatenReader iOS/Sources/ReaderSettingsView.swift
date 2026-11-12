import PlatenCore
import SwiftUI

/// The settings sheet on iOS, opened from the gear button in the overlay.
/// The same global settings as the Mac's Settings window (General and
/// Appearance), in one sheet; the Mac's File Types tab has no iOS
/// counterpart. Changes apply to the open book straight away.
struct ReaderSettingsView: View {
    @ObservedObject var settings = ReaderSettings.shared
    /// Font, size and spacing do not apply to fixed-layout books.
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
                Section("Text") {
                    LabeledContent("Text Size") {
                        Stepper(value: $settings.fontSizeIndex, in: 0...(ReaderSettings.fontSizes.count - 1)) {
                            Text("\(Int(settings.fontSize)) pt").monospacedDigit()
                        }
                        .fixedSize()
                    }
                    Picker("Font", selection: $settings.fontFamily) {
                        ForEach(ReaderSettings.curatedFonts, id: \.self) { name in
                            Text(name.isEmpty ? String(localized: "Publisher Default") : name).tag(name)
                        }
                    }
                    Picker("Line Spacing", selection: $settings.lineHeight) {
                        ForEach(ReaderSettings.lineHeights, id: \.self) { value in
                            Text(value == 0 ? String(localized: "Publisher Default")
                                 : value.formatted(.number.precision(.fractionLength(1...2)))).tag(value)
                        }
                    }
                    Toggle("Hyphenate Text", isOn: $settings.hyphenate)
                }
                .disabled(isFixedLayout)

                Section {
                    Picker("Appearance", selection: $settings.appearance) {
                        ForEach(AppearanceChoice.allCases) { Text($0.label).tag($0) }
                    }
                } footer: {
                    Text("Automatic follows the system: Light in Light Mode, Dark in Dark Mode.")
                }

                Section("Layout") {
                    Picker("Layout", selection: $settings.defaultLayout) {
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
