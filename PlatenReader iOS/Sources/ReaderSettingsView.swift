import PlatenCore
import SwiftUI
import UIKit

/// The settings on iOS: a sheet from the gear at the foot of the home
/// screen. They are about how the app works, so they live there, not among
/// the reader's buttons (every one of which is about the book being read).
///
/// Only what the reader's own popovers do not hold is here: one page or
/// scroll and the line width are in the Layout popover; text size, font,
/// line spacing and appearance in Aa. Each setting is in one place only.
/// The Mac's File Types tab has no iOS counterpart. Changes apply to any
/// open book straight away.
struct ReaderSettingsView: View {
    @ObservedObject var settings = ReaderSettings.shared
    @Environment(\.dismiss) private var dismiss
    @State private var confirmClear = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Reading") {
                    Picker("Page Turn", selection: $settings.pageTurnStyle) {
                        ForEach(PageTurnStyle.allCases) { Text($0.label).tag($0) }
                    }
                    Toggle("Show Pages Left in Chapter", isOn: $settings.showPagesLeftInChapter)
                    VStack(alignment: .leading, spacing: 2) {
                        Toggle("Justify Text", isOn: $settings.justify)
                        Text("Lines flush at both sides, where the book asks for it. Off, lines end where their words do (ragged right), which leaves no wide gaps between words on a narrow screen.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Toggle("Hyphenate Text", isOn: $settings.hyphenate)
                        Text("Breaks long words at the ends of lines, so lines are more even and justified text has fewer wide gaps between words. Not used in books whose pages are laid out by the publisher.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Section {
                    Button("Clear Reading Positions and Bookmarks…", role: .destructive) { confirmClear = true }
                } footer: {
                    Text("Platen keeps only where you are in each book and your bookmarks, on this device.")
                }
                Section {
                    LabeledContent("Platen Reader", value: AppVersion.line)
                } footer: {
                    // A little whimsy, unattributed (Slaughterhouse-Five).
                    Text(verbatim: "Poo-tee-weet?")
                        .font(.system(.footnote, design: .serif).italic())
                        .frame(maxWidth: .infinity)
                        .padding(.top, 24)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
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
