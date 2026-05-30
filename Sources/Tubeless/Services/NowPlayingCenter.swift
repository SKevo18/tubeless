import Foundation
import MediaPlayer
import AppKit

// bridges playback to the system "Now Playing" center so the media keys
// (fn+F8 / the play-pause key) and Control Center control THIS app.
// macOS routes the media keys to whichever app most recently published
// now-playing info — publishing it here takes them away from Apple Music.
@MainActor
final class NowPlayingCenter {
    static let shared = NowPlayingCenter()

    struct Handlers {
        let play: () -> Void
        let pause: () -> Void
        let toggle: () -> Void
        let next: () -> Void
        let previous: () -> Void
        let seek: (Double) -> Void
    }

    private var configured = false
    private var artworkTask: Task<Void, Never>?
    private var lastArtworkURL: URL?

    func configure(_ h: Handlers) {
        guard !configured else { return }
        configured = true
        let c = MPRemoteCommandCenter.shared()

        c.playCommand.addTarget { _ in h.play(); return .success }
        c.pauseCommand.addTarget { _ in h.pause(); return .success }
        c.togglePlayPauseCommand.addTarget { _ in h.toggle(); return .success }
        c.nextTrackCommand.addTarget { _ in h.next(); return .success }
        c.previousTrackCommand.addTarget { _ in h.previous(); return .success }
        c.changePlaybackPositionCommand.addTarget { event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            h.seek(e.positionTime)
            return .success
        }
        [c.playCommand, c.pauseCommand, c.togglePlayPauseCommand,
         c.nextTrackCommand, c.previousTrackCommand, c.changePlaybackPositionCommand]
            .forEach { $0.isEnabled = true }
    }

    func update(track: Track?, isPlaying: Bool, elapsed: Double, duration: Double) {
        let center = MPNowPlayingInfoCenter.default()
        guard let track else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            return
        }
        var info = center.nowPlayingInfo ?? [:]
        info[MPMediaItemPropertyTitle] = track.title
        info[MPMediaItemPropertyArtist] = track.displayChannel
        info[MPMediaItemPropertyPlaybackDuration] = duration
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        center.nowPlayingInfo = info
        center.playbackState = isPlaying ? .playing : .paused
        loadArtwork(track.thumbnailURL)
    }

    func clear() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }

    private func loadArtwork(_ url: URL?) {
        guard let url, url != lastArtworkURL else { return }
        lastArtworkURL = url
        artworkTask?.cancel()
        artworkTask = Task { [weak self] in
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = NSImage(data: data), !Task.isCancelled else { return }
            let art = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            let center = MPNowPlayingInfoCenter.default()
            guard self?.lastArtworkURL == url, var info = center.nowPlayingInfo else { return }
            info[MPMediaItemPropertyArtwork] = art
            center.nowPlayingInfo = info
        }
    }
}
