import SwiftUI

/// Favourites are marked from a book's long-press menu, on its cover in a
/// folder or in Recent Books (not from inside the reader: the reader's
/// buttons are all about reading). Marking one is a small moment of "I love
/// this book", so a heart beats twice over the cover (lub-dub, lub-dub),
/// with a soft ring going out from it on the second beat, and the phone taps in
/// time. Taking one off is quiet. With Reduce Motion the heart only shows.
/// (On the Mac, a cover's menu is its right-click menu, and there are no
/// taps.)
@MainActor
enum Favourites {
    static var list: RecentList { RecentList.favorites }

    /// The device's taps, set by the iOS app (`Favourites+UIKit.swift`):
    /// in time with the heart when one is added, and a light tick when one
    /// is taken off. None on the Mac.
    static var heartbeatHaptics: () -> Void = {}
    static var removedHaptic: () -> Void = {}

    static func contains(_ url: URL) -> Bool { list.contains(url) }

    /// A book in a folder: added (with its title, author and a copy of its
    /// cover, read in the background while the folder's access is held), or
    /// taken off. Returns whether it is now a favourite.
    @discardableResult
    static func toggle(_ url: URL) -> Bool {
        if let item = list.item(at: url) {
            list.remove(item)
            removedHaptic()
            return false
        }
        list.addBook(url)
        heartbeatHaptics()
        return true
    }

    /// A book in Recent Books: its entry is copied, so this works even when
    /// the book is out of reach just now.
    @discardableResult
    static func toggle(_ item: RecentItem, from recents: RecentList) -> Bool {
        if let here = list.item(at: RecentItem.pathURL(item.path)) {
            list.remove(here)
            removedHaptic()
            return false
        }
        list.add(copyOf: item, from: recents)
        heartbeatHaptics()
        return true
    }

    /// The menu item: "Add to Favourites" or "Remove from Favourites".
    static func menuLabel(isFavourite: Bool) -> some View {
        isFavourite
            ? Label("Remove from Favourites", systemImage: "heart.slash")
            : Label("Add to Favourites", systemImage: "heart")
    }
}

/// The heart's size and its ring, and how much it shows, as the heartbeat
/// animation moves them.
struct Heartbeat {
    var opacity = 0.0
    var scale = 1.0
    var ring = 0.8
    var ringOpacity = 0.0
}

extension View {
    /// An orange heart (the app's one accent) that beats twice over the view and fades, each time
    /// `trigger` goes up (a book marked as a favourite).
    func heartbeat(_ trigger: Int) -> some View {
        modifier(HeartbeatOverlay(trigger: trigger))
    }
}

private struct HeartbeatOverlay: ViewModifier {
    let trigger: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.overlay {
            Image(systemName: "heart.fill")
                .font(.system(size: 44))
                .foregroundStyle(Color.platenAccent)
                .shadow(color: .black.opacity(0.3), radius: 4, y: 1)
                .keyframeAnimator(initialValue: Heartbeat(), trigger: trigger) { heart, beat in
                    heart
                        .scaleEffect(beat.scale)
                        .background {
                            Circle()
                                .stroke(Color.platenAccent, lineWidth: 2)
                                .frame(width: 56, height: 56)
                                .scaleEffect(beat.ring)
                                .opacity(beat.ringOpacity)
                        }
                        .opacity(beat.opacity)
                } keyframes: { _ in
                    // After the menu closes: shows, beats twice (a strong
                    // beat and a softer echo, a pause, then again a little
                    // gentler), holds a moment and fades.
                    KeyframeTrack(\.opacity) {
                        LinearKeyframe(0, duration: 0.3)
                        LinearKeyframe(1, duration: 0.08)
                        LinearKeyframe(1, duration: 1.4)
                        LinearKeyframe(0, duration: 0.35)
                    }
                    KeyframeTrack(\.scale) {
                        LinearKeyframe(1.0, duration: 0.3)
                        SpringKeyframe(reduceMotion ? 1 : 1.35, duration: 0.12, spring: .snappy)
                        SpringKeyframe(1.0, duration: 0.12, spring: .snappy)
                        SpringKeyframe(reduceMotion ? 1 : 1.2, duration: 0.11, spring: .snappy)
                        SpringKeyframe(1.0, duration: 0.3, spring: .smooth)
                        SpringKeyframe(reduceMotion ? 1 : 1.25, duration: 0.12, spring: .snappy)
                        SpringKeyframe(1.0, duration: 0.12, spring: .snappy)
                        SpringKeyframe(reduceMotion ? 1 : 1.12, duration: 0.11, spring: .snappy)
                        SpringKeyframe(1.0, duration: 0.35, spring: .smooth)
                    }
                    KeyframeTrack(\.ring) {
                        LinearKeyframe(0.8, duration: 0.31)
                        CubicKeyframe(1.8, duration: 0.6)
                        LinearKeyframe(0.8, duration: 0.07)
                        CubicKeyframe(1.8, duration: 0.6)
                    }
                    // One soft ring, on the second beat only (a ring on the
                    // first beat too was one too many).
                    KeyframeTrack(\.ringOpacity) {
                        LinearKeyframe(0, duration: 0.98)
                        LinearKeyframe(reduceMotion ? 0 : 0.45, duration: 0.01)
                        CubicKeyframe(0, duration: 0.6)
                    }
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}
