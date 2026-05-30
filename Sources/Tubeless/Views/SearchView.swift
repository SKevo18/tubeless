import SwiftUI

struct SearchView: View {
    @EnvironmentObject var nav: AppNavigation
    @EnvironmentObject var player: AudioPlayer
    @EnvironmentObject var settings: AppSettings
    @State private var resolvingAlbum: String?     // release-group id currently being opened

    private var isEmpty: Bool {
        nav.searchResults.isEmpty && nav.searchArtists.isEmpty
            && nav.searchAlbums.isEmpty && nav.searchPlaylists.isEmpty
    }

    var body: some View {
        if let err = nav.searchError {
            placeholder("exclamationmark.triangle", "Search failed", err)
        } else if isEmpty {
            placeholder("magnifyingglass", "Search YouTube",
                        "Song versions are preferred over music videos.")
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if !nav.searchArtists.isEmpty { artistSection }
                    if !nav.searchAlbums.isEmpty { albumSection }
                    if !nav.searchPlaylists.isEmpty { playlistSection }
                    if !nav.searchResults.isEmpty { songSection }
                }
                .padding(.bottom, 24)
            }
        }
    }

    @ViewBuilder private var artistSection: some View {
        SectionHeader(title: "Artists")
        cardRow { ForEach(nav.searchArtists) { ArtistResultCard(artist: $0) } }
    }

    @ViewBuilder private var albumSection: some View {
        SectionHeader(title: "Albums")
        cardRow {
            ForEach(nav.searchAlbums) { album in
                ReleaseCard(release: album.release, resolving: resolvingAlbum == album.id) {
                    playAlbum(album)
                }
            }
        }
    }

    @ViewBuilder private var playlistSection: some View {
        SectionHeader(title: "Playlists")
        cardRow { ForEach(nav.searchPlaylists) { PlaylistCard(playlist: $0) } }
    }

    @ViewBuilder private var songSection: some View {
        SectionHeader(title: "Songs")
        LazyVStack(spacing: 2) {
            ForEach(nav.searchResults) { track in
                TrackRow(track: track) { nav.play(track, context: nav.searchResults, on: player) }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func cardRow<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 16) { content() }
                .padding(.horizontal, 20).padding(.vertical, 4)
        }
    }

    // play an album: resolve its MusicBrainz tracklist to YouTube, play the first
    // track immediately and fill the rest into the queue as they load (mirrors the
    // artist page's release playback, using the album's own artist credit).
    private func playAlbum(_ album: AlbumResult) {
        guard resolvingAlbum == nil else { return }
        resolvingAlbum = album.id
        let artist = album.artist
        Task {
            let titles = await ArtistService.tracklist(releaseGroupID: album.id)
            var queries = titles.isEmpty ? ["\(artist) \(album.release.title)"]
                                         : titles.map { "\(artist) \($0)" }
            while !queries.isEmpty {
                let q = queries.removeFirst()
                if let t = try? await YTDLPService.shared.firstResult(for: q, ytdlp: settings.ytdlpPath) {
                    nav.play(t, context: [t], on: player)
                    break
                }
            }
            resolvingAlbum = nil
            player.fillQueue(resolving: queries, ytdlp: settings.ytdlpPath)
        }
    }

    private func placeholder(_ icon: String, _ title: String, _ subtitle: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 38)).foregroundStyle(.tertiary)
            Text(title).font(.headline)
            Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// circular artist hit that opens the artist detail page on tap
struct ArtistResultCard: View {
    let artist: ArtistResult
    @EnvironmentObject var nav: AppNavigation
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 6) {
            Artwork(url: artist.imageURL, size: 120, corner: 60)
                .overlay(Circle().stroke(.quaternary))
                .overlay(Circle().stroke(.tint, lineWidth: hovering ? 2 : 0))
                .shadow(radius: hovering ? 6 : 0)
            Text(artist.name).font(.subheadline).lineLimit(1).frame(width: 120)
            Text("Artist").font(.caption).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .pointerCursor()
        .animation(.easeOut(duration: 0.12), value: hovering)
        .tooltip("Open \(artist.name)")
        .onTapGesture { nav.showArtist(artist.name) }
    }
}
