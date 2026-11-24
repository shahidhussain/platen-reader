import XCTest

/// The line under the loading bar while a book opens (Shared/OpeningProgress.swift).
final class OpeningProgressTests: XCTestCase {
    /// It names the book at every step, and says so while downloading.
    func testTheLineNamesTheBook() {
        for stage in [OpeningStage.reading, .preparing, .layingOut] {
            XCTAssertEqual(stage.label(title: "Sense and Sensibility"), "Opening “Sense and Sensibility”")
        }
        XCTAssertEqual(OpeningStage.downloading.label(title: "Emma"), "Downloading “Emma” from iCloud")
    }

    /// With no name known, the plain wording.
    func testWithoutATitleTheLineIsPlain() {
        XCTAssertEqual(OpeningStage.reading.label(title: ""), "Opening the book")
        XCTAssertEqual(OpeningStage.downloading.label(title: ""), "Downloading from iCloud")
    }
}
