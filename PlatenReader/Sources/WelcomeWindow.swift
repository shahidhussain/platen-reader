import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The window shown when Platen starts with nothing to read: one clear
/// "Open Book…" button, rather than dropping straight into the Open panel.
/// A book can also be dropped onto it. It closes as soon as a book opens.
final class WelcomeWindowController: NSWindowController, NSWindowDelegate {
    static let shared = WelcomeWindowController()

    private init() {
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                              backing: .buffered, defer: true)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.title = String(localized: "Platen Reader")
        super.init(window: window)
        window.delegate = self
        window.contentViewController = NSHostingController(rootView: WelcomeView(open: { [weak self] in self?.openBook() },
                                                                                 openURLs: { [weak self] in self?.open($0) }))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show() {
        guard let window else { return }
        // A comfortable size for the screen: about half its width, within
        // sensible limits.
        let screen = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width = min(max(screen.width * 0.42, 560), 900)
        let height = min(max(screen.height * 0.5, 400), 640)
        window.setContentSize(NSSize(width: width, height: height))
        window.center()
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }

    /// Called when a book window opens.
    static func closeIfOpen() {
        shared.window?.orderOut(nil)
    }

    private func openBook() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = Self.bookTypes
        guard let window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK else { return }
            self?.open(panel.urls)
        }
    }

    private func open(_ urls: [URL]) {
        for url in urls {
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
                if let error { NSApp.presentError(error) }
            }
        }
    }

    /// The types listed in Info.plist (EPUB, KEPUB, MOBI, AZW, AZW3, plain text, PDF).
    static var bookTypes: [UTType] {
        ["org.idpf.epub-container", "com.kobo.kepub", "com.amazon.mobi", "com.amazon.azw", "com.amazon.azw3"]
            .compactMap { UTType($0) } + [UTType(filenameExtension: "epub")].compactMap { $0 } + [.plainText, .pdf]
    }
}
