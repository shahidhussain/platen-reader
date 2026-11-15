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
/// findings"). Hence the bar's long, slow last stretch.
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

    var label: String {
        switch self {
        case .downloading: return String(localized: "Downloading from iCloud…")
        case .reading: return String(localized: "Opening the book…")
        case .preparing: return String(localized: "Preparing the pages…")
        case .layingOut: return String(localized: "Laying out the first page…")
        }
    }

    /// Where the bar heads during this stage, and how long it takes to get
    /// there. The last stage creeps, so the bar never stands still, but
    /// never reaches the end before the page is shown.
    var target: (progress: Double, seconds: Double) {
        switch self {
        case .downloading: return (0.15, 8)
        case .reading: return (0.3, 0.4)
        case .preparing: return (0.5, 0.6)
        case .layingOut: return (0.95, 9)
        }
    }
}

/// A slim loading bar with a line saying what is happening, shown in the
/// middle of the page while a book opens (only if that takes a moment: the
/// reader shows it after about a third of a second).
struct OpeningProgressView: View {
    @ObservedObject var state: ReaderState
    @State private var progress = 0.0
    /// The last stage shown, so the line stays while the view fades out.
    @State private var shown: OpeningStage = .reading

    var body: some View {
        VStack(spacing: 10) {
            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .tint(.secondary)
                .frame(width: 180)
            Text(shown.label)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .contentTransition(.opacity)
        }
        .accessibilityElement(children: .combine)
        .onAppear { advance(to: state.opening) }
        .onChange(of: state.opening) { _, stage in advance(to: stage) }
    }

    private func advance(to stage: OpeningStage?) {
        guard let stage else {
            withAnimation(.easeOut(duration: 0.2)) { progress = 1 }
            return
        }
        withAnimation(.easeInOut(duration: 0.2)) { shown = stage }
        let (target, seconds) = stage.target
        guard target > progress else { return }
        withAnimation(stage == .layingOut || stage == .downloading ? .easeOut(duration: seconds) : .easeInOut(duration: seconds)) {
            progress = target
        }
    }
}
