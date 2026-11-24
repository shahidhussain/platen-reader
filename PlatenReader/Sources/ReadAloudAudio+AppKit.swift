import AppKit
import MediaPlayer

/// Read aloud's place in the Mac's audio: Now Playing (in Control Centre
/// and the menu bar: the book's cover, title and chapter; play and pause;
/// previous and next sentence, and no seek bar, as a reading has no set
/// length), worked by the keyboard's media keys and headphone controls.
///
/// One window reads at a time: a window that starts reading stops the one
/// that was. Each call names its window (`owner`), so a window that has
/// already been stopped cannot clear the newer one's Now Playing.
@MainActor
final class ReadAloudAudio {
    static let shared = ReadAloudAudio()

    private weak var owner: AnyObject?
    private var controls: ReadAloudControls?
    private var artwork: MPMediaItemArtwork?
    private var commandTargets: [(MPRemoteCommand, Any)] = []
    /// The latest Now Playing, kept so the cover can be added when it is
    /// ready.
    private var info: (title: String, author: String, chapter: String, playing: Bool)?

    /// `owner` begins reading: another window reading stops, and Now
    /// Playing shows this book.
    func begin(owner: AnyObject, title: String, author: String, chapter: String, controls: ReadAloudControls) {
        if let previous = self.owner, previous !== owner { self.controls?.stop() }
        self.owner = owner
        self.controls = controls
        artwork = nil
        installCommands()
        update(owner: owner, title: title, author: author, chapter: chapter, playing: true)
    }

    /// The book's cover, once it has been read.
    func setCover(_ image: NSImage, owner: AnyObject) {
        guard owner === self.owner else { return }
        artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        if let info { update(owner: owner, title: info.title, author: info.author, chapter: info.chapter, playing: info.playing) }
    }

    /// Now Playing kept up to date (the chapter changes as reading goes on).
    func update(owner: AnyObject, title: String, author: String, chapter: String, playing: Bool) {
        guard owner === self.owner else { return }
        info = (title, author, chapter, playing)
        var now: [String: Any] = [
            // The book's title, and its author under it: the chapter's
            // name alone ("I") said little on the lock screen. The chapter
            // is the album, which some places show.
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyAlbumTitle: chapter,
            MPNowPlayingInfoPropertyPlaybackRate: playing ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            // No length and no place in it: no seek bar.
            MPNowPlayingInfoPropertyIsLiveStream: true,
        ]
        if !author.isEmpty { now[MPMediaItemPropertyArtist] = author }
        if let artwork { now[MPMediaItemPropertyArtwork] = artwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = now
        MPNowPlayingInfoCenter.default().playbackState = playing ? .playing : .paused
    }

    /// `owner` stopped reading: Now Playing and the controls go (if it is
    /// still the window reading).
    func end(owner: AnyObject) {
        guard owner === self.owner else { return }
        self.owner = nil
        controls = nil
        artwork = nil
        info = nil
        for (command, target) in commandTargets { command.removeTarget(target) }
        commandTargets.removeAll()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }

    private func installCommands() {
        guard commandTargets.isEmpty else { return }
        let center = MPRemoteCommandCenter.shared()
        func add(_ command: MPRemoteCommand, _ action: @escaping @MainActor () -> Void) {
            command.isEnabled = true
            let target = command.addTarget { _ in
                MainActor.assumeIsolated { action() }
                return .success
            }
            commandTargets.append((command, target))
        }
        add(center.playCommand) { [weak self] in self?.controls?.play() }
        add(center.pauseCommand) { [weak self] in self?.controls?.pause() }
        add(center.togglePlayPauseCommand) { [weak self] in
            guard let self else { return }
            if MPNowPlayingInfoCenter.default().playbackState == .playing { self.controls?.pause() } else { self.controls?.play() }
        }
        add(center.nextTrackCommand) { [weak self] in self?.controls?.skip(1) }
        add(center.previousTrackCommand) { [weak self] in self?.controls?.skip(-1) }
        // No seeking, and no "15 seconds" skips: sentences are the steps.
        for command in [center.changePlaybackPositionCommand, center.skipForwardCommand, center.skipBackwardCommand,
                        center.seekForwardCommand, center.seekBackwardCommand] as [MPRemoteCommand] {
            command.isEnabled = false
        }
    }
}
