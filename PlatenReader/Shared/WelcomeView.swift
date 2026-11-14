import SwiftUI

/// The welcome screen, shown when Platen starts with nothing to read: one
/// clear "Open Book…" button, so the reader knows where they are, rather
/// than being dropped straight into a file browser.
///
/// - Mac: in its own window (WelcomeWindowController), where a book can also
///   be dropped onto it.
/// - iOS: full screen before the document browser, the first time the app
///   is opened (SceneDelegate). Dropping books is not supported there, so
///   the drop hint and the drop target are left out.
struct WelcomeView: View {
    let open: () -> Void
    /// Books dropped onto the screen (the Mac only); nil turns dropping off.
    var openURLs: (([URL]) -> Void)?
    @State private var dropTargeted = false

    var body: some View {
        let content = VStack(spacing: 18) {
            Spacer()
            Image(systemName: "book")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true) // decoration: VoiceOver should start on the title
            Text("Platen Reader")
                .font(.largeTitle.weight(.semibold))
            Button(action: open) {
                Text("Open Book…")
                    .font(.title3.weight(.medium))
                    .padding(.horizontal, 22)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            Text(openURLs == nil ? "EPUB, KEPUB, MOBI, AZW3, PDF or plain text."
                                 : "EPUB, KEPUB, MOBI, AZW3, PDF or plain text. You can also drop a book here.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Spacer()
            // A little whimsy.
            VStack(spacing: 2) {
                Text(verbatim: "Poo-tee-weet?")
                    .font(.system(.title3, design: .serif).italic())
                Text(verbatim: "— Kurt Vonnegut")
                    .font(.callout)
            }
            .foregroundStyle(.secondary)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)

        if let openURLs {
            content
                .background {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(dropTargeted ? 0.8 : 0),
                                      style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                        .padding(12)
                }
                .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
                    for provider in providers {
                        _ = provider.loadObject(ofClass: URL.self) { url, _ in
                            if let url { DispatchQueue.main.async { openURLs([url]) } }
                        }
                    }
                    return true
                }
        } else {
            content
        }
    }
}
