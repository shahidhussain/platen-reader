import XCTest

/// Tests of the About screen's parts: the bundled acknowledgements (made by
/// scripts/make-acknowledgements.py) and the version info for bug reports.
final class AboutTests: XCTestCase {
    /// The bundled file decodes, every component has its licence text, and
    /// the Kokoro credit's facts (hexgrad, Apache-2.0) match it.
    func testTheAcknowledgementsAreCompleteAndMatchTheCredit() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("PlatenReader/Shared/Acknowledgements.json")
        let list = try Acknowledgements.decode(Data(contentsOf: file))
        XCTAssertFalse(list.components.isEmpty)
        for component in list.components {
            let text = try XCTUnwrap(list.texts[component.text], "\(component.name) has no licence text")
            XCTAssertGreaterThan(text.count, 500, component.name)
            XCTAssertFalse(component.notice.isEmpty, component.name)
        }
        let kokoro = try XCTUnwrap(list.components.first { $0.name.hasPrefix("Kokoro-82M") })
        XCTAssertEqual(kokoro.licence, "Apache-2.0")
        XCTAssertTrue(kokoro.notice.contains("hexgrad"))
        // Nothing GPL.
        XCTAssertFalse(list.components.contains { $0.licence.uppercased().contains("GPL") })
    }

    /// Three lines: the app with version, build (and commit); the system;
    /// the model code.
    func testVersionInfoIsThreeLinesForABugReport() {
        let lines = AboutInfo.versionInfo.split(separator: "\n")
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].hasPrefix("Platen Reader "))
        XCTAssertTrue(lines[0].contains("build "))
        XCTAssertTrue(lines[1].hasPrefix("macOS "))
        XCTAssertFalse(lines[2].isEmpty)
    }
}
