import XCTest

/// Tests of `GlowBand` (Shared/GlowBand.swift): the colour of the bands
/// behind the iOS reader's controls while ambient light is on.
final class GlowBandTests: XCTestCase {
    typealias RGB = GlowBand.RGB

    func testHexRoundTrips() {
        XCTAssertEqual(RGB(hex: "#ff9f0a").hex, "#ff9f0a")
        XCTAssertEqual(RGB(hex: "000000"), RGB.black)
    }

    func testContrastOfBlackAndWhiteIsTwentyOne() {
        XCTAssertEqual(GlowBand.contrast(.black, .white), 21, accuracy: 0.01)
    }

    /// A dark glow behind white controls is legible as it is: the band is
    /// the glow's own colour, with no fade to the page's black.
    func testADarkGlowIsUsedAsItIs() {
        let brown = RGB(hex: "#3a2418")
        XCTAssertEqual(GlowBand.colour(edge: brown, page: .black, darkTheme: true), brown)
    }

    /// A bright glow behind white controls is darkened towards the page,
    /// only as far as the controls need.
    func testABrightGlowIsDarkenedJustEnough() {
        let orange = RGB(hex: "#f0a040")
        let band = GlowBand.colour(edge: orange, page: .black, darkTheme: true)
        XCTAssertNotEqual(band, orange)
        XCTAssertGreaterThanOrEqual(GlowBand.contrast(band, .white), GlowBand.neededContrast)
        XCTAssertGreaterThan(band.luminance, 0.05, "not all the way to black")
    }

    /// Behind black controls (a light theme), a dark glow is lightened
    /// towards the white page.
    func testADarkGlowIsLightenedInALightTheme() {
        let navy = RGB(hex: "#203060")
        let band = GlowBand.colour(edge: navy, page: .white, darkTheme: false)
        XCTAssertGreaterThanOrEqual(GlowBand.contrast(band, .black), GlowBand.neededContrast)
    }

    /// A dark glow and page behind white controls: no band at all.
    func testNoBandOverADarkBackdrop() {
        let backdrop = Array(repeating: RGB(hex: "#2a1d14"), count: 90) + Array(repeating: RGB(hex: "#1e1e20"), count: 10)
        XCTAssertFalse(GlowBand.needsBand(behind: backdrop, width: 10, darkTheme: true))
    }

    /// A bright picture behind white controls (Scroll, a picture passing
    /// under the title): a band.
    func testABandOverABrightPicture() {
        let backdrop = Array(repeating: RGB(hex: "#e8e070"), count: 60) + Array(repeating: RGB(hex: "#1e1e20"), count: 40)
        XCTAssertTrue(GlowBand.needsBand(behind: backdrop, width: 10, darkTheme: true))
    }

    /// A few poor pixels (a stroke of a picture) are tolerated.
    func testAFewPoorPixelsAreTolerated() {
        let backdrop = Array(repeating: RGB(hex: "#1e1e20"), count: 95) + Array(repeating: RGB.white, count: 5)
        XCTAssertFalse(GlowBand.needsBand(behind: backdrop, width: 10, darkTheme: true))
    }

    /// In a light theme the controls are black: a light glow needs no band,
    /// a dark one does.
    func testLightThemeBackdrops() {
        XCTAssertFalse(GlowBand.needsBand(behind: Array(repeating: RGB(hex: "#f3e3b0"), count: 50), width: 10, darkTheme: false))
        XCTAssertTrue(GlowBand.needsBand(behind: Array(repeating: RGB(hex: "#30304a"), count: 50), width: 10, darkTheme: false))
    }

    /// Lines of the page's own text behind the controls: a band, though
    /// the paper alone would let the controls read (Sepia, black controls).
    func testTextBehindTheControlsNeedsABand() {
        let paper = RGB(hex: "#f4ecd8"), ink = RGB(hex: "#8a7f70")
        // Rows of 20: every other row has strokes of "text" in it.
        let rows = (0..<10).flatMap { row in
            (0..<20).map { x in row % 2 == 0 && x % 3 == 0 ? ink : paper }
        }
        XCTAssertTrue(GlowBand.needsBand(behind: rows, width: 20, darkTheme: false))
        XCTAssertFalse(GlowBand.needsBand(behind: Array(repeating: paper, count: 200), width: 20, darkTheme: false))
    }
}
