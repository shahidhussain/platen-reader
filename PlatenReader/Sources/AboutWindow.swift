import AppKit
import SwiftUI

/// Platen Reader › About Platen Reader: a small window of its own, in the
/// style of a Mac app's About box (no title, no toolbar; close, nothing to
/// resize), showing the shared AboutView. Its Acknowledgements button opens
/// a second window (AcknowledgementsWindowController).
final class AboutWindowController: NSWindowController {
    static let shared = AboutWindowController()

    private init() {
        let view = AboutView(
            icon: Image(nsImage: NSApp.applicationIconImage),
            copyToClipboard: { text in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            },
            showAcknowledgements: { AcknowledgementsWindowController.shared.show() })
            .padding(.horizontal, 28)
            .padding(.top, 8)
            .padding(.bottom, 32)
            .frame(width: 400)
        let hosting = NSHostingController(rootView: view)
        // Sized once, to fit the content. (Letting the window follow the
        // content's size, with the content under the title bar, looped:
        // each changed the other until AppKit gave up and crashed.)
        hosting.sizingOptions = []
        let window = NSWindow(contentViewController: hosting)
        // An About box: a title bar with only the close button, its title
        // hidden, the content running up under it.
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.title = String(localized: "About Platen Reader")
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        // The content's size, measured before its first layout (the
        // view's own fittingSize is still zero then).
        window.setContentSize(hosting.sizeThatFits(in: NSSize(width: 400, height: 2000)))
        window.center()
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

/// The acknowledgements in a window of their own: the components in a
/// sidebar, each one's notice and licence beside it.
final class AcknowledgementsWindowController: NSWindowController {
    static let shared = AcknowledgementsWindowController()

    private init() {
        let hosting = NSHostingController(rootView: AcknowledgementsView().frame(minWidth: 640, minHeight: 440))
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView]
        window.title = String(localized: "Acknowledgements")
        window.setContentSize(NSSize(width: 760, height: 540))
        window.setFrameAutosaveName("PlatenAcknowledgements")
        window.center()
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
