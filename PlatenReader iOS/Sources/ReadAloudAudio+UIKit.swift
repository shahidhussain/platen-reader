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
        installCommands()
        update(title: title, author: author, chapter: chapter, playing: true)
    }

    /// Now Playing kept up to date (the chapter changes as reading goes on).
    func update(title: String, author: String, chapter: String, playing: Bool) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: chapter.isEmpty ? title : chapter,
            MPMediaItemPropertyAlbumTitle: title,
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
        controls = nil
        artwork = nil
        pausedByInterruption = false
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        for (command, target) in commandTargets { command.removeTarget(target) }
        commandTargets.removeAll()
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
        // A call or an alarm: pause; afterwards, go on if iOS says to.
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: session,
                                            queue: .main) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
            let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt)
                .map(AVAudioSession.InterruptionOptions.init) ?? []
            MainActor.assumeIsolated {
                guard let self else { return }
                switch type {
                case .began:
                    self.pausedByInterruption = true
                    self.controls?.pause()
                case .ended:
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
