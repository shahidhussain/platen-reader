import AppKit
import os

/// The window for one book.
///
/// Chrome is hidden by default: the title bar is transparent, content extends
/// underneath it, and the title and window buttons fade in only with the
/// overlay or when the pointer reaches the top edge (as in IINA). The window
/// stays draggable by its top edge throughout.
final class ReaderWindowController: NSWindowController, NSWindowDelegate {
    private var readerViewController: ReaderViewController? {
        contentViewController as? ReaderViewController
    }

    init(document: BookDocument) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.minSize = NSSize(width: 360, height: 320)
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.isRestorable = true
        window.tabbingMode = .automatic
        super.init(window: window)

        window.delegate = self
        contentViewController = ReaderViewController(document: document)
        window.setContentSize(NSSize(width: 900, height: 780))
        // Remember the size of the last window; new windows cascade from it.
        shouldCascadeWindows = true
        windowFrameAutosaveName = "PlatenReaderWindow"
        if window.frame.origin == .zero { window.center() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The window shows the book's title rather than its file name.
    override func windowTitle(forDocumentDisplayName displayName: String) -> String {
        readerViewController?.bookTitle ?? displayName
    }

    func windowWillClose(_ notification: Notification) {
        #if DEBUG
        Logger(subsystem: "Platen Reader", category: "reader").info("Window closed")
        #endif
        readerViewController?.savePositionNow()
        // There is always a window: when the last book closes, the welcome
        // window comes back.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            if NSDocumentController.shared.documents.isEmpty, !AppDelegate.isQuitting {
                WelcomeWindowController.shared.show()
            }
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        readerViewController?.reportLayoutToSettings()
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        readerViewController?.fullScreenChanged()
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        readerViewController?.fullScreenChanged()
    }
}
