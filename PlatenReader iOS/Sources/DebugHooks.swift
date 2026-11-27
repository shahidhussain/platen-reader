#if DEBUG
import Foundation
import UIKit

/// Debug-only hooks for checking the iOS reader from the command line, the
/// counterpart of the Mac's PLATEN_STEPS (see scripts/run-debug.sh).
///
/// Environment variables (set them as `SIMCTL_CHILD_<name>` for
/// `xcrun simctl launch`, which passes them on to the app):
/// - `PLATEN_OPEN_PATH=<path>` opens a book at launch (see SceneDelegate).
///   Use a path inside the app's container (copy the book into
///   `$(xcrun simctl get_app_container booted org.platenreader.PlatenReader data)/Documents`):
///   coordinated reads of paths on the Mac itself stall in the Simulator.
/// - `PLATEN_FOLDER_SEARCH=<words>` searches the folder view for them as
///   it first appears (with `PLATEN_FOLDER_PATH`).
/// - `PLATEN_FOLDER_PATH=<path>` chooses the folder the home screen shows
///   as covers, as "Choose Folder…" would (a folder inside the app's
///   container, for the same reason).
/// - `PLATEN_ADD_FAVOURITES=<path>|<path>|…` marks those books as
///   favourites, as a cover's long-press menu would, without the heart's
///   animation; the first named is shown first (marketing/screenshots,
///   which sets up the Home screen this way).
/// - `PLATEN_PRESS_FREEZE=<0…1>` holds the platen press (PlatenPress.swift)
///   still at that point and leaves it up, to look at its poses
///   (run-ios-debug.sh passes it on).
/// - `PLATEN_SLOW_CHECKS=<seconds>` makes every check of a listed folder or
///   book wait that long first, as a share that is not answering would
///   (the home screen's "Reconnecting…", then greyed if over the 6 s limit).
/// - `PLATEN_COPY_ALL_FAVOURITES=1` keeps a copy of every favourite on the
///   device, as if each were on a share (OfflineCopies).
/// - `PLATEN_ANIMATION_SPEED=<n>` runs the reader window's animations at
///   that speed (0.1: ten times slower), so a screenshot catches one
///   part-way (run-ios-debug.sh passes it on).
/// - `PLATEN_KEEP_CONTROLS=1` keeps the controls up once shown (no 4 s
///   timeout), so popovers can be opened by hand in the Simulator.
/// - `PLATEN_LOG_PAGE_FIT=1` logs where a PDF's pages sit on screen and at
///   what scale (`page fit: …`), after each page change.
/// - `PLATEN_STEPS="<step>;<step>"` runs steps 1.5 s apart after the first
///   page renders. A step is `@tap:<left|centre|right>` (as if that zone
///   were tapped), `@turn:<left|right|next|prev>` (a page turn, curled if
///   that is the setting), `@doubleturn:<…>` (two turns 0.15 s apart, the second
///   while the first is drawn), `@snapshot` (a snapshot of the web view), `@theme:<light|sepia|dark|black>`, `@orientation` (logs the device's
///   and the app's orientation), `@bookmark`, `@pageturn:<curl|slide|none>`, `@ambient:<on|off>`,
///   `@layout:<one|two|scroll>`, `@rotate:<landscape|portrait>`,
///   `@controls:<show|hide>`, `@shot:<name>` (saves the window as
///   tmp/shots/<name>.png in the app's container), `@wait` (nothing),
///   `@report` (logs the reader's state as
///   `report: {json}`, for scripts/ios-matrix.py),
///   `@close`, or JavaScript such as `platen.next()`. PDFs take `@turn:<…>`,
///   `@doubleturn:<…>`, `@swipe:<left|right>` (a finger drawn across the
///   page over 0.3 s; left brings the next page), `@zoom:<factor>` (zoom to
///   that many times the fit), `@fit` (back to the fit), `@orientation` and
///   `@close`. Each
///   step is logged as `step: …`; take screenshots between them with
///   `xcrun simctl io booted screenshot`.
extension ReaderBaseViewController {
    func runDebugStepsIfAny() {
        guard let list = ProcessInfo.processInfo.environment["PLATEN_STEPS"] else { return }
        // In the first window only: a window opened by a step ("@newwindow")
        // would otherwise run the steps again, and open another.
        guard UIApplication.shared.connectedScenes.count <= 1 else { return }
        runDebugSteps(list.split(separator: ";").map(String.init)[...])
    }

    /// Each step 1.5 s after the one before it ran (not at fixed times
    /// from the start: when the main thread is busy for a moment, the steps
    /// after it keep their spacing instead of running together).
    private func runDebugSteps(_ steps: ArraySlice<String>) {
        guard let step = steps.first else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            log.notice("step: \(step, privacy: .public)")
            self.runDebugStep(step)
            self.runDebugSteps(steps.dropFirst())
        }
    }
}
#endif
