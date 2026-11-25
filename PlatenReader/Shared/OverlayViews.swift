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
    /// The speaker button's actions, on the Mac's bar (iOS has the speaker
    /// in its top bar); nil where the reader cannot read aloud.
    var readAloud: ReadAloudButtonActions? = nil
    /// Called whenever the user interacts, so the overlay does not auto-hide
    /// while it is being used.
    var interacted: () -> Void
}

/// The band behind the controls at the top or bottom of the page: the
/// page's own colour, solid at the screen's edge and fading into the page
/// towards the text (as Apple Books does), so no letter is ever seen behind
/// a control, in any theme. `fade` is how tall the fading part is; it is
/// drawn inside the view, at the side facing the page.
struct PageBand: View {
    let colour: String
    let edge: VerticalEdge
    var fade: CGFloat = 24

    var body: some View {
        let page = Color(hex: colour)
        VStack(spacing: 0) {
            if edge == .bottom {
                LinearGradient(stops: Self.easedStops(page).reversed().map { .init(color: $0.color, location: 1 - $0.location) },
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: fade)
                page
            } else {
                page
                LinearGradient(stops: Self.easedStops(page), startPoint: .top, endPoint: .bottom)
                    .frame(height: fade)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// The fade from the band into the page: an S-curve (smoothstep), not a
    /// straight line, so it eases out of the band and into the page with no
    /// visible edge at either end. A straight fade over a bright picture
    /// read as a hard line where it began (device testing, 21 Nov 2026).
    static func easedStops(_ colour: Color) -> [Gradient.Stop] {
        (0...12).map { step in
            let t = Double(step) / 12
            let eased = t * t * (3 - 2 * t)
            return .init(color: colour.opacity(1 - eased), location: t)
        }
    }
}

/// `PageBand` in the colour of the reader's page, following the theme.
struct ReaderPageBand: View {
    @ObservedObject var state: ReaderState
    let edge: VerticalEdge
    var fade: CGFloat = 24

    var body: some View {
        PageBand(colour: state.pageColour, edge: edge, fade: fade)
    }
}

extension Color {
    /// The app's accent, a bright warm orange (Shared/Colours.xcassets: light and
    /// dark variants). Named, rather than `accentColor`, where it must not
    /// follow the Mac's own accent colour (System Settings → Appearance),
    /// such as the progress slider.
    static let platenAccent = Color("Accent")

    /// "#rrggbb" → Color (sRGB), for the themes' colours.
    init(hex: String) {
        let value = UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0
        self.init(.sRGB, red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255)
    }
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

#if os(iOS)
/// The body of an iOS popover from the overlay: rows straight on the
/// popover's own glass (no panel of their own), 300 points wide (or as
/// given) and as tall as they need, so the popover fits them and never scrolls.
struct PopoverRows<Content: View>: View {
    var width: CGFloat = 300
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .padding(.vertical, 6)
            .frame(width: width)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A hairline between popover rows, inset from the leading edge.
struct PopoverDivider: View {
    var inset: CGFloat = 16

    var body: some View {
        Divider().padding(.leading, inset)
    }
}

extension View {
    /// A popover row: a finger-sized height and the popover's side margins.
    func popoverRow(minHeight: CGFloat = 46) -> some View {
        padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: minHeight)
    }
}
#endif

/// The overlay's controls: location line, progress slider with chapter
/// ticks, page buttons, Contents, Back and the Aa (typography) button. On the
/// Mac they are one bar at the bottom, and the top part is the real window
/// title bar, faded in by the view controller. On iOS they are the bottom
/// bar (`Part.bottomBar`), under the top bar of Close and the title
/// (ReaderChrome).
struct OverlayBar: View {
    @ObservedObject var state: ReaderState
    @ObservedObject var settings = ReaderSettings.shared
    let actions: OverlayActions
    let sidebarActions: ContentsActions
    /// Which part of the overlay this view draws (see `Part`).
    var part: Part = .whole

    /// The Mac draws the whole bar as one panel at the bottom of the window.
    /// iOS draws a bottom bar across the screen, on a band of the page's
    /// colour: where the reader is (or "Back to …" after a jump), the
    /// slider, then one row of buttons. Pages turn by tapping or swiping the
    /// page's edges, so there are no ‹ › buttons on iOS.
    enum Part { case whole, bottomBar }

    @State private var dragFraction: Double?
    /// The popover that is open, if any: one at a time.
    @State private var openPopover: Popover?
    private enum Popover { case typography, layout }
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
        case .bottomBar: bottomBar
        }
    }

    // MARK: - iOS: the bottom bar

    /// Where the reader is, the slider, and the buttons, on the page's own
    /// colour (ReaderChrome puts the band behind it). The buttons are plain
    /// symbols on the band, as in Apple Books, not pieces of glass.
    private var bottomBar: some View {
        VStack(spacing: 2) {
            HStack(spacing: 8) {
                // Shown only after a jump, until the reader moves on.
                if let back = state.backLabel {
                    Button {
                        actions.goBack()
                    } label: {
                        Label(String(localized: "Back to \(back)"), systemImage: "arrow.uturn.backward")
                            .labelStyle(.titleAndIcon)
                            .font(.footnote.weight(.semibold))
                            .lineLimit(1)
                    }
                    .buttonStyle(.borderless)
                    .tint(.platenAccent)
                    Spacer(minLength: 8)
                }
                Text(locationText)
                    .font(.footnote)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityLabel(Text("Location"))
                    .accessibilityValue(Text(locationText))
            }
            .frame(maxWidth: .infinity, minHeight: 24)
            slider
                .frame(height: 36)
            HStack(spacing: 0) {
                contentsButton.frame(maxWidth: .infinity, minHeight: 44)
                bookmarkButton.scaleEffect(x: 1.15, y: 1).frame(maxWidth: .infinity, minHeight: 44)
                layoutButton.frame(maxWidth: .infinity, minHeight: 44)
                typographyButton.frame(maxWidth: .infinity, minHeight: 44)
            }
            .labelStyle(.iconOnly)
            .font(.body.weight(.medium))
            .imageScale(.large)
            .tint(.primary)
        }
        .buttonStyle(.borderless)
        .frame(maxWidth: 600)
        .popoverBookkeeping(state: state, actions: actions, openPopover: $openPopover)
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
                if let readAloud = actions.readAloud {
                    ReadAloudButton(phase: state.readAloud, actions: readAloud)
                }
                layoutButton
                typographyButton
            }
            // The symbols a step larger than the system's default, of one
            // weight (the chevrons too), in the text colour: plain controls
            // that read clearly against the bar. The accent marks a state
            // only (a bookmarked page).
            .font(.title2)
            .fontWeight(.medium)
            .imageScale(.medium)
            .foregroundStyle(.primary)
            .frame(minHeight: 32)
        }
        .buttonStyle(.borderless)
        .labelStyle(.iconOnly)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        // Liquid Glass on macOS 26 / iOS 26 and later. Before that, the
        // material is slightly see-through (about 18%), so the bar reads as
        // something laid over the page; solid while the pointer is over it.
        .overlaySurface(RoundedRectangle(cornerRadius: 22, style: .continuous),
                        seeThrough: !(hovering || isTouch))
        #if os(iOS)
        // Icons in the text colour, as on the Mac (not the system blue).
        .tint(.primary)
        #endif
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.15)) { hovering = inside }
        }
        .frame(maxWidth: 760)
        .popoverBookkeeping(state: state, actions: actions, openPopover: $openPopover)
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

    /// A bookmarked page's symbol: the app's one accent, the orange of the
    /// ribbon on the page.
    private static let bookmarkedColour = Color.platenAccent

    /// Bookmarks the page on screen (or removes its bookmark).
    private var bookmarkButton: some View {
        Button(action: actions.toggleBookmark) {
            Label(state.isPageBookmarked ? String(localized: "Remove Bookmark") : String(localized: "Bookmark This Page"),
                  systemImage: state.isPageBookmarked ? "bookmark.fill" : "bookmark")
                // The hierarchical primary style, as the other symbols (an
                // explicit Color.primary did not draw on glass).
                .foregroundStyle(state.isPageBookmarked ? AnyShapeStyle(Self.bookmarkedColour) : AnyShapeStyle(.primary))
        }
        .help(state.isPageBookmarked ? String(localized: "Remove Bookmark (⌘D)") : String(localized: "Bookmark This Page (⌘D)"))
    }

    /// Layout: one page, two pages or scroll, and line width.
    private var layoutButton: some View {
        Button {
            toggle(.layout)
        } label: {
            // The layout in use (an iPhone shows one page whatever the
            // Two Pages setting says).
            Label(String(localized: "Layout"), systemImage: state.currentLayout.symbol)
        }
        .help(String(localized: "Layout"))
        .popover(isPresented: isOpen(.layout), arrowEdge: popoverEdge) {
            LayoutPopover(state: state, actions: actions)
        }
    }

    private var typographyButton: some View {
        Button {
            toggle(.typography)
        } label: {
            // "textformat" is the system's "Aa" symbol.
            Label(String(localized: "Text and Appearance"), systemImage: "textformat")
        }
        .help("Text and Appearance")
        .popover(isPresented: isOpen(.typography), arrowEdge: popoverEdge) {
            TypographyPopover(state: state, actions: actions)
        }
    }

    private func toggle(_ popover: Popover) {
        openPopover = openPopover == popover ? nil : popover
        if openPopover != nil { state.sidebarVisible = false } // one popover at a time
        actions.interacted()
    }

    /// Whether one popover is open, as a binding (the system closes a
    /// popover by setting it to false).
    private func isOpen(_ popover: Popover) -> Binding<Bool> {
        Binding(get: { openPopover == popover },
                set: { open in
                    if open { openPopover = popover } else if openPopover == popover { openPopover = nil }
                })
    }

    /// Popovers hang above the controls at the bottom of the screen. The
    /// two platforms read the edge differently: the Mac needs .top for a
    /// popover above the button, iOS needs .bottom.
    #if os(iOS)
    private var popoverEdge: Edge { .bottom }
    #else
    private var popoverEdge: Edge { .top }
    #endif
}

private extension View {
    /// Keeps the overlay up while one of its popovers is open, and closes
    /// it when the contents popover opens (one popover at a time).
    func popoverBookkeeping<P: Equatable>(state: ReaderState, actions: OverlayActions,
                                          openPopover: Binding<P?>) -> some View {
        onChange(of: openPopover.wrappedValue != nil) { _, open in
            state.overlayPopoverOpen = open
            actions.interacted()
        }
        .onChange(of: state.sidebarVisible) { _, open in if open { openPopover.wrappedValue = nil } }
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
    @Environment(\.colorScheme) private var colorScheme
    private let knob: CGFloat = 18
    private let track: CGFloat = 4

    /// The part of the track still to read, and the chapter ticks. A light
    /// line on dark glass needs more weight than a dark line on light glass
    /// to be seen as well (in dark mode, 15% white all but vanished).
    private var restOfTrack: Color { Color.primary.opacity(colorScheme == .dark ? 0.35 : 0.15) }
    private var tickColour: Color { Color.primary.opacity(colorScheme == .dark ? 0.5 : 0.3) }

    /// The least room between two chapter ticks, in points. Many short
    /// chapters together (front matter, a run of brief sections) otherwise
    /// draw as a solid bar of ticks.
    static let minimumTickSpacing: CGFloat = 6

    /// The chapter starts to mark on a track `width` points long: not the
    /// book's start or end, and none closer than `minimumTickSpacing` to
    /// the last one kept (or to the track's ends).
    static func spaced(_ ticks: [Double], width: CGFloat) -> [Double] {
        let gap = Double(minimumTickSpacing / max(width, 1))
        var kept: [Double] = []
        var last = 0.0
        for tick in ticks.sorted() where tick - last >= gap && 1 - tick >= gap {
            kept.append(tick)
            last = tick
        }
        return kept
    }

    var body: some View {
        GeometryReader { geo in
            let usable = max(geo.size.width - knob, 1)
            // Position along the track, mirrored for right-to-left books.
            let position = { (f: Double) -> CGFloat in
                knob / 2 + usable * CGFloat(rightToLeft ? 1 - f : f)
            }
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(restOfTrack)
                    .frame(height: track)
                    .padding(.horizontal, knob / 2)
                Capsule()
                    .fill(Color.platenAccent)
                    .frame(width: max(0, abs(position(value) - position(0))), height: track)
                    .offset(x: rightToLeft ? position(value) : knob / 2)
                ForEach(Array(Self.spaced(ticks, width: usable).enumerated()), id: \.offset) { _, tick in
                    Rectangle()
                        .fill(tickColour)
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
///
/// iOS: plain rows on the popover's own glass, sized to fit (a grouped form
/// there drew a second panel inside the popover, at a fixed height). The Mac
/// keeps a grouped form.
struct TypographyPopover: View {
    @ObservedObject var state: ReaderState
    @ObservedObject var settings = ReaderSettings.shared
    let actions: OverlayActions

    var body: some View {
        #if os(iOS)
        PopoverRows(width: 340) {
            // PDFs: only the theme applies (it colours the area around the
            // page); text size, font and spacing are the PDF's own.
            if !state.isPDF {
                textSizeRow
                PopoverDivider()
                LabeledContent("Font") { fontPicker.labelsHidden().fixedSize() }
                    .popoverRow()
                    .disabled(state.isFixedLayout)
                PopoverDivider()
                LabeledContent("Line Spacing") { lineSpacingPicker.labelsHidden().fixedSize() }
                    .popoverRow()
                    .disabled(state.isFixedLayout)
                PopoverDivider()
            }
            LabeledContent("Appearance") { appearancePicker.labelsHidden() }
                .popoverRow()
            PopoverDivider()
            // The glow of the page's own colours around it (books and PDFs;
            // not in the Black theme, whose point is a black screen).
            Toggle("Ambient Light", isOn: $settings.ambientLight)
                .tint(.platenAccent)
                .popoverRow()
            if state.isPDF {
                PopoverDivider()
                // White pages dark, for reading in the dark.
                Toggle("Invert Colours", isOn: $settings.invertPDF)
                    .tint(.platenAccent)
                    .popoverRow()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Text and Appearance"))
        .platenPopover()
        #else
        Form {
            if !state.isPDF {
                textSizeRow
                fontPicker.disabled(state.isFixedLayout)
                lineSpacingPicker.disabled(state.isFixedLayout)
            }
            appearancePicker
        }
        .formStyle(.grouped)
        .frame(width: 360)
        .fixedSize(horizontal: false, vertical: true)
        // VoiceOver names the popover rather than saying "scroll area".
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Text and Appearance"))
        #endif
    }

    private var appearancePicker: some View {
        Picker("Appearance", selection: $settings.appearance) {
            ForEach(AppearanceChoice.allCases) { Text($0.label).tag($0) }
        }
        .pickerStyle(.menu)
    }

    private var fontPicker: some View {
        Picker("Font", selection: $settings.fontFamily) {
            ForEach(ReaderSettings.curatedFonts, id: \.self) { name in
                Text(name.isEmpty ? String(localized: "Publisher Default") : name).tag(name)
            }
        }
        .pickerStyle(.menu)
    }

    private var lineSpacingPicker: some View {
        Picker("Line Spacing", selection: $settings.lineHeight) {
            ForEach(ReaderSettings.lineHeights, id: \.self) { value in
                Text(value == 0 ? String(localized: "Publisher Default") : value.formatted(.number.precision(.fractionLength(1...2)))).tag(value)
            }
        }
        .pickerStyle(.menu)
    }

    /// The smaller and larger text buttons: on a touch screen each gets a
    /// finger-sized target (44 points), not just the glyph.
    private func textSizeIcon(_ name: String) -> some View {
        #if os(iOS)
        Image(systemName: name)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        #else
        Image(systemName: name)
        #endif
    }

    #if os(iOS)
    private let textSizeSpacing: CGFloat = 0
    #else
    private let textSizeSpacing: CGFloat = 8
    #endif

    private var textSizeRow: some View {
        LabeledContent("Text Size") {
            HStack(spacing: textSizeSpacing) {
                Button { settings.smallerText() } label: { textSizeIcon("textformat.size.smaller") }
                    .disabled(settings.fontSizeIndex == 0)
                    .accessibilityLabel(Text("Smaller Text"))
                Text("\(Int(settings.fontSize)) pt").monospacedDigit().frame(minWidth: 44)
                Button { settings.biggerText() } label: { textSizeIcon("textformat.size.larger") }
                    .disabled(settings.fontSizeIndex == ReaderSettings.fontSizes.count - 1)
                    .accessibilityLabel(Text("Larger Text"))
            }
            // Each button takes only its own taps. In an iOS form, a row's
            // plain buttons all fire on any tap in the row, so Smaller and
            // Larger cancelled each other out.
            .buttonStyle(.borderless)
        }
        #if os(iOS)
        .popoverRow(minHeight: 52)
        #endif
        .disabled(state.isFixedLayout)
    }
}

/// The layout popover: one page, two pages or scroll, and the line width.
///
/// iOS: plain rows on the popover's own glass, sized to fit: the layouts as
/// a list with a tick by the one in use, then the line width (books). A
/// grouped form there drew a second panel inside the popover, at a fixed
/// height, off centre and scrollable. The Mac keeps a grouped form with a
/// segmented control (and its shortcuts).
struct LayoutPopover: View {
    @ObservedObject var state: ReaderState
    @ObservedObject var settings = ReaderSettings.shared
    let actions: OverlayActions

    var body: some View {
        #if os(iOS)
        // Narrow: just wide enough for the names, the ticks and the line
        // width's three choices, so the ticks sit near the names.
        PopoverRows(width: 240) {
            ForEach(Array(state.availableLayouts.enumerated()), id: \.element) { index, layout in
                if index > 0 { PopoverDivider(inset: 54) }
                layoutRow(layout)
            }
            if let note {
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
            }
            if !state.isPDF {
                PopoverDivider()
                VStack(alignment: .leading, spacing: 8) {
                    Text("Line Width")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    lineWidthPicker
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .disabled(state.isFixedLayout)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Layout"))
        .platenPopover()
        #else
        Form {
            Picker("Layout", selection: Binding(get: { state.currentLayout }, set: actions.setLayout)) {
                ForEach(state.availableLayouts) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .help(String(localized: "⌘1 one page, ⌘2 two pages, ⌘3 scroll"))
            if let note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !state.isPDF { lineWidthPicker.disabled(state.isFixedLayout) }
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Layout"))
        #endif
    }

    private var lineWidthPicker: some View {
        Picker("Line Width", selection: $settings.lineWidth) {
            ForEach(LineWidth.allCases) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
    }

    #if os(iOS)
    /// One layout: its symbol, its name, and a tick if it is in use.
    private func layoutRow(_ layout: ReadingLayout) -> some View {
        let selected = state.currentLayout == layout
        return Button {
            actions.setLayout(layout)
        } label: {
            HStack(spacing: 14) {
                Image(systemName: layout.symbol)
                    .frame(width: 24)
                    .foregroundStyle(.secondary)
                Text(layout.label)
                Spacer(minLength: 8)
                Image(systemName: "checkmark")
                    .fontWeight(.semibold)
                    .foregroundStyle(.tint)
                    .opacity(selected ? 1 : 0)
            }
            .popoverRow()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
    #endif

    /// A line under the choices, when one is needed: a PDF in Two Pages held
    /// in portrait (one page shows until the device is turned) or whose
    /// pages are spreads already, or a window too narrow for two pages.
    private var note: LocalizedStringKey? {
        if state.isPDF, state.pagesAreSpreads {
            return "These pages are already spreads, so they show one at a time."
        }
        if state.isPDF, state.flow == .paginated, settings.pageLayout == .two, state.columnsOnScreen < 2 {
            return "Two pages show side by side when you turn to landscape."
        }
        if state.twoPagesTooNarrow {
            return "The window is too narrow for two pages. Make it wider to see them side by side."
        }
        return nil
    }
}
