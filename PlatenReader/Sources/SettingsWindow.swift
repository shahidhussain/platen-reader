import AppKit
import PlatenCore
import SwiftUI
import UniformTypeIdentifiers

/// Platen Reader > Settings… (⌘,): a standard tabbed macOS settings window.
final class SettingsWindowController: NSWindowController {
    init() {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        func tab(_ title: String, _ symbol: String, _ view: some View) -> NSTabViewItem {
            let item = NSTabViewItem(viewController: NSHostingController(rootView: view.frame(width: 460)))
            item.label = title
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            return item
        }
        tabs.addTabViewItem(tab(String(localized: "General"), "gearshape", GeneralSettingsView()))
        tabs.addTabViewItem(tab(String(localized: "Appearance"), "textformat", AppearanceSettingsView()))
        tabs.addTabViewItem(tab(String(localized: "File Types"), "doc.text", FileTypesSettingsView()))
        tabs.addTabViewItem(tab(String(localized: "Advanced"), "wrench.and.screwdriver", AdvancedSettingsView()))

        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.title = String(localized: "Settings")
        window.center()
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

private struct GeneralSettingsView: View {
    @ObservedObject var settings = ReaderSettings.shared

    var body: some View {
        Form {
            Picker("Default reading mode", selection: $settings.defaultFlow) {
                ForEach(ReadingFlow.allCases) { Text($0.label).tag($0) }
            }
            Picker("Page layout", selection: $settings.pageLayout) {
                ForEach(PageLayout.allCases) { Text($0.label).tag($0) }
            }
            Toggle("Animate page turns", isOn: $settings.animatePageTurns)
            Toggle("Hyphenate text in paginated mode", isOn: $settings.hyphenate)
            Toggle("Show pages left in chapter", isOn: $settings.showPagesLeftInChapter)
            LabeledContent("First-run tips") {
                Button("Reset") { ReadingControlsExplainer.resetTips() }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct AppearanceSettingsView: View {
    @ObservedObject var settings = ReaderSettings.shared

    var body: some View {
        Form {
            Section {
                Toggle("Follow system appearance", isOn: $settings.followSystemAppearance)
                if settings.followSystemAppearance {
                    Picker("Light appearance", selection: $settings.lightTheme) {
                        ForEach(Theme.allCases) { Text($0.label).tag($0) }
                    }
                    Picker("Dark appearance", selection: $settings.darkTheme) {
                        ForEach(Theme.allCases) { Text($0.label).tag($0) }
                    }
                } else {
                    Picker("Theme", selection: $settings.fixedTheme) {
                        ForEach(Theme.allCases) { Text($0.label).tag($0) }
                    }
                }
            }
            Section {
                Picker("Font", selection: $settings.fontFamily) {
                    ForEach(ReaderSettings.curatedFonts, id: \.self) { name in
                        Text(name.isEmpty ? String(localized: "Publisher Default") : name).tag(name)
                    }
                }
                Picker("Text size", selection: $settings.fontSizeIndex) {
                    ForEach(ReaderSettings.fontSizes.indices, id: \.self) { i in
                        Text("\(Int(ReaderSettings.fontSizes[i])) pt").tag(i)
                    }
                }
                Picker("Line spacing", selection: $settings.lineHeight) {
                    ForEach(ReaderSettings.lineHeights, id: \.self) { value in
                        Text(value == 0 ? String(localized: "Publisher Default") : value.formatted(.number.precision(.fractionLength(1...2)))).tag(value)
                    }
                }
                Picker("Line width", selection: $settings.lineWidth) {
                    ForEach(LineWidth.allCases) { Text($0.label).tag($0) }
                }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// One row per supported type, with its current default app and a button to
/// make Platen the default.
private struct FileTypesSettingsView: View {
    struct Row: Identifiable {
        let id: String
        let label: String
        let type: UTType?
    }

    static let rows: [Row] = [
        Row(id: "org.idpf.epub-container", label: "EPUB (.epub, .kepub.epub)", type: UTType("org.idpf.epub-container")),
        Row(id: "com.kobo.kepub", label: "KEPUB (.kepub)", type: UTType("com.kobo.kepub")),
        Row(id: "com.amazon.mobi", label: "MOBI (.mobi)", type: UTType("com.amazon.mobi")),
        Row(id: "com.amazon.azw", label: "AZW (.azw)", type: UTType("com.amazon.azw")),
        Row(id: "com.amazon.azw3", label: "AZW3 (.azw3)", type: UTType("com.amazon.azw3")),
    ]

    @State private var defaults: [String: String] = [:]
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                ForEach(Self.rows) { row in
                    LabeledContent(row.label) {
                        HStack {
                            Text(defaults[row.id] ?? "—").foregroundStyle(.secondary)
                            Button("Make Platen the Default") { makeDefault([row]) }
                                .disabled(row.type == nil || defaults[row.id] == appName)
                        }
                    }
                }
            }
            Section {
                Button("Make Platen the Default for All") { makeDefault(Self.rows) }
                if let error { Text(error).foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear(perform: refresh)
    }

    private var appName: String { FileManager.default.displayName(atPath: Bundle.main.bundlePath) }

    private func refresh() {
        var result: [String: String] = [:]
        for row in Self.rows {
            if let type = row.type, let app = NSWorkspace.shared.urlForApplication(toOpen: type) {
                result[row.id] = FileManager.default.displayName(atPath: app.path)
            }
        }
        defaults = result
    }

    private func makeDefault(_ rows: [Row]) {
        Task { @MainActor in
            for row in rows {
                guard let type = row.type else { continue }
                do {
                    try await NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpen: type)
                } catch {
                    self.error = error.localizedDescription
                }
            }
            refresh()
        }
    }
}

private struct AdvancedSettingsView: View {
    @State private var confirmClear = false

    var body: some View {
        Form {
            LabeledContent("Reading positions and bookmarks") {
                Button("Clear…") { confirmClear = true }
            }
            LabeledContent("Data folder") {
                Button("Show in Finder") {
                    let folder = PositionStore.shared.directory
                    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    NSWorkspace.shared.activateFileViewerSelecting([folder])
                }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .confirmationDialog("Clear all reading positions and bookmarks?", isPresented: $confirmClear) {
            Button("Clear", role: .destructive) { try? PositionStore.shared.removeAll() }
        } message: {
            Text("Books will open at the beginning. This cannot be undone.")
        }
    }
}
