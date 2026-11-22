import XCTest

/// Tests of `HangWatch` and `MainThreadSampler` (Shared/HangWatch.swift):
/// what the diagnostics file says about a moment the main thread was busy.
final class HangWatchTests: XCTestCase {
    /// A look at the main thread, taken from another thread while the main
    /// thread is busy in a function of the tests, names that function.
    func testASampleOfTheBusyMainThreadNamesWhatItIsDoing() throws {
        #if !arch(arm64)
        throw XCTSkip("The sampler reads 64-bit ARM stacks only.")
        #else
        XCTAssertTrue(Thread.isMainThread)
        let sampler = MainThreadSampler()
        var calls: [String] = []
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
            calls = sampler.sample()
            done.signal()
        }
        Self.keepBusy(until: done)
        let text = calls.joined(separator: "\n")
        XCTAssertFalse(calls.isEmpty)
        XCTAssertTrue(text.contains("keepBusy"), text)
        #endif
    }

    /// Spins on the main thread until the sample has been taken.
    @inline(never)
    static func keepBusy(until done: DispatchSemaphore) {
        var spins = 0
        while done.wait(timeout: .now()) == .timedOut {
            spins &+= 1
        }
        XCTAssertGreaterThan(spins, 0)
    }

    func testALookIsCutAfterTheAppsFourthCall() {
        let calls = ["libsystem  wait", "Platen Reader.debug.dylib  a", "SwiftUICore  b",
                     "Platen Reader.debug.dylib  c", "Platen Reader.debug.dylib  d",
                     "Platen Reader.debug.dylib  e", "UIKitCore  f", "Platen Reader  main"]
        XCTAssertEqual(MainThreadSampler.trim(calls).last, "Platen Reader.debug.dylib  e")
        // None of the app's own: the innermost dozen.
        let system = (0..<30).map { "UIKitCore  f\($0)" }
        XCTAssertEqual(MainThreadSampler.trim(system).count, 12)
    }

    func testRepeatedLooksAreWrittenOnce() {
        let text = HangWatch.describe([["A  one", "B  two"], ["A  one", "B  two"], ["C  three"]])
        XCTAssertEqual(text, """

              look 1 at 300 ms:
                A  one
                B  two
              look 2: the same
              look 3 at 1300 ms:
                C  three
            """)
    }
}
