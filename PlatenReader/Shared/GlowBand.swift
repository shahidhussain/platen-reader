import Foundation

/// The colour of the bands behind the reader's controls (iOS) while ambient
/// light is on.
///
/// Without ambient light a band is the page's own colour, so it is invisible
/// against the page. With it, the edges of the screen glow in the colours of
/// what is on the page, and a band in the page's colour (black, say) cut a
/// hard fade from the glow into it (device testing, 21 Nov 2026). So the
/// band takes the glow's colour at its edge instead, and blends into it.
///
/// The band is also what the controls' title and buttons are read against,
/// so that colour is moved towards the page's colour only as far as it must
/// be for them to stay legible: a glow that is dark enough behind white
/// controls (or light enough behind black ones) is used as it is.
enum GlowBand {
    /// A colour as red, green and blue from 0 to 1 (sRGB).
    struct RGB: Equatable {
        var r: Double
        var g: Double
        var b: Double

        static let white = RGB(r: 1, g: 1, b: 1)
        static let black = RGB(r: 0, g: 0, b: 0)

        /// "#rrggbb", as the themes and `ReaderState.pageColour` give it.
        init(hex: String) {
            let value = UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0
            r = Double((value >> 16) & 0xFF) / 255
            g = Double((value >> 8) & 0xFF) / 255
            b = Double(value & 0xFF) / 255
        }

        init(r: Double, g: Double, b: Double) {
            self.r = r
            self.g = g
            self.b = b
        }

        var hex: String {
            func byte(_ value: Double) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
            return String(format: "#%02x%02x%02x", byte(r), byte(g), byte(b))
        }

        /// How bright the colour looks (WCAG's relative luminance).
        var luminance: Double {
            func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
            return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
        }

        /// Part of the way (`amount`, 0 to 1) from this colour to another.
        func mixed(with other: RGB, _ amount: Double) -> RGB {
            RGB(r: r + (other.r - r) * amount, g: g + (other.g - g) * amount, b: b + (other.b - b) * amount)
        }
    }

    /// How far apart two colours are in brightness (WCAG's contrast ratio,
    /// from 1 to 21).
    static func contrast(_ a: RGB, _ b: RGB) -> Double {
        let (high, low) = (max(a.luminance, b.luminance), min(a.luminance, b.luminance))
        return (high + 0.05) / (low + 0.05)
    }

    /// The contrast the controls need against their band: the level asked
    /// of ordinary text.
    static let neededContrast = 4.5

    // MARK: - Whether a band is needed at all

    /// The contrast the controls need against what is behind them when
    /// there is no band: a little below the level for ordinary text, as the
    /// title and buttons are bold and large (the reader asked for some
    /// tolerance, 21 Nov 2026).
    static let backdropContrast = 3.0

    /// The share of what is behind the controls that may fall below
    /// `backdropContrast` (a few strokes of a picture, a line of the page's
    /// own text glimpsed) before they need a band.
    static let backdropTolerance = 0.08

    /// The share of what is behind the controls that may be fine detail
    /// (lines of the book's own text, a busy picture) before they need a
    /// band: text over text is hard to read whatever the contrast.
    static let detailTolerance = 0.03

    /// Whether the controls need a band behind them. What lies there (the
    /// page, its picture and the glow: `pixels`, rows of a small picture of
    /// it, `width` across) needs one if it is too close to the controls' own
    /// colour (white in a dark theme, black in a light one) for them to read
    /// clearly, or if it is busy with fine detail, such as the page's own
    /// lines of text (device testing: the Sepia page's text under the slider,
    /// 21 Nov 2026). A band that is not needed is left out, so the glow and
    /// the page show behind the controls as they are, with no edge or fade.
    static func needsBand(behind pixels: [RGB], width: Int, darkTheme: Bool) -> Bool {
        let (poor, detail) = measure(pixels, width: width, darkTheme: darkTheme)
        return pixels.isEmpty || width < 2 || poor > backdropTolerance || detail > detailTolerance
    }

    /// The two shares `needsBand` weighs: of pixels too close to the
    /// controls' colour, and of pixels at fine detail.
    static func measure(_ pixels: [RGB], width: Int, darkTheme: Bool) -> (poor: Double, detail: Double) {
        guard !pixels.isEmpty, width > 1 else { return (1, 1) }
        // Each pixel's brightness, worked out once (it is the costly part).
        let luminances = pixels.map(\.luminance)
        let textLuminance = darkTheme ? 1.0 : 0.0
        var poor = 0, detailed = 0
        for index in luminances.indices {
            let l = luminances[index]
            let (high, low) = (max(l, textLuminance), min(l, textLuminance))
            if (high + 0.05) / (low + 0.05) < backdropContrast { poor += 1 }
            // Detail: neighbours along a row that differ clearly in brightness.
            if (index + 1) % width != 0, index + 1 < luminances.count,
               abs(l - luminances[index + 1]) > 0.04 { detailed += 1 }
        }
        return (Double(poor) / Double(pixels.count), Double(detailed) / Double(pixels.count))
    }

    // MARK: - The band's colour

    /// The band's colour for a glow whose colour at the band's edge is
    /// `edge`, on a page of colour `page`, under controls drawn in white (a
    /// dark theme, `darkTheme`) or black. The glow's colour
    /// itself where that is legible; otherwise the least step towards the
    /// page's colour that is.
    static func colour(edge: RGB, page: RGB, darkTheme: Bool) -> RGB {
        let text = darkTheme ? RGB.white : RGB.black
        for step in 0...20 {
            let colour = edge.mixed(with: page, Double(step) / 20)
            if contrast(colour, text) >= neededContrast { return colour }
        }
        return page
    }
}
