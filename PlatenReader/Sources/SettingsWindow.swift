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
            // Each tab sizes the window to its content (the standard Settings
            // behaviour), rather than one height that cut off the longest.
            let hosting = NSHostingController(rootView: view.frame(width: 460))
            hosting.sizingOptions = [.preferredContentSize]
            let item = NSTabViewItem(viewController: hosting)
            item.label = title
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            return item
        }
        // Four tabs: how books look (Appearance), the voices that read them
        // (Read Aloud), which files open here (File Types), and housekeeping
        // (Advanced).
        tabs.addTabViewItem(tab(String(localized: "Appearance"), "textformat", AppearanceSettingsView()))
        tabs.addTabViewItem(tab(String(localized: "Read Aloud"), "speaker.wave.2", ReadAloudSettingsView()))
        tabs.addTabViewItem(tab(String(localized: "File Types"), "doc.text", FileTypesSettingsView()))
        tabs.addTabViewItem(tab(String(localized: "Advanced"), "wrench.and.screwdriver", AdvancedSettingsView()))

        // The tabs' views have no titles of their own; without this the
        // window would take the (empty) title of the selected tab and show
        // "Untitled".
        tabs.canPropagateSelectedChildViewControllerTitle = false
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.title = String(localized: "Platen Reader")
        window.center()
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

/// Appearance: a preview of the text as set, then the same two groups as
/// the controls over the page. Text matches the Aa popover; Layout matches
/// the Layout popover.
private struct AppearanceSettingsView: View {
    @ObservedObject var settings = ReaderSettings.shared
    @ObservedObject var frontWindow = FrontWindowLayout.shared

    var body: some View {
        Form {
            Section {
                TextPreview(settings: settings)
                    .frame(height: 132)
                    .listRowInsets(EdgeInsets())
            }
            Section("Text") {
                Picker("Font", selection: $settings.fontFamily) {
                    ForEach(ReaderSettings.curatedFonts, id: \.self) { name in
                        Text(name.isEmpty ? String(localized: "Publisher Default") : name).tag(name)
                    }
                }
                Picker("Size", selection: $settings.fontSizeIndex) {
                    ForEach(ReaderSettings.fontSizes.indices, id: \.self) { i in
                        Text("\(Int(ReaderSettings.fontSizes[i])) pt").tag(i)
                    }
                }
                Picker("Line spacing", selection: $settings.lineHeight) {
                    ForEach(ReaderSettings.lineHeights, id: \.self) { value in
                        Text(value == 0 ? String(localized: "Publisher Default") : value.formatted(.number.precision(.fractionLength(1...2)))).tag(value)
                    }
                }
                Toggle("Justify", isOn: $settings.justify)
                Toggle(isOn: $settings.hyphenate) {
                    Text("Hyphenate")
                    Text("Breaks long words at the ends of lines on pages (not when scrolling).")
                }
                LabeledContent("Theme") {
                    ThemeSwatches(selection: $settings.appearance)
                }
                Text("Automatic matches macOS: Light in Light Mode, Dark in Dark Mode.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Layout") {
                Picker("Layout", selection: $settings.defaultLayout) {
                    ForEach(ReadingLayout.allCases) { Text("\($0.label) (⌘\($0.shortcut))").tag($0) }
                }
                if settings.pageLayout == .two && frontWindow.tooNarrowForTwoPages {
                    Text("The book window is too narrow for two pages. Make it wider to see them side by side.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Picker("Line width", selection: $settings.lineWidth) {
                    ForEach(LineWidth.allCases) { Text($0.label).tag($0) }
                }
                Picker("Page turn", selection: $settings.pageTurnStyle) {
                    ForEach(PageTurnStyle.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Show pages left in chapter", isOn: $settings.showPagesLeftInChapter)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// A few lines of a book as they would be set now: the font, size, line
/// spacing, justification and hyphenation chosen, on the theme's page and
/// in its ink, so a change can be seen without a book open. (AppKit's text
/// view, as SwiftUI's text cannot justify or hyphenate.)
private struct TextPreview: NSViewRepresentable {
    @ObservedObject var settings: ReaderSettings
    @Environment(\.colorScheme) private var colorScheme

    // Austen (public domain), the opening of Pride and Prejudice.
    private static let sample = "It is a truth universally acknowledged, that a single man in possession of a good "
        + "fortune, must be in want of a wife. However little known the feelings or views of such a man may be on "
        + "his first entering a neighbourhood, this truth is so well fixed in the minds of the surrounding "
        + "families, that he is considered as the rightful property of some one or other of their daughters."

    func makeNSView(context: Context) -> NSTextView {
        let view = NSTextView()
        view.isEditable = false
        view.isSelectable = false
        view.drawsBackground = true
        view.textContainerInset = NSSize(width: 18, height: 14)
        view.textContainer?.lineFragmentPadding = 0
        view.setAccessibilityLabel(String(localized: "Preview of the text"))
        return view
    }

    func updateNSView(_ view: NSTextView, context: Context) {
        let theme = settings.theme(systemIsDark: colorScheme == .dark)
        let size = settings.fontSize
        let font = settings.fontFamily.isEmpty ? NSFont(name: "Iowan Old Style", size: size) ?? .systemFont(ofSize: size)
            : NSFont(name: settings.fontFamily, size: size) ?? NSFont(name: "Iowan Old Style", size: size) ?? .systemFont(ofSize: size)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = settings.justify ? .justified : .natural
        paragraph.hyphenationFactor = settings.hyphenate ? 1 : 0
        // Publisher Default leaves spacing to the book: about 1.25 is typical.
        let spacing = settings.lineHeight == 0 ? 1.25 : settings.lineHeight
        paragraph.lineHeightMultiple = spacing / max(font.ascender - font.descender + font.leading, 1) * size
        view.backgroundColor = NSColor(Color(hex: theme.background))
        view.textStorage?.setAttributedString(NSAttributedString(string: Self.sample, attributes: [
            .font: font, .foregroundColor: NSColor(Color(hex: theme.foreground)), .paragraphStyle: paragraph,
        ]))
    }
}

/// The page themes as swatches of their own colours, with a name under
/// each; Automatic is half Light, half Dark. The chosen one is ringed in the
/// accent.
private struct ThemeSwatches: View {
    @Binding var selection: AppearanceChoice

    var body: some View {
        HStack(spacing: 12) {
            ForEach(AppearanceChoice.allCases) { choice in
                Button {
                    selection = choice
                } label: {
                    VStack(spacing: 4) {
                        swatch(choice)
                            .frame(width: 34, height: 24)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.18), lineWidth: 0.5))
                            .padding(2.5)
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(selection == choice ? Color.platenAccent : .clear, lineWidth: 2))
                        Text(choice.label)
                            .font(.caption)
                            .foregroundStyle(selection == choice ? .primary : .secondary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(choice.label))
                .accessibilityAddTraits(selection == choice ? .isSelected : [])
            }
        }
    }

    @ViewBuilder private func swatch(_ choice: AppearanceChoice) -> some View {
        switch choice {
        case .automatic:
            HStack(spacing: 0) { page(.light); page(.dark) }
        case .light: page(.light)
        case .sepia: page(.sepia)
        case .dark: page(.dark)
        case .black: page(.black)
        }
    }

    /// A tiny page: the theme's paper with two lines of its ink.
    private func page(_ theme: Theme) -> some View {
        ZStack {
            Color(hex: theme.background)
            VStack(alignment: .leading, spacing: 3) {
                Capsule().fill(Color(hex: theme.foreground)).frame(width: 14, height: 2)
                Capsule().fill(Color(hex: theme.foreground)).frame(width: 10, height: 2)
            }
        }
    }
}

/// One row per supported type, with its current default app and a button to
/// make Platen the default.
private struct FileTypesSettingsView: View {
    struct Row: Identifiable {
        let id: String
        let label: String
        let type: UTType?
        /// Whether "Make Platen the Default for All" includes it. Plain text
        /// does not: most text files on a Mac are not books.
        var inAll = true
    }

    static let rows: [Row] = [
        Row(id: "org.idpf.epub-container", label: "EPUB (.epub, .kepub.epub)", type: UTType("org.idpf.epub-container")),
        Row(id: "com.kobo.kepub", label: "KEPUB (.kepub)", type: UTType("com.kobo.kepub")),
        Row(id: "com.amazon.mobi", label: "MOBI (.mobi)", type: UTType("com.amazon.mobi")),
        Row(id: "com.amazon.azw", label: "AZW (.azw)", type: UTType("com.amazon.azw")),
        Row(id: "com.amazon.azw3", label: "AZW3 (.azw3)", type: UTType("com.amazon.azw3")),
        Row(id: "public.plain-text", label: "Plain Text (.txt)", type: .plainText, inAll: false),
        // PDFs: listed so Platen can be chosen, but never made the default
        // by "for All" (spec, "PDF": unless the user chooses it).
        Row(id: "com.adobe.pdf", label: "PDF (.pdf)", type: .pdf, inAll: false),
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
                Button("Make Platen the Default for All Ebooks") { makeDefault(Self.rows.filter(\.inAll)) }
                Text("Plain text is left out, since most text files are not books. Use its own button to open all text files in Platen.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
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

/// Settings › Read Aloud: the shared section (ReadAloudSettingsSection).
private struct ReadAloudSettingsView: View {
    var body: some View {
        Form { ReadAloudSettingsSection() }
            .formStyle(.grouped)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct AdvancedSettingsView: View {
    @State private var confirmClear = false

    var body: some View {
        Form {
            Section {
                LabeledContent("First-run tips") {
                    Button("Show Again") { ReadingControlsExplainer.resetTips() }
                }
            } footer: {
                Text("Shows the click zones again for the next five books you open.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Reading positions and bookmarks") {
                    Button("Clear…") { confirmClear = true }
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
