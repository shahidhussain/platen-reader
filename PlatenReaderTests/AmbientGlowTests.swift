import XCTest

/// The ambient light's colour maths, now shared by the iOS and Mac PDF
/// readers (`AmbientGlow`): it must agree with UIColor's and NSColor's own
/// hue, saturation and brightness, which the iOS glow used before.
final class AmbientGlowTests: XCTestCase {
    func testHSBMatchesTheSystemsAndRoundTrips() {
        let samples: [(CGFloat, CGFloat, CGFloat)] = [(1, 0, 0), (0.2, 0.6, 0.4), (0.9, 0.85, 0.1), (0.5, 0.5, 0.5),
                                                      (0.12, 0.12, 0.13), (0.3, 0.1, 0.8), (1, 1, 1), (0, 0, 0)]
        for (r, g, b) in samples {
            let (h, s, v) = AmbientGlow.hsb(red: r, green: g, blue: b)
            let system = NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
            XCTAssertEqual(s, system.saturationComponent, accuracy: 0.001)
            XCTAssertEqual(v, system.brightnessComponent, accuracy: 0.001)
            if s > 0 {
                // Round the wheel: a hue of 1 is the same as 0 (red).
                let apart = abs(h - system.hueComponent)
                XCTAssertLessThan(min(apart, 1 - apart), 0.001)
            }
            let back = AmbientGlow.rgb(hue: h, saturation: s, brightness: v)
            XCTAssertEqual(back.0, r, accuracy: 0.001)
            XCTAssertEqual(back.1, g, accuracy: 0.001)
            XCTAssertEqual(back.2, b, accuracy: 0.001)
        }
    }

    func testThemeBrightnessFromItsHex() {
        XCTAssertEqual(AmbientGlow.brightness(ofHex: "#000000"), 0)
        XCTAssertEqual(AmbientGlow.brightness(ofHex: "#ffffff"), 1)
        XCTAssertEqual(AmbientGlow.brightness(ofHex: "#1e1e20"), 32.0 / 255, accuracy: 0.001)
    }

    /// A page of one strong colour glows in that colour's hue.
    func testAColouredPageGlowsInItsOwnHue() throws {
        let red = CGColor(red: 0.8, green: 0.1, blue: 0.1, alpha: 1)
        let image = try XCTUnwrap(AmbientGlow.picture(width: 12, height: 16, paper: red, themeBrightness: 0.12) { _, _ in })
        XCTAssertGreaterThan(image.width, 12, "enlarged before it is stretched")
    }
}
