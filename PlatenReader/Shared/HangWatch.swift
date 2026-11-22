import Foundation

/// Notes in the log when the main thread was too busy to answer a tap for a
/// while ("main thread busy for 420 ms"), so a reader's "it sometimes
/// doesn't respond" can be traced to what was going on then.
///
/// A background timer asks the main thread to answer ten times a second;
/// when an answer comes late by more than `threshold`, the delay is logged.
/// Cheap (one tiny block on the main queue every tenth of a second) and
/// local: it writes to the device's own log and the app's diagnostics file
/// (`DiagnosticLog`), which nothing sends anywhere (spec: no telemetry); the
/// reader can share the file from Settings. The lines just before a busy
/// moment in that file say what was going on.
final class HangWatch: @unchecked Sendable {
    static let shared = HangWatch()

    /// Delays shorter than this pass unremarked: a tap answered within a
    /// quarter of a second feels immediate enough.
    static let threshold: TimeInterval = 0.25

    private let queue = DispatchQueue(label: "org.platenreader.hang-watch", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var waiting = false
    private var asked = Date()

    func start() {
        queue.async { [self] in
            guard timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 1, repeating: 0.1, leeway: .milliseconds(20))
            timer.setEventHandler { [weak self] in self?.tick() }
            timer.resume()
            self.timer = timer
        }
    }

    private func tick() {
        // Still waiting for the last answer: the main thread is busy.
        guard !waiting else { return }
        waiting = true
        asked = Date()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let late = Date().timeIntervalSince(self.asked)
            self.queue.async {
                self.waiting = false
                if late > Self.threshold {
                    log.notice("main thread busy for \(Int(late * 1000), privacy: .public) ms")
                }
            }
        }
    }
}
