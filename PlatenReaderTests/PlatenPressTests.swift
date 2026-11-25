import XCTest

/// Tests of the platen press's logic (Shared/PlatenPress.swift): when it
/// plays, where it starts, and that it ends exactly on the page as shown.
final class PlatenPressTests: XCTestCase {
    private let start = PressStart(turn: 10, tilt: 10, axisX: 0.7, axisY: -0.7)

    func testItPlaysOnOpeningAndOnGoingBackOnlyAfterTheLoadingBar() {
        XCTAssertTrue(PressOccasion.open.plays(loadingWasShown: false))
        XCTAssertTrue(PressOccasion.open.plays(loadingWasShown: true))
        XCTAssertTrue(PressOccasion.resume.plays(loadingWasShown: true))
        XCTAssertFalse(PressOccasion.resume.plays(loadingWasShown: false), "no timer: only the loading bar decides")
        XCTAssertEqual(PressOccasion.open.duration, 0.5, accuracy: 0.001)
        XCTAssertEqual(PressOccasion.resume.duration, 0.35, accuracy: 0.001)
    }

    func testItStartsFaintSmallBlurredTurnedAndTilted() {
        let pose = PressPose(progress: 0, start: start)
        XCTAssertEqual(pose.opacity, 0)
        XCTAssertEqual(pose.scale, PlatenMotion.Press.startScale, accuracy: 0.0001)
        XCTAssertEqual(pose.blur, PlatenMotion.Press.startBlur, accuracy: 0.0001)
        XCTAssertEqual(pose.turn, 10)
        XCTAssertEqual(pose.tilt, 10)
        XCTAssertEqual(pose.shadowRadius, PlatenMotion.Press.shadowRadius.upperBound)
    }

    /// The hand-over to the page itself must not jump: at the end, and
    /// past it (a spring strays a touch beyond), it is the page as shown.
    func testItEndsExactlyOnTheGlass() {
        XCTAssertEqual(PressPose(progress: 1, start: start), .landed)
        XCTAssertEqual(PressPose(progress: 1.01, start: start), .landed)
        XCTAssertEqual(PressPose.landed.scale, 1)
        XCTAssertEqual(PressPose.landed.turn, 0)
        XCTAssertEqual(PressPose.landed.tilt, 0)
        XCTAssertEqual(PressPose.landed.blur, 0)
    }

    /// The parts finish in order: it fades in, reaches the glass and comes
    /// into focus, squares up, and the tilt (the landing) resolves last.
    func testThePartsFinishInOrder() {
        let press = PlatenMotion.Press.self
        let faded = PressPose(progress: press.opacityEnds, start: start)
        XCTAssertEqual(faded.opacity, 1)
        XCTAssertLessThan(faded.scale, 1)

        XCTAssertLessThan(faded.glow, 1)
        XCTAssertEqual(PressPose(progress: 0, start: start).glow, 0, "the page's colour at first")

        let near = PressPose(progress: press.scaleAndBlurEnd, start: start)
        XCTAssertEqual(near.scale, 1)
        XCTAssertEqual(near.glow, 1, "the glow is all there once the page is full size")
        XCTAssertEqual(near.blur, 0)
        XCTAssertNotEqual(near.turn, 0)

        let square = PressPose(progress: press.flatTurnEnds, start: start)
        XCTAssertEqual(square.turn, 0)
        XCTAssertGreaterThan(square.tilt, 0, "the tilt is the last to go")
    }

    func testReduceMotionIsAPlainFade() {
        let halfway = PressPose(progress: 0.5, start: start, reduceMotion: true)
        XCTAssertEqual(halfway.opacity, 0.5, accuracy: 0.0001)
        XCTAssertEqual(halfway.scale, 1)
        XCTAssertEqual(halfway.blur, 0)
        XCTAssertEqual(halfway.turn, 0)
        XCTAssertEqual(halfway.tilt, 0)
    }

    /// Each start is chosen afresh, within the spec's ranges, either way
    /// round, and tilted so the corner that lands first (the low one of the
    /// turn) is the one nearest the glass.
    func testStartsAreRandomWithinTheirRanges() {
        var generator = SystemRandomNumberGenerator()
        var clockwise = 0
        for _ in 0..<200 {
            let start = PressStart.random(using: &generator)
            XCTAssertTrue(PlatenMotion.Press.flatTurn.contains(abs(start.turn)))
            XCTAssertTrue(PlatenMotion.Press.tilt.contains(start.tilt))
            XCTAssertEqual(start.axisX * start.axisX + start.axisY * start.axisY, 1, accuracy: 0.0001)
            // Turning about the axis by a positive angle brings the side at
            // the axis's angle plus a quarter turn nearest: that must be
            // towards the low corner (down, and right if clockwise).
            let nearX = -start.axisY, nearY = start.axisX
            XCTAssertGreaterThan(nearY, 0, "the bottom lands first")
            XCTAssertEqual(nearX > 0, start.turn > 0, "on the side the turn lowers")
            if start.turn > 0 { clockwise += 1 }
        }
        XCTAssertTrue((40...160).contains(clockwise), "either way round")
    }

    func testTheRibbonTimingsGoToTheWebShell() {
        let payload = PlatenMotion.Ribbon.payload
        XCTAssertEqual(payload["layDuration"], 0.2)
        XCTAssertEqual(payload["liftDuration"], 0.15)
        XCTAssertEqual(payload.count, 7)
    }
}
