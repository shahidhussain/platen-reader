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
/// quarters through that stretch while its stripes keep moving.
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

    /// How much of the bar is filled during this stage: the share of the
    /// steps already done, nothing more. A slow step simply takes a while;
    /// the stripes moving along the bar show that it is still working.
    var progress: Double { Double(rawValue) / 4 }
}

/// A slim loading bar with a line saying what is happening, shown in the
/// middle of the page while a book opens (only if that takes a moment: the
/// reader shows it after about a third of a second). The bar fills by the
/// steps actually done; diagonal stripes move along it all the while, so a
/// long step never looks stuck.
struct OpeningProgressView: View {
    @ObservedObject var state: ReaderState
    @State private var progress = 0.0
    /// The last stage shown, so the line stays while the view fades out.
    @State private var shown: OpeningStage = .reading

    var body: some View {
        VStack(spacing: 10) {
            StripedProgressBar(progress: progress)
                .frame(width: 180, height: 6)
            Text(shown.label)
                .font(.footnote)
                .foregroundStyle(.secondary)
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

/// A rounded bar, filled to `progress`, with faint diagonal stripes moving
/// steadily along it (a barber's pole), still under Reduce Motion.
struct StripedProgressBar: View {
    let progress: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width, height = geo.size.height
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                Capsule()
                    .fill(Color.primary.opacity(0.45))
                    .frame(width: max(height, width * progress))
                TimelineView(.animation(paused: reduceMotion)) { timeline in
                    Canvas { context, size in
                        // Stripes 8 points apart, leaning back, moving right
                        // at 16 points a second.
                        let spacing: CGFloat = 8
                        let shift = reduceMotion ? 0 : CGFloat(timeline.date.timeIntervalSinceReferenceDate * 16)
                            .truncatingRemainder(dividingBy: spacing)
                        var x = -size.height - spacing + shift
                        while x < size.width + size.height {
                            var stripe = Path()
                            stripe.move(to: CGPoint(x: x, y: size.height))
                            stripe.addLine(to: CGPoint(x: x + size.height, y: 0))
                            stripe.addLine(to: CGPoint(x: x + size.height + spacing / 2, y: 0))
                            stripe.addLine(to: CGPoint(x: x + spacing / 2, y: size.height))
                            stripe.closeSubpath()
                            context.fill(stripe, with: .color(.primary.opacity(0.18)))
                            x += spacing
                        }
                    }
                }
            }
            .clipShape(Capsule())
        }
        .accessibilityHidden(true)
    }
}
