import SwiftUI

/// Callbacks from the overlay to the reader.
struct OverlayActions {
    var previousPage: () -> Void
    var nextPage: () -> Void
    var goToFraction: (Double) -> Void
    var goBack: () -> Void
    var toggleContents: () -> Void
    var setLayout: (ReadingLayout) -> Void
    var toggleBookmark: () -> Void
    /// Called whenever the user interacts, so the overlay does not auto-hide
    /// while it is being used.
    var interacted: () -> Void
}

/// The bottom part of the overlay: location line, progress slider with
/// chapter ticks, page buttons, Contents, Back and the Aa (typography)
/// button. The top part is the real window title bar, faded in by the view
/// controller.
struct OverlayBar: View {
    @ObservedObject var state: ReaderState
    @ObservedObject var settings = ReaderSettings.shared
    let actions: OverlayActions
    let sidebarActions: SidebarActions

    @State private var dragFraction: Double?
    @State private var showTypography = false
    @State private var showLayout = false
    /// The bar is slightly see-through, and solid while the pointer is on it.
    @State private var hovering = false

    private var locationText: String {
        if let f = dragFraction {
            // While dragging: the chapter at the slider position, and where.
            let percent = f.formatted(.percent.precision(.fractionLength(0)))
            return [state.chapter(atFraction: f), percent].compactMap { $0 }.joined(separator: " · ")
        }
        return state.locationLine(showPagesLeft: settings.showPagesLeftInChapter)
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                // Shown only after a jump, until the reader moves on.
                if let back = state.backLabel {
                    Button {
                        actions.goBack()
                    } label: {
                        Label(String(localized: "Back to \(back)"), systemImage: "arrow.uturn.backward")
                    }
                    .help(String(localized: "Back to \(back) (⌘[)"))
                }
                Spacer(minLength: 0)
                Text(locationText)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityLabel(Text("Location"))
                    .accessibilityValue(Text(locationText))
                Spacer(minLength: 0)
            }
            .frame(minHeight: 22)

            HStack(spacing: 18) {
                Button(action: actions.toggleContents) {
                    Image(systemName: "list.bullet")
                }
                .help("Contents, Bookmarks and Search (⌘T)")
                .accessibilityLabel(Text("Contents, Bookmarks and Search"))
                .popover(isPresented: $state.sidebarVisible, arrowEdge: .top) {
                    SidebarView(state: state, actions: sidebarActions)
                }

                Button(action: state.isRightToLeft ? actions.nextPage : actions.previousPage) {
                    Image(systemName: "chevron.left")
                }
                .help(state.isRightToLeft ? "Next Page" : "Previous Page")
                .accessibilityLabel(state.isRightToLeft ? Text("Next Page") : Text("Previous Page"))

                ProgressSlider(
                    value: Binding(
                        get: { dragFraction ?? state.fraction },
                        set: { dragFraction = $0; actions.interacted() }
                    ),
                    ticks: state.sectionFractions,
                    rightToLeft: state.isRightToLeft,
                    onEditingChanged: { editing in
                        if !editing, let f = dragFraction {
                            actions.goToFraction(f)
                            // Keep showing the target until the reader catches up.
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { dragFraction = nil }
                        }
                    }
                )

                Button(action: state.isRightToLeft ? actions.previousPage : actions.nextPage) {
                    Image(systemName: "chevron.right")
                }
                .help(state.isRightToLeft ? "Previous Page" : "Next Page")
                .accessibilityLabel(state.isRightToLeft ? Text("Previous Page") : Text("Next Page"))

                // Bookmarks the page on screen (or removes its bookmark).
                Button(action: actions.toggleBookmark) {
                    Image(systemName: state.isPageBookmarked ? "bookmark.fill" : "bookmark")
                        .foregroundStyle(state.isPageBookmarked ? Color.red : Color.primary)
                }
                .help(state.isPageBookmarked ? String(localized: "Remove Bookmark (⌘D)") : String(localized: "Bookmark This Page (⌘D)"))
                .accessibilityLabel(state.isPageBookmarked ? Text("Remove Bookmark") : Text("Bookmark This Page"))

                // Layout: one page, two pages or scroll, and line width.
                Button {
                    showLayout.toggle()
                    actions.interacted()
                } label: {
                    Image(systemName: state.flow == .scrolled ? "scroll"
                          : settings.pageLayout == .two ? "book" : "doc.plaintext")
                }
                .help(String(localized: "Layout"))
                .accessibilityLabel(Text("Layout"))
                .popover(isPresented: $showLayout, arrowEdge: .top) {
                    LayoutPopover(state: state, actions: actions)
                }

                Button {
                    showTypography.toggle()
                    actions.interacted()
                } label: {
                    Text("Aa").font(.title3.weight(.medium))
                }
                .help("Text and Appearance")
                .accessibilityLabel(Text("Text and Appearance"))
                .popover(isPresented: $showTypography, arrowEdge: .top) {
                    TypographyPopover(state: state, actions: actions)
                }
            }
            .buttonStyle(.borderless)
            .font(.title3)
            .imageScale(.large)
            .frame(minHeight: 32)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        // Slightly see-through (about 18%), so the bar reads as something
        // laid over the page; solid while the pointer is over it.
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.regularMaterial)
                .opacity(hovering ? 1 : 0.82)
        }
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.15)) { hovering = inside }
        }
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.separator, lineWidth: 0.5))
        .frame(maxWidth: 760)
        // The overlay must stay while its popover is open.
        .onChange(of: showTypography || showLayout) { _, open in
            state.overlayPopoverOpen = open
            actions.interacted()
        }
        // One popover at a time.
        .onChange(of: state.sidebarVisible) { _, open in if open { showTypography = false; showLayout = false } }
        .onChange(of: showTypography) { _, open in if open { showLayout = false } }
        .onChange(of: showLayout) { _, open in if open { showTypography = false } }
    }
}

/// The progress slider: a thin track with tick marks at chapter starts and
/// a round knob. Drawn by hand because the system slider's knob is a pill.
/// Click anywhere on the track to jump there, or drag the knob.
struct ProgressSlider: View {
    @Binding var value: Double
    let ticks: [Double]
    var rightToLeft = false
    let onEditingChanged: (Bool) -> Void

    @State private var dragging = false
    private let knob: CGFloat = 18
    private let track: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            let usable = max(geo.size.width - knob, 1)
            // Position along the track, mirrored for right-to-left books.
            let position = { (f: Double) -> CGFloat in
                knob / 2 + usable * CGFloat(rightToLeft ? 1 - f : f)
            }
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.15))
                    .frame(height: track)
                    .padding(.horizontal, knob / 2)
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: max(0, abs(position(value) - position(0))), height: track)
                    .offset(x: rightToLeft ? position(value) : knob / 2)
                ForEach(Array(ticks.dropFirst().dropLast().enumerated()), id: \.offset) { _, tick in
                    Rectangle()
                        .fill(Color.primary.opacity(0.3))
                        .frame(width: 1, height: 10)
                        .offset(x: position(tick))
                }
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.3), radius: 1.5, y: 0.5)
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5))
                    .frame(width: knob, height: knob)
                    .scaleEffect(dragging ? 1.12 : 1)
                    .offset(x: position(value) - knob / 2)
                    .animation(.easeOut(duration: 0.1), value: dragging)
            }
            .frame(height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        if !dragging { dragging = true; onEditingChanged(true) }
                        var f = Double((drag.location.x - knob / 2) / usable)
                        if rightToLeft { f = 1 - f }
                        value = min(max(f, 0), 1)
                    }
                    .onEnded { _ in
                        dragging = false
                        onEditingChanged(false)
                    }
            )
        }
        .frame(height: 28)
        .accessibilityElement()
        .accessibilityLabel(Text("Progress"))
        .accessibilityValue(Text(value.formatted(.percent.precision(.fractionLength(0)))))
        .accessibilityAdjustableAction { direction in
            let step = 0.01
            let f = direction == .increment ? value + step : value - step
            onEditingChanged(true)
            value = min(max(f, 0), 1)
            onEditingChanged(false)
        }
    }
}

/// The Aa popover: text size, font, line spacing and appearance. These are
/// the same global settings as in Settings.
struct TypographyPopover: View {
    @ObservedObject var state: ReaderState
    @ObservedObject var settings = ReaderSettings.shared
    let actions: OverlayActions

    var body: some View {
        Form {
            LabeledContent("Text Size") {
                HStack(spacing: 8) {
                    Button { settings.smallerText() } label: { Image(systemName: "textformat.size.smaller") }
                        .disabled(settings.fontSizeIndex == 0)
                        .accessibilityLabel(Text("Smaller Text"))
                    Text("\(Int(settings.fontSize)) pt").monospacedDigit().frame(minWidth: 44)
                    Button { settings.biggerText() } label: { Image(systemName: "textformat.size.larger") }
                        .disabled(settings.fontSizeIndex == ReaderSettings.fontSizes.count - 1)
                        .accessibilityLabel(Text("Larger Text"))
                }
            }
            .disabled(state.isFixedLayout)

            Picker("Font", selection: $settings.fontFamily) {
                ForEach(ReaderSettings.curatedFonts, id: \.self) { name in
                    Text(name.isEmpty ? String(localized: "Publisher Default") : name).tag(name)
                }
            }
            .disabled(state.isFixedLayout)

            Picker("Line Spacing", selection: $settings.lineHeight) {
                ForEach(ReaderSettings.lineHeights, id: \.self) { value in
                    Text(value == 0 ? String(localized: "Publisher Default") : value.formatted(.number.precision(.fractionLength(1...2)))).tag(value)
                }
            }
            .disabled(state.isFixedLayout)

            Picker("Appearance", selection: $settings.appearance) {
                ForEach(AppearanceChoice.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.menu)
        }
        .formStyle(.grouped)
        .frame(width: 360)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// The layout popover: one page, two pages or scroll, and the line width.
struct LayoutPopover: View {
    @ObservedObject var state: ReaderState
    @ObservedObject var settings = ReaderSettings.shared
    let actions: OverlayActions

    var body: some View {
        Form {
            Picker("Layout", selection: Binding(get: { ReadingLayout(flow: state.flow, pages: settings.pageLayout) },
                                                set: actions.setLayout)) {
                ForEach(ReadingLayout.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .help(String(localized: "⌘1 one page, ⌘2 two pages, ⌘3 scroll"))

            if state.twoPagesTooNarrow {
                Text("The window is too narrow for two pages. Make it wider to see them side by side.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Picker("Line Width", selection: $settings.lineWidth) {
                ForEach(LineWidth.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .disabled(state.isFixedLayout)
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Shown in place of the page when a book cannot be opened.
struct OpenFailureView: View {
    let title: String
    let detail: String?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "book.closed")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let detail {
                Text(detail)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(40)
        .frame(width: 460)
        .textSelection(.enabled)
    }
}
