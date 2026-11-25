import SwiftUI

// The platen press: the one signature motion in Platen Reader
// (docs/platen-press.md). The app is named after the platen, the glass a
// page is pressed against in a scanner. The screen is that glass and the
// reader is underneath it, looking up. When a book opens, its first page is
// lowered onto the glass: small, faint, out of focus and a little crooked at
// first, it comes down, sharpens, and one corner touches the glass before
// the rest settles flat and square.
//
// It plays when a book is opened, and when the app goes back to a book at
// launch only if the loading bar had to show first; never on page turns,
// resizes, settings changes or returning to the app. Each reader keeps a
// plain cover in the page's colour over the page while it loads
// (`ReaderBaseViewController`, on each platform), takes a picture of the
// first page once it is drawn, and plays this over the cover, which goes
// when it ends: what is underneath is then exactly what the picture showed.

/// Every number in the decorative motions, in one place to tune them: the
/// press, and the bookmark ribbon (reader.js's ribbons use the same values,
/// sent with the settings; see `RibbonMotion`).
enum PlatenMotion {
    enum Press {
        /// Opening a book.
        static let openDuration: Double = 0.5
        /// Going back to a book at launch (after the loading bar).
        static let resumeDuration: Double = 0.35
        /// How lively the spring is: 0.15 is a damping fraction of 0.85, so
        /// the page settles with only a hint of adjusting itself; no
        /// overshoot can be seen (each part stops at its end).
        static let bounce: Double = 0.15
        /// With Reduce Motion: a plain fade from the page's colour.
        static let reducedDuration: Double = 0.15

        /// How far away the page starts (its size, as a share of the end).
        static let startScale: Double = 0.85
        /// How out of focus it starts (points).
        static let startBlur: Double = 12
        /// Its flat turn at the start: between these, either way (degrees).
        static let flatTurn: ClosedRange<Double> = 6...14
        /// Its tilt at the start, one edge nearer the glass (degrees).
        static let tilt: ClosedRange<Double> = 8...12
        /// How far the tilt's axis may stray from square to the corner that
        /// lands first (degrees), so no two presses are quite the same.
        static let tiltAxisJitter: Double = 20
        /// The tilt's perspective (SwiftUI's `rotation3DEffect`).
        static let perspective: Double = 0.5
        /// The shadow in the air (wide and soft) and on the glass (tight).
        static let shadowRadius: ClosedRange<Double> = 2...30
        static let shadowOpacity: ClosedRange<Double> = 0.04...0.22

        /// When each part has finished, as a share of the motion: it fades
        /// in, reaches the glass and comes into focus, squares up, then the
        /// leading corner having touched, the rest lands flat.
        static let opacityEnds: Double = 0.4
        static let scaleAndBlurEnd: Double = 0.7
        static let flatTurnEnds: Double = 0.85
        static let tiltAndShadowEnd: Double = 1
    }

    /// The bookmark ribbon's motions (bookmarks.js draws and moves the
    /// ribbons in books; `BookmarkRibbonView` on iOS PDFs).
    enum Ribbon {
        /// Adding: folded down onto the page from nearly end-on.
        static let layDuration: Double = 0.2
        /// How far from end-on it starts (degrees about the page's top
        /// edge; 90 would be edge-on to the reader).
        static let layStartFold: Double = 80
        /// It comes in from the page's outer side, angled off vertical.
        static let layStartSwing: Double = 15
        /// As it stops, a tiny pendulum swing that dies away.
        static let settleSwing: Double = 1.5
        static let settleDuration: Double = 0.15
        /// Removing: the same fold, in reverse.
        static let liftDuration: Double = 0.15
        /// With Reduce Motion: a fade in or out.
        static let reducedDuration: Double = 0.15

        /// As the web shell takes them (`platen.setRibbonMotion`).
        static var payload: [String: Double] {
            ["layDuration": layDuration, "layStartFold": layStartFold, "layStartSwing": layStartSwing,
             "settleSwing": settleSwing, "settleDuration": settleDuration, "liftDuration": liftDuration,
             "reducedDuration": reducedDuration]
        }
    }
}

/// How a book came to be opened, which decides whether it is pressed into
/// place, and how quickly.
enum PressOccasion: Equatable {
    /// The reader opened it (from Finder, Files, Home, another app).
    case open
    /// The app went back to it by itself at launch: pressed only if the
    /// loading bar had to show first.
    case resume

    var duration: Double {
        self == .open ? PlatenMotion.Press.openDuration : PlatenMotion.Press.resumeDuration
    }

    /// Whether the press plays: always on opening; on going back, only if
    /// the loading bar was needed (there is no timer).
    func plays(loadingWasShown: Bool) -> Bool { self == .open || loadingWasShown }
}

/// Where one press starts, chosen afresh each time: which way the page is
/// turned, how far, and which way it is tilted.
struct PressStart: Equatable {
    /// Its flat turn, in degrees: positive is clockwise.
    var turn: Double
    /// Its tilt, in degrees.
    var tilt: Double
    /// The axis it is tilted about, in the plane of the screen (x right, y
    /// down; a unit vector).
    var axisX: Double
    var axisY: Double

    /// The corner that lands first is the low one of the flat turn (the
    /// bottom right when turned clockwise, the bottom left otherwise), so
    /// the tilt brings that corner nearest the glass: about an axis square
    /// to the line from the middle to that corner, give or take a little.
    static func random<G: RandomNumberGenerator>(using generator: inout G) -> PressStart {
        let press = PlatenMotion.Press.self
        let clockwise = Bool.random(using: &generator)
        let turn = Double.random(in: press.flatTurn, using: &generator) * (clockwise ? 1 : -1)
        let tilt = Double.random(in: press.tilt, using: &generator)
        // The way to the corner that lands first (screen coordinates).
        let corner = atan2(1.0, clockwise ? 1.0 : -1.0)
        let jitter = Double.random(in: -press.tiltAxisJitter...press.tiltAxisJitter, using: &generator) * .pi / 180
        // The axis is square to it: turning about it by a positive angle
        // brings that corner towards the reader (checked on screen).
        let axis = corner + jitter - .pi / 2
        return PressStart(turn: turn, tilt: tilt, axisX: cos(axis), axisY: sin(axis))
    }

    static func random() -> PressStart {
        var generator = SystemRandomNumberGenerator()
        return random(using: &generator)
    }
}

/// The page's pose at one point in the press: everything that moves.
struct PressPose: Equatable {
    var opacity: Double
    var scale: Double
    var blur: Double
    var turn: Double
    var tilt: Double
    var shadowRadius: Double
    var shadowOpacity: Double

    /// At rest on the glass: exactly the page as the reader shows it.
    static let landed = PressPose(opacity: 1, scale: 1, blur: 0, turn: 0, tilt: 0,
                                  shadowRadius: PlatenMotion.Press.shadowRadius.lowerBound,
                                  shadowOpacity: PlatenMotion.Press.shadowOpacity.lowerBound)

    /// The pose when the motion has gone `progress` of the way (0 to 1; a
    /// spring may stray a touch past 1). Each part runs from the start to
    /// its own finishing point and then stays put, so the parts end one
    /// after another and none goes past its end.
    init(progress: Double, start: PressStart, reduceMotion: Bool = false) {
        let press = PlatenMotion.Press.self
        func part(_ end: Double) -> Double { min(max(progress / end, 0), 1) }
        // Exactly the end value once a part is done (no rounding left over).
        func blend(_ from: Double, _ to: Double, _ amount: Double) -> Double {
            amount >= 1 ? to : from + (to - from) * amount
        }
        if reduceMotion {
            // A plain fade from the page's colour.
            self = .landed
            opacity = min(max(progress, 0), 1)
            return
        }
        opacity = part(press.opacityEnds)
        let near = part(press.scaleAndBlurEnd)
        scale = blend(press.startScale, 1, near)
        blur = blend(press.startBlur, 0, near)
        turn = blend(start.turn, 0, part(press.flatTurnEnds))
        let landing = part(press.tiltAndShadowEnd)
        tilt = blend(start.tilt, 0, landing)
        shadowRadius = blend(press.shadowRadius.upperBound, press.shadowRadius.lowerBound, landing)
        shadowOpacity = blend(press.shadowOpacity.upperBound, press.shadowOpacity.lowerBound, landing)
    }

    init(opacity: Double, scale: Double, blur: Double, turn: Double, tilt: Double,
         shadowRadius: Double, shadowOpacity: Double) {
        self.opacity = opacity
        self.scale = scale
        self.blur = blur
        self.turn = turn
        self.tilt = tilt
        self.shadowRadius = shadowRadius
        self.shadowOpacity = shadowOpacity
    }
}

/// The press itself: a picture of the first page, lowered onto the page's
/// colour. It fills the page area exactly, so at the end it is the page as
/// shown, pixel for pixel, and the reader can take it away. It never takes
/// a touch or a click (the reader ends it early on any input).
struct PlatenPressView: View {
    let image: CGImage
    /// The picture's pixels per point.
    let scale: CGFloat
    /// The page's colour (the theme), which it fades in from.
    let background: Color
    let occasion: PressOccasion
    let start: PressStart
    let reduceMotion: Bool
    /// Debug builds: hold still at this point (for checking poses).
    var frozenAt: Double?
    let finished: () -> Void

    @State private var progress: Double = 0

    var body: some View {
        ZStack {
            background
            Image(decorative: image, scale: scale)
                .resizable()
                .modifier(PressEffect(progress: frozenAt ?? progress, start: start, reduceMotion: reduceMotion))
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear {
            guard frozenAt == nil else { return }
            let animation: Animation = reduceMotion
                ? .linear(duration: PlatenMotion.Press.reducedDuration)
                : .spring(duration: occasion.duration, bounce: PlatenMotion.Press.bounce)
            withAnimation(animation, completionCriteria: .logicallyComplete) {
                progress = 1
            } completion: {
                finished()
            }
        }
    }
}

/// The pose at the animated progress, applied to the page's picture.
private struct PressEffect: ViewModifier, Animatable {
    var progress: Double
    let start: PressStart
    let reduceMotion: Bool

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let pose = PressPose(progress: progress, start: start, reduceMotion: reduceMotion)
        content
            .rotation3DEffect(.degrees(pose.tilt), axis: (x: start.axisX, y: start.axisY, z: 0),
                              perspective: PlatenMotion.Press.perspective)
            .rotationEffect(.degrees(pose.turn))
            .scaleEffect(pose.scale)
            .shadow(color: .black.opacity(pose.shadowOpacity), radius: pose.shadowRadius,
                    y: pose.shadowRadius / 3)
            .blur(radius: pose.blur)
            .opacity(pose.opacity)
    }
}
