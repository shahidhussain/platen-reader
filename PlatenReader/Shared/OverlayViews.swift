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

/// The overlay's controls: location line, progress slider with chapter
/// ticks, page buttons, Contents, Back and the Aa (typography) button. On the
/// Mac they are one bar at the bottom, and the top part is the real window
/// title bar, faded in by the view controller. On iOS they are split (see
/// `Part`), beside a floating Close button and the title (ReaderChrome).
struct OverlayBar: View {
    @ObservedObject var state: ReaderState
    @ObservedObject var settings = ReaderSettings.shared
    let actions: OverlayActions
    let sidebarActions: ContentsActions
    /// Which part of the overlay this view draws (see `Part`).
    var part: Part = .whole

    /// The Mac draws the whole bar as one panel at the bottom of the window.
    /// iOS splits it, in the way of Apple's own iOS 26 apps: the buttons are
    /// a small glass group at the top right, beside the Close button, and the
    /// slider floats at the bottom with ‹ and › at its ends.
    enum Part { case whole, buttons, scrubber }

    @State private var dragFraction: Double?
    @State private var showTypography = false
    @State private var showLayout = false
    /// The bar is slightly see-through, and solid while the pointer is on it.
    @State private var hovering = false
    #if os(iOS)
    /// Touch screens have no hover, so the bar is always solid there.
    private let isTouch = true
    #else
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
        switch part {
        case .whole: wholeBar
        case .buttons: buttonGroup
        case .scrubber: scrubber
        }
    }

    // MARK: - iOS: the buttons, and the floating slider

    /// Contents, bookmark, layout, Aa and settings, side by side on one
    /// piece of glass.
    private var buttonGroup: some View {
        HStack(spacing: 0) {
            contentsButton.frame(width: 44, height: 44)
            bookmarkButton.frame(width: 44, height: 44)
            layoutButton.frame(width: 44, height: 44)
            typographyButton.frame(width: 44, height: 44)
            if actions.openSettings != nil { settingsButton.frame(width: 44, height: 44) }
        }
        .buttonStyle(.borderless)
        .labelStyle(.iconOnly)
        .font(.body.weight(.medium))
        .imageScale(.large)
        .padding(.horizontal, 4)
        .overlaySurface(Capsule())
        .tint(.primary)
        .popoverBookkeeping(state: state, actions: actions, showTypography: $showTypography, showLayout: $showLayout)
    }

    /// Where the reader is, and the slider between round ‹ › buttons, each
    /// on its own small piece of glass, so the page shows around them.
    private var scrubber: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                if let back = state.backLabel {
                    Button {
                        actions.goBack()
                    } label: {
                        Label(String(localized: "Back to \(back)"), systemImage: "arrow.uturn.backward")
                            .labelStyle(.titleAndIcon)
                            .font(.subheadline)
                            .lineLimit(1)
                            .padding(.horizontal, 12)
                            .frame(minHeight: 32)
                            .overlaySurface(Capsule())
                    }
                    .buttonStyle(.plain)
                }
                Text(locationText)
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 32)
                    .overlaySurface(Capsule())
                    .accessibilityLabel(Text("Location"))
                    .accessibilityValue(Text(locationText))
            }
            HStack(spacing: 8) {
                previousButton
                    .frame(width: 44, height: 44)
                    .overlaySurface(Circle())
                slider
                    .padding(.horizontal, 16)
                    .frame(height: 44)
                    .overlaySurface(Capsule())
                nextButton
                    .frame(width: 44, height: 44)
                    .overlaySurface(Circle())
            }
        }
        .buttonStyle(.borderless)
        .labelStyle(.iconOnly)
        .font(.body.weight(.semibold))
        .tint(.primary)
        .glassGroup(spacing: 8)
        .frame(maxWidth: 760)
    }

    // MARK: - The Mac's bar

    private var wholeBar: some View {
        VStack(spacing: 10) {
            locationRow
            HStack(spacing: 18) {
                contentsButton
                previousButton
                slider
                nextButton
                bookmarkButton
                layoutButton
                typographyButton
                if actions.openSettings != nil { settingsButton }
            }
            .frame(minHeight: 32)
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
        .popoverBookkeeping(state: state, actions: actions, showTypography: $showTypography, showLayout: $showLayout)
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
            // The layout in use (an iPhone shows one page whatever the
            // Two Pages setting says).
            Label(String(localized: "Layout"), systemImage: state.currentLayout == .scroll ? "scroll"
                  : state.currentLayout == .twoPages ? "book" : "doc.plaintext")
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

    private var settingsButton: some View {
        Button {
            actions.openSettings?()
        } label: {
            Label(String(localized: "Settings"), systemImage: "gearshape")
        }
    }

    /// Popovers hang above the bar at the bottom of the screen, and below
    /// the buttons at the top on iOS. The two platforms read the edge
    /// differently: the Mac needs .top for a popover above the button, iOS
    /// .bottom (and .top for one below).
    #if os(iOS)
    private var popoverEdge: Edge { part == .buttons ? .top : .bottom }
    #else
    private var popoverEdge: Edge { .top }
    #endif
}

private extension View {
    /// Keeps the overlay up while one of its popovers is open, and allows
    /// one popover at a time.
    func popoverBookkeeping(state: ReaderState, actions: OverlayActions,
                            showTypography: Binding<Bool>, showLayout: Binding<Bool>) -> some View {
        onChange(of: showTypography.wrappedValue || showLayout.wrappedValue) { _, open in
            state.overlayPopoverOpen = open
            actions.interacted()
        }
        .onChange(of: state.sidebarVisible) { _, open in
            if open { showTypography.wrappedValue = false; showLayout.wrappedValue = false }
        }
        .onChange(of: showTypography.wrappedValue) { _, open in if open { showLayout.wrappedValue = false } }
        .onChange(of: showLayout.wrappedValue) { _, open in if open { showTypography.wrappedValue = false } }
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
                ForEach(state.availableLayouts) { Text(label(for: $0)).tag($0) }
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
        // PDFs have only the layout picker (no line width).
        .frame(width: 340, height: state.isPDF ? 90 : state.twoPagesTooNarrow ? 230 : 180)
        #else
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
        #endif
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Layout"))
        .platenPopover()
    }

    /// On iOS a PDF in pages shows one page in portrait and two in landscape
    /// (spec, "PDF"), so that choice is called Pages rather than One Page.
    private func label(for layout: ReadingLayout) -> String {
        #if os(iOS)
        if state.isPDF, layout == .onePage { return String(localized: "Pages") }
        #endif
        return layout.label
    }
}
