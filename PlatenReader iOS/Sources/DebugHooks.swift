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
/// - `PLATEN_FOLDER_PATH=<path>` chooses the folder the home screen shows
///   as covers, as "Choose Folder…" would (a folder inside the app's
///   container, for the same reason).
/// - `PLATEN_KEEP_CONTROLS=1` keeps the controls up once shown (no 4 s
///   timeout), so popovers can be opened by hand in the Simulator.
/// - `PLATEN_LOG_PAGE_FIT=1` logs where a PDF's pages sit on screen and at
///   what scale (`page fit: …`), after each page change.
/// - `PLATEN_STEPS="<step>;<step>"` runs steps 1.5 s apart after the first
///   page renders. A step is `@tap:<left|centre|right>` (as if that zone
///   were tapped), `@turn:<left|right|next|prev>` (a page turn, curled if
///   that is the setting), `@doubleturn:<…>` (two turns 0.15 s apart, the second
///   while the first is drawn), `@snapshot` (a snapshot of the web view), `@orientation` (logs the device's
///   and the app's orientation),
///   `@close`, or JavaScript such as `platen.next()`. PDFs take `@turn:<…>`,
///   `@doubleturn:<…>`, `@swipe:<left|right>` (a finger drawn across the
///   page over 0.3 s; left brings the next page), `@orientation` and
///   `@close`. Each
///   step is logged as `step: …`; take screenshots between them with
///   `xcrun simctl io booted screenshot`.
extension ReaderBaseViewController {
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
