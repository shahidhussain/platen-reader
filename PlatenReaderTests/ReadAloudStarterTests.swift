import XCTest

/// Tests of `ReadAloudStarter` (Shared/ReadAloudStarter.swift): what the
/// speaker button does in both apps (start, pause, resume, the first-time
/// question in English books), with a stand-in for the reader window and its
/// text.
@MainActor
final class ReadAloudStarterTests: XCTestCase {
    private var savedChoice: ReadAloudVoiceChoice!
    private var savedAvailable = false

    override func setUp() async throws {
        savedChoice = ReadAloudSettings.shared.choice
        savedAvailable = KokoroVoice.downloadAvailable
    }

    override func tearDown() async throws {
        ReadAloudSettings.shared.choice = savedChoice
        KokoroVoice.downloadAvailable = savedAvailable
    }

    func testWhileReadingTheButtonPausesThenResumes() {
        let (state, source, host) = make()
        let starter = ReadAloudStarter(state: state, host: host)
        state.readAloud = .playing
        starter.toggle()
        XCTAssertEqual(source.calls, ["pause"])
        state.readAloud = .paused
        starter.toggle()
        XCTAssertEqual(source.calls, ["pause", "resume"])
        starter.stop()
        XCTAssertEqual(source.calls, ["pause", "resume", "stop"])
    }

    func testAnEnglishBookAsksWhichVoiceFirst() throws {
        try XCTSkipUnless(KokoroVoice.hasMemoryForIt, "the natural voice is not offered on this machine")
        KokoroVoice.downloadAvailable = true
        ReadAloudSettings.shared.choice = .undecided
        let (state, source, host) = make()
        let starter = ReadAloudStarter(state: state, host: host)
        starter.toggle()
        // Nothing read yet: the question is asked, with Apple's voice, the
        // download, and Cancel.
        XCTAssertEqual(source.calls, [])
        XCTAssertEqual(host.questions.count, 1)
        XCTAssertEqual(host.questions.first?.buttons.count, 2)
        XCTAssertEqual(host.questions.first?.cancellable, true)
    }

    func testChoosingTheDownloadDownloadsFirstAndRemembersTheChoice() throws {
        try XCTSkipUnless(KokoroVoice.hasMemoryForIt, "the natural voice is not offered on this machine")
        try XCTSkipIf(KokoroVoice.isInstalled, "the natural voice is installed here")
        KokoroVoice.downloadAvailable = true
        ReadAloudSettings.shared.choice = .undecided
        let (state, _, host) = make()
        let starter = ReadAloudStarter(state: state, host: host)
        starter.toggle()
        host.questions.first?.buttons[1].action()
        XCTAssertEqual(ReadAloudSettings.shared.choice, .kokoro)
        XCTAssertEqual(host.downloads, 1)
    }

    /// While reading, moving the page stops the page following the voice
    /// at once (it used to turn straight back to the sentence being read),
    /// before reading starts again from the new page.
    func testMovingThePageWhileReadingHoldsThePageAtOnce() {
        let (state, source, host) = make()
        let starter = ReadAloudStarter(state: state, host: host)
        state.readAloud = .playing
        starter.pageMovedByHand()
        XCTAssertEqual(source.calls, ["hold"])
    }

    func testMovingThePageWhileOffDoesNothing() {
        let (state, source, host) = make()
        let starter = ReadAloudStarter(state: state, host: host)
        starter.pageMovedByHand()
        let waited = expectation(description: "past the restart delay")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { waited.fulfill() }
        wait(for: [waited], timeout: 2)
        XCTAssertEqual(source.calls, [])
    }

    func testMovingThePageWhilePausedStopsReading() {
        let (state, source, host) = make()
        let starter = ReadAloudStarter(state: state, host: host)
        state.readAloud = .paused
        starter.pageMovedByHand()
        let waited = expectation(description: "past the restart delay")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { waited.fulfill() }
        wait(for: [waited], timeout: 2)
        // The page stops following the voice at once; then, paused, it
        // stops (so the speaker starts again on the new page), rather than
        // reading from there.
        XCTAssertEqual(source.calls, ["hold", "stop"])
    }

    /// Reading that ends with nothing to say (a scanned PDF) is explained,
    /// rather than just stopping.
    func testReadingThatFindsNoTextSaysSo() {
        let (state, _, host) = make()
        let starter = ReadAloudStarter(state: state, host: host)
        state.readAloudFoundNoText += 1
        let waited = expectation(description: "the message")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { waited.fulfill() }
        wait(for: [waited], timeout: 2)
        XCTAssertEqual(host.questions.count, 1)
        XCTAssertTrue(host.questions.first?.message.contains("no readable text") == true)
        withExtendedLifetime(starter) {}
    }

    private func make() -> (ReaderState, FakeSource, FakeHost) {
        let state = ReaderState()
        let source = FakeSource()
        let host = FakeHost(source: source)
        return (state, source, host)
    }
}

@MainActor
private final class FakeSource: ReadAloudSource {
    var calls: [String] = []
    var canReadAloud: Bool { true }
    var readAloudLanguage: String { "en-GB" }
    func startReadAloud(engine: SpeechEngine) { calls.append("start") }
    func pauseReadAloud() { calls.append("pause") }
    func resumeReadAloud() { calls.append("resume") }
    func stopReadAloud() { calls.append("stop") }
    func skipReadAloud(by delta: Int) { calls.append("skip \(delta)") }
    func holdReadAloudPage() { calls.append("hold") }
}

@MainActor
private final class FakeHost: ReadAloudHost {
    let source: FakeSource
    var questions: [(message: String, buttons: [ReadAloudPromptButton], cancellable: Bool)] = []
    var downloads = 0

    init(source: FakeSource) { self.source = source }

    var readAloudSource: ReadAloudSource? { source }
    func readAloudAsk(message: String, buttons: [ReadAloudPromptButton], cancellable: Bool) {
        questions.append((message, buttons, cancellable))
    }
    func readAloudDownloadVoice(done: @escaping (Bool) -> Void) { downloads += 1 }
    func readAloudAudioBegin(controls: ReadAloudControls) {}
    func readAloudAudioUpdate(chapter: String, playing: Bool) {}
    func readAloudAudioEnd() {}
}
