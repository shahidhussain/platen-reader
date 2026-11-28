import SwiftUI

// The few places where the home screen's views (shared by the iOS app's tabs
// and the Mac's Home window) differ by platform, kept together so the views
// themselves read the same on both. Nothing here imports UIKit or AppKit.

extension Notification.Name {
    /// The app has come back to the front: lists check again whether their
    /// books and folders can be reached, and a folder reads itself again.
    /// These are the system's own notifications, named by their raw values
    /// (shared code cannot import UIKit or AppKit): iOS's "will enter
    /// foreground", and the Mac's "did become active".
    #if os(iOS)
    static let platenAppReturned = Notification.Name("UIApplicationWillEnterForegroundNotification")
    #else
    static let platenAppReturned = Notification.Name("NSApplicationDidBecomeActiveNotification")
    #endif

    /// Asks the folder view to read its folder again (a reader was closed;
    /// the book may have been moved or deleted meanwhile).
    static let platenFolderShouldRefresh = Notification.Name("platenFolderShouldRefresh")
}

extension ToolbarItemPlacement {
    /// The buttons at the trailing end of the bar: the top right on iOS, the
    /// toolbar's own place for a window's main buttons on the Mac.
    static var homeTrailing: ToolbarItemPlacement {
        #if os(iOS)
        .topBarTrailing
        #else
        .primaryAction
        #endif
    }
}

/// Whether a cover grid has the room of an iPad (or a Mac window) rather than
/// an iPhone's: more covers across by default. Read from the size class on
/// iOS; a Mac window is always roomy (a pinch on the trackpad, or View ›
/// Bigger and Smaller Covers, changes the count).
struct RoomyGrid: DynamicProperty {
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    var isRoomy: Bool { sizeClass == .regular }
    #else
    var isRoomy: Bool { true }
    #endif
}
