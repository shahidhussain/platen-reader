import SwiftUI

/// How far a book has got while it opens, for the loading bar and the line
/// under it (`OpeningProgressView`). The session moves it on at each step
/// (BookSession; PDFReaderModel's readers for PDFs), and clears it once the
/// first page is on screen.
///
/// Where the time goes (an iPhone Simulator, a 2 MB EPUB): reading the file
/// takes about 0.2 s and opening it in the web shell about 0.5 s; most of
/// the rest (about 3 s) is WebKit loading the first chapter's frame, which
/// is slow the first time after launch (docs/m3-ios-plan.md, "Phase 1
/// findings"). The bar fills only as steps finish, so it rests at three
/// quarters through that stretch.
enum OpeningStage: Int, Comparable {
    /// The file is in iCloud (or another provider) and not on the device.
    case downloading
    /// Reading the file and checking it (Book.open, off the main thread).
    case reading
    /// The book is handed to the web shell, which opens it (foliate-js).
    case preparing
    /// The first chapter is being laid out and drawn.
    case layingOut

    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    /// The line under the bar: which book is opening, by name ("Opening
    /// “Sense and Sensibility”"), rather than which step it is on; the bar
    /// shows how far it has got. No ellipsis: the bar already says it is
    /// under way. `title` is empty if no name is known.
    func label(title: String) -> String {
        switch (self, title.isEmpty) {
        case (.downloading, false): return String(localized: "Downloading “\(title)” from iCloud")
        case (.downloading, true): return String(localized: "Downloading from iCloud")
        case (_, false): return String(localized: "Opening “\(title)”")
        case (_, true): return String(localized: "Opening the book")
        }
    }

    /// How much of the bar is filled during this stage: the share of the
    /// steps already done, nothing more. A slow step simply takes a while;
    /// the line under the bar says what it is.
    var progress: Double { Double(rawValue) / 4 }
}

/// A slim loading bar with a line saying what is happening, shown in the
/// middle of the page while a book opens (only if that takes a moment: the
/// reader shows it after about a third of a second). The bar fills by the
/// steps actually done: plain and thin, in the app's accent.
struct OpeningProgressView: View {
    @ObservedObject var state: ReaderState
    @State private var progress = 0.0
    /// The last stage shown, so the line stays while the view fades out.
    @State private var shown: OpeningStage = .reading

    var body: some View {
        VStack(spacing: 10) {
            ThinProgressBar(progress: progress)
                .frame(width: 180, height: 3)
            Text(shown.label(title: state.title.isEmpty ? state.openingTitle : state.title))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(maxWidth: 280)
                .contentTransition(.opacity)
        }
        .accessibilityElement(children: .combine)
        .onAppear { advance(to: state.opening, animated: false) }
        .onChange(of: state.opening) { _, stage in advance(to: stage, animated: true) }
    }

    private func advance(to stage: OpeningStage?, animated: Bool) {
        let target = stage?.progress ?? 1
        withAnimation(animated ? .easeInOut(duration: 0.25) : nil) {
            if let stage { shown = stage }
            progress = max(progress, target)
        }
    }
}

/// A thin rounded bar, filled to `progress` in the app's accent over a
/// faint track (design review, 21 Nov 2026: plain, in place of the moving
/// stripes it had).
struct ThinProgressBar: View {
    let progress: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                Capsule()
                    .fill(Color.platenAccent)
                    .frame(width: max(geo.size.height, geo.size.width * progress))
            }
        }
        .accessibilityHidden(true)
    }
}
