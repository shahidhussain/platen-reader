import SwiftUI

/// What the speaker button does.
struct ReadAloudButtonActions {
    /// Starts reading, pauses or resumes, by what is happening now.
    var tap: () -> Void
    /// Stops reading (from the button's long-press menu).
    var stop: () -> Void
}

/// The speaker button (iOS: at the right of the top bar; Mac: on the overlay
/// bar): starts reading aloud from the current page; while reading, pauses
/// and resumes. A long press (Mac: a right-click) offers Stop Reading. The
/// usual player pattern (play and pause in one button), with the speaker as
/// the way in.
struct ReadAloudButton: View {
    let phase: ReadAloudPhase
    let actions: ReadAloudButtonActions

    var body: some View {
        Button(action: actions.tap) {
            #if os(iOS)
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
            #else
            // On the Mac's bar, sized and coloured by the bar, as its other
            // symbols are.
            Image(systemName: symbol)
                .contentTransition(.symbolEffect(.replace))
            #endif
        }
        #if os(iOS)
        .buttonStyle(.plain)
        #else
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
