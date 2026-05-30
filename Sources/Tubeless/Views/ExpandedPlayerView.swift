import SwiftUI

struct ExpandedPlayerView: View {
    @EnvironmentObject var player: AudioPlayer
    @EnvironmentObject var nav: AppNavigation
    @EnvironmentObject var library: LibraryStore

    var body: some View {
        GeometryReader { geo in
            // the queue panel keeps its full width; the artwork shrinks to fit
            let panelW = min(380, max(150, geo.size.width - 90))
            let artW = max(min((geo.size.width - panelW) * 0.85, geo.size.height * 0.56, 360), 44)
            HStack(spacing: 0) {
                artworkPane(art: artW).frame(maxWidth: .infinity)
                Divider()
                sidePanel.frame(width: panelW)
            }
        }
        .background(.background)
    }

    private func artworkPane(art: CGFloat) -> some View {
        VStack(spacing: 16) {
            HStack {
                Button { nav.expanded = false } label: {
                    Image(systemName: "chevron.down").font(.title2.weight(.semibold)).padding(6)
                }
                .buttonStyle(.plain)
                Spacer()
            }
            Spacer(minLength: 0)
            PlayPauseArtwork(url: player.currentTrack?.thumbnailURL, size: art, corner: 14)
                .shadow(radius: 18, y: 8)
                .animation(.easeInOut(duration: 0.2), value: art)
            VStack(spacing: 6) {
                Text(player.currentTrack?.title ?? "Nothing playing")
                    .font(.title2.bold()).multilineTextAlignment(.center)
                    .lineLimit(2).minimumScaleFactor(0.6)
                Text(player.currentTrack?.displayChannel ?? "")
                    .font(.title3).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.6)
            }
            if let track = player.currentTrack {
                HStack(spacing: 22) {
                    Button { library.toggleLike(track) } label: {
                        Image(systemName: library.isLiked(track) ? "heart.fill" : "heart")
                            .foregroundStyle(library.isLiked(track) ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    }
                    .buttonStyle(.plain)
                    if player.downloading.contains(track.id) {
                        ProgressView().controlSize(.small)
                    } else {
                        Button { player.download(track) } label: { Image(systemName: "arrow.down.circle") }
                            .buttonStyle(.plain).foregroundStyle(.secondary).help("Download MP3")
                    }
                }
                .font(.title2)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
    }

    private var sidePanel: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Up Next").font(.headline)
                if player.isBuildingRadio {
                    ProgressView().controlSize(.small)
                    Text("building radio…").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { player.shuffleUpcoming() } label: { Image(systemName: "shuffle") }
                    .buttonStyle(.plain).disabled(player.queue.count < 2).help("Shuffle what's next")
                if player.isBuildingRadio {
                    ProgressView().controlSize(.small)
                } else {
                    Button { player.startRadio() } label: { Image(systemName: "dot.radiowaves.left.and.right") }
                        .buttonStyle(.plain).help("Rebuild queue as a radio")
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    // non-lazy so off-screen rows keep a real frame: a "play next" move
                    // from the bottom animates upward instead of vanishing while the rows
                    // below slide down (which read as moving the song to the bottom).
                    VStack(spacing: 2) {
                        ForEach(Array(player.queue.enumerated()), id: \.element.id) { idx, t in
                            TrackRow(track: t, dimmed: rowDimmed(idx: idx, id: t.id)) {
                                player.playQueueItem(t)
                            }
                            .id(t.id)
                        }

                        if !player.autoplay.isEmpty {
                            HStack(spacing: 6) {
                                Image(systemName: "dot.radiowaves.left.and.right").font(.caption)
                                Text("Autoplay").font(.caption.bold())
                                Spacer()
                            }
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10).padding(.top, 12).padding(.bottom, 4)

                            ForEach(Array(player.autoplay.enumerated()), id: \.element.id) { _, t in
                                TrackRow(track: t, dimmed: player.isBuildingRadio) {
                                    player.playAutoplayItem(t)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 10).padding(.bottom, 12)
                    .animation(.easeInOut(duration: 0.4), value: player.queue)
                }
                .onChange(of: player.currentIndex) { _ in
                    withAnimation { proxy.scrollTo(player.currentTrack?.id, anchor: .center) }
                }
            }
        }
    }

    // during a radio rebuild, dim every song except the one still playing
    private func rowDimmed(idx: Int, id: String) -> Bool {
        if player.isBuildingRadio { return id != player.currentTrack?.id }
        return idx < player.currentIndex
    }
}
