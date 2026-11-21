import SwiftUI

/// The welcome screen, shown when Platen starts with nothing to read: one
/// clear "Open Book…" button, so the reader knows where they are, rather
/// than being dropped straight into a file browser.
///
/// - Mac: in its own window (WelcomeWindowController), where a book can also
///   be dropped onto it.
/// - iOS: full screen, as the home screen when no book is open
///   (HomeViewController) until a folder is chosen; "Open Book…" shows the
///   system's document picker, and "Choose Folder…" picks the folder whose
///   books the home screen then shows as covers.
///   Dropping books is not supported there, so the drop hint and the drop
///   target are left out.
struct WelcomeView: View {
    let open: () -> Void
    /// Books dropped onto the screen (the Mac only); nil turns dropping off.
    var openURLs: (([URL]) -> Void)?
    /// "Choose Folder…", for the folder view (iOS, until a folder is
    /// chosen); nil leaves the button out.
    var chooseFolder: (() -> Void)?
    @State private var dropTargeted = false

    var body: some View {
        let content = VStack(spacing: 18) {
            Spacer()
            Image(systemName: "book")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true) // decoration: VoiceOver should start on the title
                .reportsFrame(\.mark)
            VStack(spacing: 4) {
                Text("Platen Reader")
                    .font(.largeTitle.weight(.semibold))
                    .reportsFrame(\.title)
                Text(verbatim: AppVersion.line)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .reportsFrame(\.version)
            }
            Button(action: open) {
                Text("Open Book…")
                    .font(.title3.weight(.medium))
                    .padding(.horizontal, 22)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            if let chooseFolder {
                Button(action: chooseFolder) {
                    Text("Choose Folder…")
                        .font(.body.weight(.medium))
                        .padding(.horizontal, 12)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
            Text(openURLs == nil ? "EPUB, KEPUB, MOBI, AZW3, PDF or plain text."
                                 : "EPUB, KEPUB, MOBI, AZW3, PDF or plain text. You can also drop a book here.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Spacer()
            // A little whimsy, unattributed: an Easter egg for those who
            // know where it is from (Slaughterhouse-Five).
            Text(verbatim: "Poo-tee-weet?")
                .font(.system(.footnote, design: .serif).italic())
                .foregroundStyle(.tertiary)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)

        if let openURLs {
            content
                .background {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.platenAccent.opacity(dropTargeted ? 0.8 : 0),
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

/// Where the welcome's mark, title and version line are on screen (in
/// window coordinates), while it is showing. The iOS start-up animation
/// (LaunchSplash) moves its own mark, title and version to these places as
/// it ends, so that it hands over to the welcome without a jump. Nil when
/// the welcome is not on screen (a folder's covers are the home screen, or
/// a book is open).
@MainActor
struct WelcomeLayout {
    var mark: CGRect?
    var title: CGRect?
    var version: CGRect?

    static var current = WelcomeLayout()
}

private extension View {
    /// Keeps `WelcomeLayout.current` up to date with this view's frame.
    func reportsFrame(_ key: WritableKeyPath<WelcomeLayout, CGRect?>) -> some View {
        background {
            GeometryReader { geometry in
                let frame = geometry.frame(in: .global)
                Color.clear
                    .onAppear { WelcomeLayout.current[keyPath: key] = frame }
                    .onChange(of: frame) { _, frame in WelcomeLayout.current[keyPath: key] = frame }
                    .onDisappear { WelcomeLayout.current[keyPath: key] = nil }
            }
        }
    }
}
