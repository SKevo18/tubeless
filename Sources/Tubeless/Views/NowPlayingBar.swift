import SwiftUI

struct NowPlayingBar: View {
    @EnvironmentObject var player: AudioPlayer
    @EnvironmentObject var nav: AppNavigation
    @EnvironmentObject var library: LibraryStore

    var body: some View {
        VStack(spacing: 4) {
            if let err = player.lastError {
                HStack(spacing: 8) {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange).lineLimit(2)
                    Button("Retry") { player.retryCurrent() }
                        .controlSize(.small).buttonStyle(.bordered)
                }
                .padding(.horizontal, 16).padding(.top, 4)
            }
            HStack(spacing: 12) {
                nowPlayingInfo.frame(minWidth: 130, maxWidth: 300, alignment: .leading)
                Spacer(minLength: 6)
                transport
                Spacer(minLength: 6)
                rightControls.frame(minWidth: 140, maxWidth: 230)
            }
            .padding(.horizontal, 16)
            ZStack(alignment: .top) {
                scrubber
                skipToast.offset(y: -26)
            }
        }
        .padding(.vertical, 9)
        .background(.bar)
    }

    @ViewBuilder private var skipToast: some View {
        if let skip = player.skippedSegment {
            Text(skip)
                .font(.caption.weight(.semibold)).fixedSize().lineLimit(1)
                .padding(.horizontal, 14).padding(.vertical, 5)
                .background(.tint, in: Capsule()).foregroundStyle(.white)
                .shadow(radius: 3, y: 1)
                .transition(.opacity.combined(with: .scale))
                .animation(.easeInOut, value: player.skippedSegment)
        }
    }

    private var nowPlayingInfo: some View {
        HStack(spacing: 10) {
            PlayPauseArtwork(url: player.currentTrack?.thumbnailURL, size: 46)
            VStack(alignment: .leading, spacing: 2) {
                Text(player.currentTrack?.title ?? "Nothing playing")
                    .font(.subheadline.weight(.medium)).lineLimit(1).minimumScaleFactor(0.85)
                Text(player.currentTrack?.displayChannel ?? "—")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.85)
            }
            .contentShape(Rectangle())
            .onTapGesture { if player.currentTrack != nil { nav.expanded.toggle() } }
            .pointerCursor()
            .tooltip("Open player")
            if let track = player.currentTrack {
                Button { library.toggleLike(track) } label: {
                    Image(systemName: library.isLiked(track) ? "heart.fill" : "heart")
                        .foregroundStyle(library.isLiked(track) ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                }
                .buttonStyle(.icon).font(.callout)
                .tooltip(library.isLiked(track) ? "Unlike" : "Like")
            }
        }
    }

    private var transport: some View {
        HStack(spacing: 16) {
            Button { player.shuffleUpcoming() } label: { Image(systemName: "shuffle") }
                .buttonStyle(.icon).disabled(player.queue.count < 2).tooltip("Shuffle what's next")
            Button(action: player.previous) { Image(systemName: "backward.fill") }
                .buttonStyle(.icon).tooltip("Previous")
            ZStack {
                if player.isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Button(action: player.togglePlayPause) {
                        Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 36)).foregroundStyle(.tint)
                    }
                    .buttonStyle(.icon).tooltip(player.isPlaying ? "Pause" : "Play")
                }
            }
            .frame(width: 38, height: 38)
            Button(action: player.next) { Image(systemName: "forward.fill") }
                .buttonStyle(.icon).disabled(!player.hasNext).tooltip("Next")
            Button(action: player.cycleRepeat) {
                Image(systemName: player.repeatMode == .song ? "repeat.1" : "repeat")
                    .foregroundStyle(player.repeatMode == .off ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
            }
            .buttonStyle(.icon).tooltip("Repeat: \(repeatLabel)")
        }
        .font(.title3)
    }

    private var repeatLabel: String {
        switch player.repeatMode {
        case .off: return "off"
        case .queue: return "queue"
        case .song: return "song"
        }
    }

    private var rightControls: some View {
        HStack(spacing: 12) {
            Button { player.startRadio() } label: { Image(systemName: "dot.radiowaves.left.and.right") }
                .buttonStyle(.icon).foregroundStyle(.secondary)
                .disabled(player.currentTrack == nil).tooltip("Start radio")
            Image(systemName: "speaker.fill").font(.caption2).foregroundStyle(.secondary)
            Slider(value: $player.volume, in: 0...1)
            Button { nav.expanded.toggle() } label: {
                Image(systemName: nav.expanded ? "chevron.down" : "chevron.up")
                    .font(.title2.weight(.semibold)).padding(8).contentShape(Rectangle())
            }
            .buttonStyle(.icon).foregroundStyle(.secondary)
            .disabled(player.currentTrack == nil)
            .tooltip(nav.expanded ? "Hide player" : "Show player")
        }
    }

    private var scrubber: some View {
        HStack(spacing: 8) {
            Text(timeText(player.currentTime)).font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary).frame(width: 38, alignment: .trailing)
            SponsorTimeline(duration: player.duration, currentTime: player.currentTime,
                            segments: player.segments, onSeek: { player.seek(to: $0) })
                .opacity(player.currentTrack == nil ? 0.4 : 1)
            Text(timeText(player.duration)).font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary).frame(width: 38, alignment: .leading)
        }
        .padding(.horizontal, 16)
    }

    private func timeText(_ s: Double) -> String {
        guard s.isFinite, s >= 0 else { return "0:00" }
        let t = Int(s); return String(format: "%d:%02d", t / 60, t % 60)
    }
}
