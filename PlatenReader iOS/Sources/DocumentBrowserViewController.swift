import PlatenCore
import UIKit
import UniformTypeIdentifiers

/// The home screen: the system document browser (Files, iCloud Drive, SMB
/// shares and any file provider). Platen has no library of its own; folders
/// are the library. Books are opened in place through security-scoped URLs
/// and never copied into the app.
/// What the document browser presents: the book reader or the PDF reader.
protocol OpenReader: UIViewController {
    var onClose: (() -> Void)? { get set }
    func savePositionNow()
}

extension ReaderViewController: OpenReader {}
extension PDFReaderViewController: OpenReader {}

final class DocumentBrowserViewController: UIDocumentBrowserViewController, UIDocumentBrowserViewControllerDelegate {
    /// The book or PDF on screen, if any.
    private(set) var reader: OpenReader?

    /// A book asked for before the browser was on screen (at launch, from
    /// another app). Presenting then would lay the book out at zero size, so
    /// it waits for `viewDidAppear`.
    private var pendingBook: URL?
    private var hasAppeared = false

    /// The book types Platen opens, as declared in Info.plist. Plain text
    /// is shown as a book too (see PlatenCore's TextBook).
    static let contentTypes: [UTType] = [
        UTType("org.idpf.epub-container"), UTType("com.kobo.kepub"),
        UTType("com.amazon.mobi"), UTType("com.amazon.azw"), UTType("com.amazon.azw3"),
        .plainText, .pdf,
    ].compactMap { $0 }

    init() {
        super.init(forOpening: Self.contentTypes)
        delegate = self
        allowsDocumentCreation = false   // a viewer: Platen never makes books
        allowsPickingMultipleItems = false
        shouldShowFileExtensions = true  // .epub and .mobi look alike otherwise
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        hasAppeared = true
        if let url = pendingBook {
            pendingBook = nil
            present(book: url)
        }
    }

    // MARK: - Opening

    func documentBrowser(_ controller: UIDocumentBrowserViewController, didPickDocumentsAt documentURLs: [URL]) {
        if let url = documentURLs.first { present(book: url) }
    }

    /// Opens a book handed to the app from outside the browser (another
    /// app, Files' "Open in", or a debug launch argument). When `revealFirst`
    /// is set, the browser first shows the file in its folder, so closing the
    /// book returns to where it lives.
    func openBook(at url: URL, revealFirst: Bool) {
        guard revealFirst else { return present(book: url) }
        revealDocument(at: url, importIfNeeded: false) { [weak self] revealed, error in
            if let error { log.error("Could not reveal \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)") }
            self?.present(book: revealed ?? url)
        }
    }

    private func present(book url: URL) {
        guard hasAppeared else { pendingBook = url; return }
        let show = { [weak self] in
            guard let self else { return }
            // PDFs are shown by PDFKit; everything else by the book reader.
            let isPDF = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType?.conforms(to: .pdf)) == true
                || url.pathExtension.lowercased() == "pdf"
            let reader: OpenReader = isPDF ? PDFReaderViewController(url: url) : ReaderViewController(url: url)
            reader.onClose = { [weak self, weak reader] in
                reader?.dismiss(animated: true)
                self?.reader = nil
            }
            reader.modalPresentationStyle = .fullScreen
            self.reader = reader
            self.present(reader, animated: true)
        }
        // Replace a book that is already open.
        if let reader {
            reader.savePositionNow()
            reader.dismiss(animated: false, completion: show)
            self.reader = nil
        } else {
            show()
        }
    }
}
