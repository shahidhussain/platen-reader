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

    // MARK: - How much band, and its colour

    /// What the band behind one of the controls' bars should be: its colour
    /// and how opaque (0: none at all, 1: solid), from what lies behind the
    /// bar (`pixels`, rows of a small picture of it, `width` across) under
    /// controls drawn in white (`darkTheme`) or black, on a page of colour
    /// `page` (the reader's model, 26 Nov 2026):
    ///
    /// - As see-through as it can be: none where the controls already read
    ///   clearly against what is behind (enough contrast, no busy detail);
    ///   some where they nearly do; solid only where they must have it.
    /// - Its colour always comes from what is behind, as the ambient glow's
    ///   does (their average colour), moved towards the page's colour only
    ///   as far as the controls need to read against it solid, so even a
    ///   solid band belongs to the page rather than sitting on it.
    ///
    /// The opacity is the least of two needs: enough that all but
    /// `backdropTolerance` of what is behind reaches `backdropContrast`
    /// against the controls once the band is laid over it; and enough to dim
    /// fine detail (the book's own lines of text, a busy picture), which a
    /// band of opacity α softens to (1 - α) of its strength, until even its
    /// busy rows are faint. Rounded up to a tenth, so a page barely
    /// different gives the same band.
    static func backing(behind pixels: [RGB], width: Int, darkTheme: Bool, page: RGB) -> (colour: RGB, opacity: Double) {
        guard !pixels.isEmpty, width > 1 else { return (page, 1) }
        let text = darkTheme ? RGB.white : RGB.black
        let count = Double(pixels.count)
        let average = RGB(r: pixels.reduce(0) { $0 + $1.r } / count, g: pixels.reduce(0) { $0 + $1.g } / count,
                          b: pixels.reduce(0) { $0 + $1.b } / count)
        let band = colour(edge: average, page: page, darkTheme: darkTheme)

        // Contrast: the least opacity each pixel needs (in twentieths),
        // and the level that covers all but the tolerated share.
        var needs = pixels.map { pixel -> Double in
            for step in 0...20 {
                let amount = Double(step) / 20
                if contrast(pixel.mixed(with: band, amount), text) >= backdropContrast { return amount }
            }
            return 1
        }
        needs.sort()
        let forContrast = needs[min(needs.count - 1, Int(Double(needs.count) * (1 - backdropTolerance)))]

        // Detail: how busy the busiest rows are. A line of the book's text
        // has sharp strokes all along it, so a few rows of it are busy
        // through and through, however much plain margin is round them (a
        // share of all the pixels missed the page's last line just behind
        // the location line, 26 Nov 2026); a clean edge in a picture or the
        // glow is a pixel or two per row. Each row's busyness is how strong
        // its strongest tenth of steps between neighbours are; the second
        // busiest row decides (one stray row does not), and the opacity
        // softens it below a faint difference.
        let luminances = pixels.map(\.luminance)
        var rowBusyness: [Double] = []
        for start in stride(from: 0, to: luminances.count - width + 1, by: width) {
            var steps = (start..<(start + width - 1)).map { abs(luminances[$0] - luminances[$0 + 1]) }
            steps.sort()
            rowBusyness.append(steps[Int(Double(steps.count) * 0.9)])
        }
        rowBusyness.sort(by: >)
        let strong = rowBusyness.count > 1 ? rowBusyness[1] : (rowBusyness.first ?? 0)
        let faint = 0.04
        let forDetail = strong > faint ? 1 - faint / strong : 0

        let opacity = (max(forContrast, forDetail) * 10).rounded(.up) / 10
        return (band, min(max(opacity, 0), 1))
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
