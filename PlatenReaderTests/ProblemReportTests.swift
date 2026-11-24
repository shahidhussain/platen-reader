import PlatenCore
import XCTest

/// Tests of problem reports (Shared/ProblemReport.swift): the subject's tag,
/// the error codes, and what the diagnostics file says (and leaves out).
final class ProblemReportTests: XCTestCase {
    func testTheTagNamesTheVersionSystemAndCode() {
        let tag = ProblemReport.tag(code: "E-1030")
        XCTAssertTrue(tag.hasPrefix("[Platen "), tag)
        XCTAssertTrue(tag.hasSuffix(" · macOS · E-1030]"), tag)
        // Feedback has no code.
        XCTAssertTrue(ProblemReport.tag(code: nil).hasSuffix(" · macOS]"))
    }

    func testEachKindOfFailureHasItsOwnCode() {
        XCTAssertEqual(ErrorCode.code(for: BookOpenError.drm(.adobeADEPT)), "E-1001")
        XCTAssertEqual(ErrorCode.code(for: BookOpenError.kfx), "E-1010")
        XCTAssertEqual(ErrorCode.code(for: BookOpenError.unsupportedFormat), "E-1020")
        XCTAssertEqual(ErrorCode.code(for: BookOpenError.unreadable("x")), "E-1030")
        XCTAssertEqual(ErrorCode.code(for: PDFOpenError.locked), "E-1041")
        XCTAssertEqual(ErrorCode.code(for: CocoaError(.fileReadNoPermission)), "E-1050")
        XCTAssertTrue(ErrorCode.isDRM(BookOpenError.drm(.kindle)))
        XCTAssertFalse(ErrorCode.isDRM(BookOpenError.kfx))
    }

    func testTheDiagnosticsSayWhatWentWrongAndHowTheBookWasMade() {
        let facts = BookFacts(kind: "EPUB", size: 2048, epubVersion: "3.0", generator: "Sigil 1.9.30")
        let text = ProblemReport.bookDiagnostics(
            error: BookOpenError.unreadable("The package file is missing."), facts: facts,
            log: "10:00:00 Read <name> (epub, 2 KB) in 12 ms", now: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(text.contains("Error code: E-1030"))
        XCTAssertTrue(text.contains("The package file is missing."))
        XCTAssertTrue(text.contains("EPUB version: 3.0"))
        XCTAssertTrue(text.contains("Made with: Sigil 1.9.30"))
        XCTAssertTrue(text.contains("Read <name>"))
    }

    func testFileNamesAreLeftOutOfSystemErrors() {
        let error = NSError(domain: NSCocoaErrorDomain, code: 260,
                            userInfo: [NSLocalizedDescriptionKey: "The file /Users/someone/Books/Secret Title.epub is gone."])
        XCTAssertEqual(ProblemReport.describe(error), "NSCocoaErrorDomain 260")
    }

    func testTheMailtoLinkIsAddressedToSupport() throws {
        let url = try XCTUnwrap(ProblemReport.mailtoURL(subject: "[Platen 1.0 · macOS] Feedback", body: "Hi"))
        XCTAssertTrue(url.absoluteString.hasPrefix("mailto:\(AppLinks.supportEmail)?subject="), url.absoluteString)
    }
}
