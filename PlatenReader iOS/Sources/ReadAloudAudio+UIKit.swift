import AVFoundation
import MediaPlayer
import UIKit

/// Read aloud's place in the system's audio (iOS): the audio session for
/// spoken audio, kept going in the background and at the lock screen
/// (Info.plist's audio background mode), the lock screen's Now Playing (the
/// book's cover, title and chapter; play and pause; previous and next
/// sentence, and no seek bar, as a reading has no set length), and pausing
/// for calls and when headphones are unplugged, as audiobook apps do.
@MainActor
final class ReadAloudAudio {
    static let shared = ReadAloudAudio()

    /// What the lock screen's controls and interruptions do to the reading.
    typealias Controls = ReadAloudControls

    /// The book's cover on the lock screen, set by `begin`.
    private var artwork: MPMediaItemArtwork?

    private var controls: Controls?
    private var observers: [NSObjectProtocol] = []
    private var commandTargets: [(MPRemoteCommand, Any)] = []
    /// Paused by a call (not by the reader): resumed when the call ends, if
    /// iOS says it should.
    private var pausedByInterruption = false
    /// iOS took the audio session away (another app's audio, a call): it
    /// is made active again when reading goes on, as iOS asks.
    private var sessionTaken = false

    /// Reading begins: the session becomes active and Now Playing shows the
    /// book.
    func begin(title: String, author: String, chapter: String, cover: UIImage?, controls: Controls) {
        self.controls = controls
        artwork = cover.map { image in MPMediaItemArtwork(boundsSize: image.size) { _ in image } }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .spokenAudio, options: [])
            try session.setActive(true)
        } catch {
            log.error("Read aloud: audio session: \(error.localizedDescription, privacy: .public)")
        }
        watch(session)
        // The app takes the lock screen's and headphones' controls (the
        // remote commands below); said to UIKit too, for older routes.
        UIApplication.shared.beginReceivingRemoteControlEvents()
        installCommands()
        update(title: title, author: author, chapter: chapter, playing: true)
        log.info("read aloud: Now Playing shown (\(cover == nil ? "no cover" : "with cover", privacy: .public))")
    }

    /// The book's cover, once read from the book itself (when Recent Books
    /// had no copy of it to hand).
    func setCover(_ image: UIImage) {
        guard controls != nil else { return }
        artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPMediaItemPropertyArtwork] = artwork
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        log.info("read aloud: Now Playing cover read from the book")
    }

    /// Now Playing kept up to date (the chapter changes as reading goes on).
    func update(title: String, author: String, chapter: String, playing: Bool) {
        if playing, sessionTaken {
            // Reading goes on after another app's audio or a call (by the
            // speaker, the lock screen, or iOS saying to resume).
            sessionTaken = false
            do { try AVAudioSession.sharedInstance().setActive(true) } catch {
                log.error("Read aloud: audio session after an interruption: \(error.localizedDescription, privacy: .public)")
            }
        }
        var info: [String: Any] = [
            // The book's title, and its author under it: the chapter's
            // name alone ("I") said little on the lock screen. The chapter
            // is the album, which some places show.
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyAlbumTitle: chapter,
            MPNowPlayingInfoPropertyPlaybackRate: playing ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            // No length and no place in it: the lock screen shows no seek
            // bar.
            MPNowPlayingInfoPropertyIsLiveStream: true,
        ]
        if !author.isEmpty { info[MPMediaItemPropertyArtist] = author }
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = playing ? .playing : .paused
    }

    /// Reading has stopped: Now Playing and the controls go, and other
    /// apps' audio may resume.
    func end() {
        log.info("read aloud: Now Playing ended")
        controls = nil
        artwork = nil
        pausedByInterruption = false
        sessionTaken = false
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        for (command, target) in commandTargets { command.removeTarget(target) }
        commandTargets.removeAll()
        UIApplication.shared.endReceivingRemoteControlEvents()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func installCommands() {
        guard commandTargets.isEmpty else { return }
        let center = MPRemoteCommandCenter.shared()
        func add(_ command: MPRemoteCommand, _ action: @escaping () -> Void) {
            command.isEnabled = true
            let target = command.addTarget { _ in
                action()
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

    private func watch(_ session: AVAudioSession) {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        // Another app's audio (music, a podcast, a video), a call or an
        // alarm: pause, as audiobook apps do; afterwards, go on only if iOS
        // says to (after a call; not when another app simply played).
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: session,
                                            queue: .main) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
            let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt)
                .map(AVAudioSession.InterruptionOptions.init) ?? []
            MainActor.assumeIsolated {
                guard let self else { return }
                switch type {
                case .began:
                    log.info("read aloud: paused, as other audio took over")
                    self.sessionTaken = true
                    self.pausedByInterruption = true
                    self.controls?.pause()
                case .ended:
                    log.info("read aloud: the other audio ended (\(options.contains(.shouldResume) ? "going on" : "staying paused", privacy: .public))")
                    if self.pausedByInterruption, options.contains(.shouldResume) { self.controls?.play() }
                    self.pausedByInterruption = false
                default: break
                }
            }
        })
        // Headphones unplugged (or a Bluetooth speaker gone): pause, rather
        // than carry on aloud from the phone's speaker.
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: session,
                                            queue: .main) { [weak self] note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt)
                .flatMap(AVAudioSession.RouteChangeReason.init)
            MainActor.assumeIsolated {
                if reason == .oldDeviceUnavailable { self?.controls?.pause() }
            }
        })
    }
}
