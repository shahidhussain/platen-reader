import SwiftUI

/// What the speaker button does.
struct ReadAloudButtonActions {
    /// Starts reading, pauses or resumes, by what is happening now.
    var tap: () -> Void
    /// Stops reading (from the button's long-press menu).
    var stop: () -> Void
}

/// The speaker button (on the overlay bar: iOS's bottom bar, in the middle;
/// the Mac's bar): starts reading aloud from the current page; while reading, pauses
/// and resumes. A long press (Mac: a right-click) offers Stop Reading. The
/// usual player pattern (play and pause in one button), with the speaker as
/// the way in.
struct ReadAloudButton: View {
    let phase: ReadAloudPhase
    let actions: ReadAloudButtonActions

    var body: some View {
        Button(action: actions.tap) {
            // On the bar (the Mac's, or iOS's bottom bar), sized and
            // coloured by it, as its other symbols are.
            Image(systemName: symbol)
                .contentTransition(.symbolEffect(.replace))
        }
        #if os(macOS)
        .help(Text(label))
        #endif
        .accessibilityLabel(Text(label))
        .contextMenu {
            if phase != .off {
                Button(role: .destructive, action: actions.stop) {
                    Label("Stop Reading", systemImage: "stop.fill")
                }
            }
        }
    }

    private var symbol: String {
        switch phase {
        case .off: return "speaker.wave.2"
        case .starting, .playing: return "pause.fill"
        case .paused: return "play.fill"
        }
    }

    private var label: LocalizedStringKey {
        switch phase {
        case .off: return "Read Aloud"
        case .starting, .playing: return "Pause Reading"
        case .paused: return "Resume Reading"
        }
    }
}
