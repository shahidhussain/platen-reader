import SwiftUI

/// Callbacks from the overlay to the reader.
struct OverlayActions {
    var previousPage: () -> Void
    var nextPage: () -> Void
    var goToFraction: (Double) -> Void
    var goBack: () -> Void
    var toggleContents: () -> Void
    var setFlow: (ReadingFlow) -> Void
    var setTheme: (Theme) -> Void
    var currentTheme: () -> Theme
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

    @State private var dragFraction: Double?
    @State private var showTypography = false

    private var locationText: String {
        if let f = dragFraction {
            // While dragging: the chapter at the slider position, and where.
            let percent = f.formatted(.percent.precision(.fractionLength(0)))
            return [state.chapter(atFraction: f), percent].compactMap { $0 }.joined(separator: " · ")
        }
        return state.locationLine(showPagesLeft: settings.showPagesLeftInChapter)
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                // Shown only after a jump, until the reader moves on.
                if let back = state.backLabel {
                    Button {
                        actions.goBack()
                    } label: {
                        Label(String(localized: "Back to \(back)"), systemImage: "arrow.uturn.backward")
                            .font(.callout)
                    }
                    .help(String(localized: "Back to \(back) (⌘[)"))
                }
                Spacer(minLength: 0)
                Text(locationText)
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityLabel(Text("Location"))
                    .accessibilityValue(Text(locationText))
                Spacer(minLength: 0)
            }

            HStack(spacing: 14) {
                if state.hasContents {
                    Button(action: actions.toggleContents) {
                        Image(systemName: "list.bullet")
                    }
                    .help("Contents and Bookmarks (⌘T)")
                    .accessibilityLabel(Text("Contents and Bookmarks"))
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
                    onEditingChanged: { editing in
                        if !editing, let f = dragFraction {
                            actions.goToFraction(f)
                            // Keep showing the target until the reader catches up.
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { dragFraction = nil }
                        }
                    }
                )
                .environment(\.layoutDirection, state.isRightToLeft ? .rightToLeft : .leftToRight)

                Button(action: state.isRightToLeft ? actions.previousPage : actions.nextPage) {
                    Image(systemName: "chevron.right")
                }
                .help(state.isRightToLeft ? "Previous Page" : "Next Page")
                .accessibilityLabel(state.isRightToLeft ? Text("Previous Page") : Text("Next Page"))

                Button {
                    showTypography.toggle()
                    actions.interacted()
                } label: {
                    Text("Aa").font(.body.weight(.medium))
                }
                .help("Text and Theme")
                .accessibilityLabel(Text("Text and Theme"))
                .popover(isPresented: $showTypography, arrowEdge: .top) {
                    TypographyPopover(state: state, actions: actions)
                }
            }
            .buttonStyle(.borderless)
            .imageScale(.large)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator, lineWidth: 0.5))
        .frame(maxWidth: 720)
    }
}

/// A slider with tick marks at chapter boundaries.
struct ProgressSlider: View {
    @Binding var value: Double
    let ticks: [Double]
    let onEditingChanged: (Bool) -> Void

    var body: some View {
        Slider(value: $value, in: 0...1, onEditingChanged: onEditingChanged)
            .controlSize(.small)
            .background(alignment: .center) {
                GeometryReader { geo in
                    // Slider's track is inset by roughly half the knob width.
                    let inset: CGFloat = 8
                    let width = geo.size.width - inset * 2
                    ForEach(Array(ticks.dropFirst().dropLast().enumerated()), id: \.offset) { _, tick in
                        Rectangle()
                            .fill(.tertiary)
                            .frame(width: 1, height: 8)
                            .position(x: inset + width * tick, y: geo.size.height / 2)
                    }
                }
                .allowsHitTesting(false)
            }
            .accessibilityLabel(Text("Progress"))
    }
}

/// The Aa popover: text size, font, line spacing, line width, theme and
/// reading mode. These are the same global settings as in Settings.
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

            Picker("Line Width", selection: $settings.lineWidth) {
                ForEach(LineWidth.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .disabled(state.isFixedLayout)

            Picker("Theme", selection: Binding(get: actions.currentTheme, set: actions.setTheme)) {
                ForEach(Theme.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)

            Picker("Layout", selection: Binding(get: { state.flow }, set: actions.setFlow)) {
                ForEach(ReadingFlow.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .disabled(state.isFixedLayout)
            .help(state.isFixedLayout ? String(localized: "Fixed-layout books are always paginated.") : "")
        }
        .formStyle(.grouped)
        .frame(width: 340)
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
