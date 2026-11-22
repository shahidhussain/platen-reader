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
}
