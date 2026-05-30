import SwiftUI

struct HomeView: View {
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var nav: AppNavigation

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                if library.recentlyPlayed.isEmpty && nav.discovery.isEmpty {
                    emptyState
                } else {
                    if !library.recentlyPlayed.isEmpty {
                        cardRow("Listen again", tracks: library.recentlyPlayed)
                    }
                    discoverySection
                    if !library.playlists.isEmpty { playlistRow }
                }
            }
            .padding(.bottom, 24)
        }
        .onAppear { nav.loadDiscovery() }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "music.note.house").font(.system(size: 44)).foregroundStyle(.tertiary)
            Text("Welcome to Tubeless").font(.title2.bold())
            Text("Search for a song to start. Your recently played and personalized\npicks will appear here.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 360)
    }

    @ViewBuilder private var discoverySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("Discovery").font(.title2.bold())
                if nav.discoveryLoading { ProgressView().controlSize(.small) }
                Spacer()
                Button { nav.loadDiscovery(force: true) } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.icon).foregroundStyle(.secondary)
                .tooltip("Refresh recommendations")
            }
            .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 10)

            if nav.discovery.isEmpty {
                Text(nav.discoveryLoading ? "Finding music you'll like…"
                                          : "Play a few songs and we'll suggest more like them.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .padding(.horizontal, 20).padding(.bottom, 12)
            } else {
                cards(nav.discovery)
            }
        }
    }

    private func cardRow(_ title: String, tracks: [Track]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: title)
            cards(tracks)
        }
    }

    private func cards(_ tracks: [Track]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 16) {
                ForEach(tracks) { TrackCard(track: $0, context: tracks) }
            }
            .padding(.horizontal, 20).padding(.vertical, 4)
        }
    }

    private var playlistRow: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Your playlists")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(library.playlists) { PlaylistCard(playlist: $0) }
                }
                .padding(.horizontal, 20).padding(.vertical, 4)
            }
        }
    }
}

struct PlaylistCard: View {
    let playlist: Playlist
    @EnvironmentObject var nav: AppNavigation
    @EnvironmentObject var player: AudioPlayer
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                Artwork(url: playlist.tracks.first?.thumbnailURL, size: 148, corner: 10)
                if hovering && !playlist.tracks.isEmpty {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 34)).foregroundStyle(.white, .tint)
                        .padding(8).shadow(radius: 4)
                }
            }
            Text(playlist.name).font(.subheadline).lineLimit(1).frame(width: 148, alignment: .leading)
            Text("\(playlist.tracks.count) songs").font(.caption).foregroundStyle(.secondary)
                .frame(width: 148, alignment: .leading)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .pointerCursor()
        .onTapGesture {
            if let first = playlist.tracks.first { nav.play(first, context: playlist.tracks, on: player) }
        }
        .contextMenu {
            Button("Open playlist") { nav.page = .playlist(playlist.id); nav.expanded = false }
            Divider()
            Button("Play") { if let f = playlist.tracks.first { nav.play(f, context: playlist.tracks, on: player) } }
            Button("Shuffle") { nav.playShuffled(playlist.tracks, on: player) }
            Button("Start radio") { nav.startRadio(from: playlist.tracks, on: player) }
        }
    }
}
