#if DEBUG
import Foundation

/// Debug-only hooks for checking the iOS reader from the command line, the
/// counterpart of the Mac's PLATEN_STEPS (see scripts/run-debug.sh).
///
/// Environment variables (set them as `SIMCTL_CHILD_<name>` for
/// `xcrun simctl launch`, which passes them on to the app):
/// - `PLATEN_OPEN_PATH=<path>` opens a book at launch (see SceneDelegate).
///   Use a path inside the app's container (copy the book into
///   `$(xcrun simctl get_app_container booted org.platenreader.PlatenReader data)/Documents`):
///   coordinated reads of paths on the Mac itself stall in the Simulator.
/// - `PLATEN_STEPS="<step>;<step>"` runs steps 1.5 s apart after the first
///   page renders. A step is `@tap:<left|centre|right>` (as if that zone
///   were tapped), `@close`, or JavaScript such as `platen.next()`. Each
///   step is logged as `step: …`; take screenshots between them with
///   `xcrun simctl io booted screenshot`.
extension ReaderViewController {
    func runDebugStepsIfAny() {
        guard let list = ProcessInfo.processInfo.environment["PLATEN_STEPS"] else { return }
        let steps = list.split(separator: ";").map(String.init)
        for (i, step) in steps.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5 * Double(i + 1)) { [weak self] in
                log.notice("step: \(step, privacy: .public)")
                self?.runDebugStep(step)
            }
        }
    }
}
#endif
