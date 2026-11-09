import AppKit

/// One open book. Platen is a document-based app, so Open Recent, window
/// restoration, tabs and Finder's "Open With" all come from AppKit.
///
/// Books are read-only: Platen never writes to the file. The document only
/// records where the file is; the reader window then loads it in the
/// background so the window can appear immediately (see
/// `ReaderViewController.loadBook`), which is what lets a slow iCloud or
/// network open show a quiet progress indicator instead of a frozen app.
final class BookDocument: NSDocument {
    override class var autosavesInPlace: Bool { false }

    // Opening should never block the main thread.
    override class func canConcurrentlyReadDocuments(ofType typeName: String) -> Bool { true }

    override func read(from url: URL, ofType typeName: String) throws {
        // Nothing to do here: the reader loads the file itself, with its own
        // file coordination, once the window is on screen.
    }

    override func makeWindowControllers() {
        addWindowController(ReaderWindowController(document: self))
    }

    // MARK: Read-only

    override func data(ofType typeName: String) throws -> Data {
        throw CocoaError(.featureUnsupported)
    }

    override var isDocumentEdited: Bool { false }
    override func canAsynchronouslyWrite(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType) -> Bool { false }
    override class func isNativeType(_ type: String) -> Bool { false }
    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        // Hide the save-related commands' effects for a viewer.
        switch item.action {
        case #selector(save(_:)), #selector(saveAs(_:)), #selector(duplicate(_:)),
             #selector(rename(_:)), #selector(move(_:)), #selector(revertToSaved(_:)):
            return false
        default:
            return super.validateUserInterfaceItem(item)
        }
    }
}
