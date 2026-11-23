import XCTest
@testable import Kokoro

/// Tests of the natural voice's model code that need no weights (the
/// weights are in the downloaded voice pack, not in the repository).
final class KokoroTests: XCTestCase {
    /// The STFT and its inverse undo each other, as torch.stft and
    /// torch.istft do (the generator's sound comes out through the inverse).
    func testTheInverseSTFTGivesBackTheSignal() {
        var signal = [Float](repeating: 0, count: 600)
        for n in signal.indices {
            let t = Float(n)
            let low: Float = 0.5 * sin(t * 0.31)
            let high: Float = 0.2 * sin(t * 1.7 + 1)
            let rough: Float = 0.05 * Float((n * 7919) % 13) / 13
            signal[n] = low + high + rough
        }
        let (magnitude, phase, frames) = kokoroSTFT(signal)
        XCTAssertEqual(frames, 600 / 5 + 1)
        let back = kokoroInverseSTFT(magnitude: magnitude, phase: phase, frames: frames)
        XCTAssertEqual(back.count, signal.count)
        let worst = zip(back, signal).map { abs($0 - $1) }.max() ?? 1
        XCTAssertLessThan(worst, 1e-4)
    }
}
