import SwiftUI
import UIKit

/// Books in windows of their own (iPad; plan, phase 6).
///
/// Each window (a scene) can hold a book. What a window holds is described
/// by a user activity of type `BookWindows.activityType` carrying the book's
/// bookmark (a reference that survives the file moving, and keeps
/// permission to read it):
///
/// - "Open in New Window" (a cover's long-press menu, on iPad) asks iOS for
///   a new window with that activity; the new window opens the book.
/// - Each window hands iOS the same kind of activity for its open book
///   (`SceneDelegate.stateRestorationActivity`), so when iOS ends Platen in
///   the background and the reader comes back, every window reopens its own
///   book (state restoration).
///
/// On iPhone there is one window, and launching goes back to the last book
/// as before (`LastOpenBook`).
enum BookWindows {
    /// Declared in Info.plist (NSUserActivityTypes), so iOS hands it to a
    /// new window.
    static let activityType = "org.platenreader.book"
    private static let bookmarkKey = "bookmark"

    /// Whether this device can show more than one window (iPad, and Macs
    /// running the iPad app).
    @MainActor static var supported: Bool { UIApplication.shared.supportsMultipleScenes }

    /// The activity for a book, from its bookmark.
    static func activity(bookmark: Data, title: String) -> NSUserActivity {
        let activity = NSUserActivity(activityType: activityType)
        activity.title = title
        activity.addUserInfoEntries(from: [bookmarkKey: bookmark])
        return activity
    }

    /// The bookmark in an activity of ours, if it is one.
    static func bookmark(in activity: NSUserActivity?) -> Data? {
        guard let activity, activity.activityType == activityType else { return nil }
        return activity.userInfo?[bookmarkKey] as? Data
    }

    /// A bookmark for a book the app can read now (one just opened, or in a
    /// folder it holds access to). Nil if the system will not make one.
    static func bookmark(for url: URL) -> Data? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try? url.bookmarkData()
    }

    /// Opens the book in a new window.
    @MainActor static func open(bookmark: Data, title: String) {
        let activity = activity(bookmark: bookmark, title: title)
        UIApplication.shared.requestSceneSessionActivation(nil, userActivity: activity, options: nil) { error in
            log.error("Could not open a new window: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Opens the book at `url` in a new window.
    @MainActor static func open(url: URL, title: String) {
        guard let bookmark = bookmark(for: url) else { return }
        open(bookmark: bookmark, title: title)
    }

    /// The "Open in New Window" item for a cover's long-press menu; nothing
    /// where only one window can be shown (iPhone).
    struct MenuItem: View {
        let action: () -> Void
        var body: some View {
            if BookWindows.supported {
                Button(action: action) { Label("Open in New Window", systemImage: "rectangle.badge.plus") }
            }
        }
    }
}
