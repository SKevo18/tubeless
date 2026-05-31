import SwiftUI
import UniformTypeIdentifiers

struct ExpandedPlayerView: View {
    @EnvironmentObject var player: AudioPlayer
    @EnvironmentObject var nav: AppNavigation
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var downloads: DownloadManager
    @State private var dragging: Track?
    @State private var dropTarget: String?
    @State private var autoScroll = 0       // -1 up / +1 down while hovering an edge
    @State private var rowY: [String: CGFloat] = [:]   // each queue row's top, in scroll space
    @State private var viewportH: CGFloat = 0

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
                .buttonStyle(.icon).tooltip("Collapse player")
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
                if let ch = player.currentTrack?.displayChannel {
                    ArtistLink(name: ch, font: .title3).minimumScaleFactor(0.6)
                }
            }
            if let track = player.currentTrack {
                HStack(spacing: 22) {
                    Button { library.toggleLike(track) } label: {
                        Image(systemName: library.isLiked(track) ? "heart.fill" : "heart")
                            .foregroundStyle(library.isLiked(track) ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    }
                    .buttonStyle(.icon).tooltip(library.isLiked(track) ? "Unlike" : "Like")
                    if downloads.isActive(track.id) {
                        ProgressView().controlSize(.small)
                    } else {
                        Button { downloads.start(track) } label: { Image(systemName: "arrow.down.circle") }
                            .buttonStyle(.icon).foregroundStyle(.secondary).tooltip("Download MP3")
                    }
                    ShareButton(track: track).foregroundStyle(.secondary)
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
                } else if player.loadingQueue > 0 {
                    ProgressView().controlSize(.small)
                    Text("loading \(player.loadingQueue) more…").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { player.shuffleUpcoming() } label: { Image(systemName: "shuffle") }
                    .buttonStyle(.icon).disabled(player.queue.count < 2).tooltip("Shuffle what's next")
                if player.isBuildingRadio {
                    ProgressView().controlSize(.small)
                } else {
                    Button { player.startRadio() } label: { Image(systemName: "dot.radiowaves.left.and.right") }
                        .buttonStyle(.icon).tooltip("Rebuild queue as a radio")
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
                            .reorderable(t, in: player.queue, dragging: $dragging, dropTarget: $dropTarget,
                                         move: { player.reorderQueue(from: $0, to: $1) })
                            .background(GeometryReader { g in
                                Color.clear.preference(key: RowOffsetKey.self,
                                                       value: [t.id: g.frame(in: .named("queue")).minY])
                            })
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
                .coordinateSpace(name: "queue")
                .background(GeometryReader { g in
                    Color.clear.onAppear { viewportH = g.size.height }
                        .onChange(of: g.size.height) { viewportH = $0 }
                })
                .onPreferenceChange(RowOffsetKey.self) { rowY = $0 }
                .onChange(of: player.currentIndex) { _ in
                    withAnimation { proxy.scrollTo(player.currentTrack?.id, anchor: .center) }
                }
                .onAppear {
                    // focus the song that's playing when the queue panel opens
                    if let id = player.currentTrack?.id { proxy.scrollTo(id, anchor: .center) }
                }
                // while dragging a row, hovering the top/bottom edge auto-scrolls the
                // queue so it can be dropped beyond the visible window
                .overlay(alignment: .top) { edgeZone(-1) }
                .overlay(alignment: .bottom) { edgeZone(1) }
                .task(id: autoScroll) {
                    guard autoScroll != 0 else { return }
                    while !Task.isCancelled && autoScroll != 0 {
                        let ids = player.queue.map(\.id)
                        // step one row past whatever is currently at the edge, reading
                        // the live scroll position so it continues from wherever we are
                        if let target = stepTarget(autoScroll, ids: ids) {
                            withAnimation(.linear(duration: 0.32)) {
                                proxy.scrollTo(ids[target], anchor: autoScroll < 0 ? .top : .bottom)
                            }
                        }
                        try? await Task.sleep(nanoseconds: 280_000_000)
                    }
                }
            }
        }
    }

    // next row to bring into view, based on the current visible range
    private func stepTarget(_ direction: Int, ids: [String]) -> Int? {
        guard !ids.isEmpty else { return nil }
        if direction > 0 {
            let last = ids.lastIndex { (rowY[$0] ?? .infinity) < viewportH - 8 } ?? (ids.count - 1)
            return min(ids.count - 1, last + 1)
        } else {
            let first = ids.firstIndex { (rowY[$0] ?? -.infinity) > -46 } ?? 0
            return max(0, first - 1)
        }
    }

    // transparent edge strip that drives auto-scroll while a drag hovers it
    private func edgeZone(_ direction: Int) -> some View {
        Color.clear
            .frame(height: 36)
            .allowsHitTesting(dragging != nil)
            .onDrop(of: [.url, .text], isTargeted: Binding(
                get: { autoScroll == direction },
                set: { targeted in
                    if targeted { autoScroll = direction }
                    else if autoScroll == direction { autoScroll = 0 }
                })) { _ in false }
    }

    // during a radio rebuild, dim every song except the one still playing
    private func rowDimmed(idx: Int, id: String) -> Bool {
        if player.isBuildingRadio { return id != player.currentTrack?.id }
        return idx < player.currentIndex
    }
}

// reports each queue row's top offset within the scroll view so edge auto-scroll
// can read the real visible range instead of guessing
private struct RowOffsetKey: PreferenceKey {
    static let defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue()) { _, new in new }
    }
}
