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

    // MARK: - How much band (`backing`)

    /// A plain backdrop the controls read clearly against: no band.
    func testNoBandOverACalmContrastingBackdrop() {
        let paper = RGB(hex: "#f4ecd8")
        let (_, opacity) = GlowBand.backing(behind: Array(repeating: paper, count: 400), width: 20,
                                            darkTheme: false, page: paper)
        XCTAssertEqual(opacity, 0)
    }

    /// White controls over a white picture: a solid band, in a colour that
    /// lets them read.
    func testASolidBandWhereItMustBe() {
        let (colour, opacity) = GlowBand.backing(behind: Array(repeating: RGB.white, count: 400), width: 20,
                                                 darkTheme: true, page: RGB(hex: "#1e1e20"))
        XCTAssertGreaterThanOrEqual(opacity, 0.7)
        XCTAssertGreaterThanOrEqual(GlowBand.contrast(colour, .white), GlowBand.neededContrast)
        // Laid over the white, the controls read.
        XCTAssertGreaterThanOrEqual(GlowBand.contrast(RGB.white.mixed(with: colour, opacity), .white), GlowBand.backdropContrast)
    }

    /// A mid-tone backdrop the controls nearly read against: part of a band,
    /// neither none nor solid.
    func testAHalfwayBandWhereTheyNearlyRead() {
        let grey = RGB(hex: "#a8a8a8") // white reads against it at about 2.4
        let (_, opacity) = GlowBand.backing(behind: Array(repeating: grey, count: 400), width: 20,
                                            darkTheme: true, page: RGB(hex: "#1e1e20"))
        XCTAssertGreaterThan(opacity, 0)
        XCTAssertLessThan(opacity, 1)
    }

    /// Lines of the book's own text behind the controls: nearly solid, so
    /// the text is no more than a faint shadow under them.
    func testTextBehindIsDimmedAlmostAway() {
        let paper = RGB(hex: "#f4ecd8"), ink = RGB(hex: "#5b4636")
        let rows = (0..<20).flatMap { row in (0..<20).map { x in row % 2 == 0 && x % 2 == 0 ? ink : paper } }
        let (colour, opacity) = GlowBand.backing(behind: rows, width: 20, darkTheme: false, page: paper)
        XCTAssertGreaterThanOrEqual(opacity, 0.8)
        XCTAssertGreaterThanOrEqual(GlowBand.contrast(colour, .black), GlowBand.neededContrast)
    }

    /// One line of text at the edge of a plain margin (the last line of a
    /// page, just behind the location line): nearly solid, however much
    /// plain margin is round it.
    func testALineOfTextInAMarginStillGetsABand() {
        let paper = RGB(hex: "#f4ecd8"), ink = RGB(hex: "#5b4636")
        let rows = (0..<40).flatMap { row in (0..<40).map { x in row < 3 && x % 3 == 0 ? ink : paper } }
        let (_, opacity) = GlowBand.backing(behind: rows, width: 40, darkTheme: false, page: paper)
        XCTAssertGreaterThanOrEqual(opacity, 0.8)
    }

    /// A clean diagonal edge across a plain picture (a picture book's page)
    /// is not detail: no band.
    func testACleanEdgeIsNotDetail() {
        // Two colours white reads clearly against, with a sharp edge between.
        let light = RGB(hex: "#a04a18"), dark = RGB(hex: "#5a2410")
        let rows = (0..<40).flatMap { row in (0..<40).map { x in x < row ? dark : light } }
        let (_, opacity) = GlowBand.backing(behind: rows, width: 40, darkTheme: true, page: RGB(hex: "#1e1e20"))
        XCTAssertEqual(opacity, 0)
    }

    /// The band's colour is what is behind it (a deep blue glow behind white
    /// controls), not the page's plain colour.
    func testTheColourComesFromWhatIsBehind() {
        let blue = RGB(hex: "#1c2a5a")
        let (colour, _) = GlowBand.backing(behind: Array(repeating: blue, count: 100), width: 10,
                                           darkTheme: true, page: RGB(hex: "#000000"))
        XCTAssertEqual(colour.hex, blue.hex)
    }
}
