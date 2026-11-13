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
    /// iOS: opens the settings sheet (a gear button in the bar). The Mac
    /// has Platen Reader > Settings… instead, so leaves this out.
    var openSettings: (() -> Void)? = nil
    /// Mac PDFs: opens the file in Preview, for editing, signing or
    /// annotating (Platen only shows PDFs).
    var openInPreview: (() -> Void)? = nil
}

extension View {
    /// Popovers from the overlay stay popovers on iPhone too (iOS would
    /// otherwise turn them into full-height sheets).
    func platenPopover() -> some View {
        #if os(iOS)
        presentationCompactAdaptation(.popover)
        #else
        self
        #endif
    }
}

/// The bottom part of the overlay: location line, progress slider with
/// chapter ticks, page buttons, Contents, Back and the Aa (typography)
/// button. On the Mac the top part is the real window title bar, faded in by
/// the view controller; on iOS it is a floating Close button and the title.
///
/// On a narrow screen (an iPhone, or a narrow iPad window) the controls do
/// not fit in one row, so they stack: the location line, the slider between
/// the page buttons, then a row of buttons.
struct OverlayBar: View {
    @ObservedObject var state: ReaderState
    @ObservedObject var settings = ReaderSettings.shared
    let actions: OverlayActions
    let sidebarActions: ContentsActions

    @State private var dragFraction: Double?
    @State private var showTypography = false
    @State private var showLayout = false
    /// The bar is slightly see-through, and solid while the pointer is on it.
    @State private var hovering = false
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var isCompact: Bool { sizeClass == .compact }
    /// Touch screens have no hover, so the bar is always solid there.
    private let isTouch = true
    #else
    private let isCompact = false
    private let isTouch = false
    #endif

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
            locationRow
            if isCompact {
                HStack(spacing: 14) {
                    previousButton
                    slider
                    nextButton
                }
                .frame(minHeight: 32)
                HStack {
                    contentsButton
                    Spacer()
                    bookmarkButton
                    if showsLayoutButton {
                        Spacer()
                        layoutButton
                    }
                    Spacer()
                    typographyButton
                    if actions.openSettings != nil {
                        Spacer()
                        settingsButton
                    }
                }
                .frame(minHeight: 32)
            } else {
                HStack(spacing: 18) {
                    contentsButton
                    previousButton
                    slider
                    nextButton
                    bookmarkButton
                    if showsLayoutButton { layoutButton }
                    typographyButton
                    if actions.openInPreview != nil { previewButton }
                    if actions.openSettings != nil { settingsButton }
                }
                .frame(minHeight: 32)
            }
        }
        .buttonStyle(.borderless)
        .labelStyle(.iconOnly)
        .font(.title3)
        .imageScale(.large)
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        // Liquid Glass on macOS 26 / iOS 26 and later. Before that, the
        // material is slightly see-through (about 18%), so the bar reads as
        // something laid over the page; solid while the pointer is over it.
        .overlaySurface(RoundedRectangle(cornerRadius: 16, style: .continuous),
                        seeThrough: !(hovering || isTouch))
        #if os(iOS)
        // Icons in the text colour, as on the Mac (not the system blue).
        .tint(.primary)
        #endif
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.15)) { hovering = inside }
        }
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

    private var locationRow: some View {
        HStack {
            // Shown only after a jump, until the reader moves on.
            if let back = state.backLabel {
                Button {
                    actions.goBack()
                } label: {
                    Label(String(localized: "Back to \(back)"), systemImage: "arrow.uturn.backward")
                }
                // As before the bar's buttons were restyled: a normal button
                // with its name, not an icon-only one.
                .buttonStyle(.automatic)
                .labelStyle(.titleAndIcon)
                .font(.body)
                .imageScale(.medium)
                .help(String(localized: "Back to \(back) (⌘[)"))
            }
            Spacer(minLength: 0)
            Text(locationText)
                .font(.body)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .accessibilityLabel(Text("Location"))
                .accessibilityValue(Text(locationText))
            Spacer(minLength: 0)
        }
        .frame(minHeight: 22)
    }

    // Every button here has a Label (a name and an icon, shown as the icon
    // only): VoiceOver reads the name.

    private var contentsButton: some View {
        Button(action: actions.toggleContents) {
            Label(String(localized: "Contents, Bookmarks and Search"), systemImage: "list.bullet")
        }
        .help("Contents, Bookmarks and Search (⌘T)")
        .popover(isPresented: $state.sidebarVisible, arrowEdge: popoverEdge) {
            ContentsPopover(state: state, actions: sidebarActions)
        }
    }

    private var previousButton: some View {
        Button(action: state.isRightToLeft ? actions.nextPage : actions.previousPage) {
            Label((state.isRightToLeft ? String(localized: "Next Page") : String(localized: "Previous Page")), systemImage: "chevron.left")
        }
        .help((state.isRightToLeft ? String(localized: "Next Page") : String(localized: "Previous Page")))
    }

    private var nextButton: some View {
        Button(action: state.isRightToLeft ? actions.previousPage : actions.nextPage) {
            Label((state.isRightToLeft ? String(localized: "Previous Page") : String(localized: "Next Page")), systemImage: "chevron.right")
        }
        .help((state.isRightToLeft ? String(localized: "Previous Page") : String(localized: "Next Page")))
    }

    private var slider: some View {
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
    }

    /// Bookmarks the page on screen (or removes its bookmark).
    private var bookmarkButton: some View {
        Button(action: actions.toggleBookmark) {
            Label(state.isPageBookmarked ? String(localized: "Remove Bookmark") : String(localized: "Bookmark This Page"),
                  systemImage: state.isPageBookmarked ? "bookmark.fill" : "bookmark")
                .foregroundStyle(state.isPageBookmarked ? Color.red : Color.primary)
        }
        .help(state.isPageBookmarked ? String(localized: "Remove Bookmark (⌘D)") : String(localized: "Bookmark This Page (⌘D)"))
    }

    /// Layout: one page, two pages or scroll, and line width.
    private var layoutButton: some View {
        Button {
            showLayout.toggle()
            actions.interacted()
        } label: {
            Label(String(localized: "Layout"), systemImage: state.flow == .scrolled ? "scroll"
                  : settings.pageLayout == .two ? "book" : "doc.plaintext")
        }
        .help(String(localized: "Layout"))
        .popover(isPresented: $showLayout, arrowEdge: popoverEdge) {
            LayoutPopover(state: state, actions: actions)
        }
    }

    private var typographyButton: some View {
        Button {
            showTypography.toggle()
            actions.interacted()
        } label: {
            // "textformat" is the system's "Aa" symbol.
            Label(String(localized: "Text and Appearance"), systemImage: "textformat")
        }
        .help("Text and Appearance")
        .popover(isPresented: $showTypography, arrowEdge: popoverEdge) {
            TypographyPopover(state: state, actions: actions)
        }
    }

    /// On iOS a PDF's layout follows the orientation (one page in portrait,
    /// two in landscape), so there is nothing to choose.
    private var showsLayoutButton: Bool {
        #if os(iOS)
        !state.isPDF
        #else
        true
        #endif
    }

    private var previewButton: some View {
        Button {
            actions.openInPreview?()
        } label: {
            Label(String(localized: "Open in Preview"), systemImage: "arrow.up.forward.app")
        }
        .help(String(localized: "Open in Preview, to edit, sign or annotate"))
    }

    private var settingsButton: some View {
        Button {
            actions.openSettings?()
        } label: {
            Label(String(localized: "Settings"), systemImage: "gearshape")
        }
    }

    /// Popovers hang above the bar (it sits at the bottom of the screen).
    /// The two platforms read the edge differently: the Mac needs .top for a
    /// popover above the button, iOS needs .bottom.
    #if os(iOS)
    private var popoverEdge: Edge { .bottom }
    #else
    private var popoverEdge: Edge { .top }
    #endif
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
            // PDFs: only the theme applies (it colours the area around the
            // page); text size, font and spacing are the PDF's own.
            if !state.isPDF { textControls }
            Picker("Appearance", selection: $settings.appearance) {
                ForEach(AppearanceChoice.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.menu)
        }
        .formStyle(.grouped)
        #if os(iOS)
        // A form in a popover has no height of its own on iOS.
        .frame(width: 340, height: state.isPDF ? 110 : 300)
        #else
        .frame(width: 360)
        .fixedSize(horizontal: false, vertical: true)
        #endif
        // VoiceOver names the popover rather than saying "scroll area".
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Text and Appearance"))
        .platenPopover()
    }

    @ViewBuilder private var textControls: some View {
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
    }
}

/// The layout popover: one page, two pages or scroll, and the line width.
struct LayoutPopover: View {
    @ObservedObject var state: ReaderState
    @ObservedObject var settings = ReaderSettings.shared
    let actions: OverlayActions

    var body: some View {
        Form {
            Picker("Layout", selection: Binding(get: { state.currentLayout }, set: actions.setLayout)) {
                ForEach(state.availableLayouts) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .help(String(localized: "⌘1 one page, ⌘2 two pages, ⌘3 scroll"))

            if state.twoPagesTooNarrow {
                Text("The window is too narrow for two pages. Make it wider to see them side by side.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !state.isPDF {
                Picker("Line Width", selection: $settings.lineWidth) {
                    ForEach(LineWidth.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .disabled(state.isFixedLayout)
            }
        }
        .formStyle(.grouped)
        #if os(iOS)
        .frame(width: 340, height: state.twoPagesTooNarrow ? 230 : 180)
        #else
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
        #endif
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Layout"))
        .platenPopover()
    }
}
