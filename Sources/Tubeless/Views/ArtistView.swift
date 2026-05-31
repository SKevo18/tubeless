import SwiftUI

// interpret detail page: info (bio + image) from Wikipedia/Last.fm, top songs
// from YouTube, and albums / singles from MusicBrainz.
struct ArtistView: View {
    let name: String

    @EnvironmentObject var nav: AppNavigation
    @EnvironmentObject var player: AudioPlayer
    @EnvironmentObject var settings: AppSettings

    @State private var info: ArtistInfo?
    @State private var songs: [Track] = []
    @State private var releases: [Release] = []
    @State private var loadingInfo = true
    @State private var loadingSongs = true
    @State private var loadingDisco = true
    @State private var bioExpanded = false
    @State private var resolvingRelease: String?   // release-group id currently being opened

    private var albums: [Release] { releases.filter { $0.kind == .album } }
    private var singles: [Release] { releases.filter { $0.kind != .album } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                if !(info?.bio ?? "").isEmpty { bio }
                songsSection
                releaseSection("Albums", albums)
                releaseSection("Singles & EPs", singles)
            }
            .padding(.bottom, 24)
        }
        .task(id: name) { await load() }
    }

    // MARK: - header

    private var header: some View {
        HStack(alignment: .bottom, spacing: 20) {
            Artwork(url: info?.imageURL, size: 150, corner: 75)
                .overlay(Circle().stroke(.quaternary))
                .shadow(radius: 10, y: 4)
            VStack(alignment: .leading, spacing: 8) {
                Text("INTERPRET").font(.caption.bold()).foregroundStyle(.secondary)
                Text(name).font(.largeTitle.bold()).lineLimit(2)
                if let n = info?.listeners {
                    Text("\(n.formatted()) listeners on Last.fm")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 10) {
                    Button {
                        if let first = songs.first { nav.play(first, context: songs, on: player) }
                    } label: { Label("Play", systemImage: "play.fill").padding(.horizontal, 14).padding(.vertical, 7) }
                        .buttonStyle(.borderedProminent).disabled(songs.isEmpty)
                    Button {
                        if let first = songs.first { player.startRadio(from: first) }
                    } label: {
                        Label("Radio", systemImage: "dot.radiowaves.left.and.right")
                            .padding(.horizontal, 14).padding(.vertical, 7)
                    }
                    .buttonStyle(.bordered).disabled(songs.isEmpty)
                    externalLinks
                    if loadingInfo { ProgressView().controlSize(.small) }
                }
                .padding(.top, 4)
            }
            Spacer()
        }
        .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 6)
        .overlay(alignment: .topLeading) {
            Button { nav.goBack() } label: {
                Image(systemName: "chevron.left").font(.title3.weight(.semibold)).padding(6)
            }
            .buttonStyle(.icon).tooltip("Back").padding(.leading, 12).padding(.top, 6)
        }
    }

    @ViewBuilder private var externalLinks: some View {
        if let url = info?.wikipediaURL { linkButton(url, "book.closed", "Wikipedia") }
        if let url = info?.lastfmURL { linkButton(url, "waveform", "Last.fm") }
        if let url = info?.youtubeMusicURL { linkButton(url, "play.rectangle", "YouTube Music") }
    }

    private func linkButton(_ url: URL, _ icon: String, _ help: String) -> some View {
        Link(destination: url) { Image(systemName: icon) }
            .buttonStyle(.icon).foregroundStyle(.secondary).tooltip(help)
    }

    // MARK: - bio

    private var bio: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(info?.bio ?? "")
                .font(.subheadline).foregroundStyle(.secondary)
                .lineLimit(bioExpanded ? nil : 3)
                .fixedSize(horizontal: false, vertical: true)
            Button(bioExpanded ? "Show less" : "Show more") { bioExpanded.toggle() }
                .buttonStyle(.plain).font(.caption.bold()).foregroundStyle(.tint).pointerCursor()
        }
        .padding(.horizontal, 20).padding(.top, 10)
    }

    // MARK: - songs

    @ViewBuilder private var songsSection: some View {
        SectionHeader(title: "Songs")
        if loadingSongs && songs.isEmpty {
            loading("Finding songs…")
        } else if songs.isEmpty {
            empty("No songs found.")
        } else {
            LazyVStack(spacing: 2) {
                ForEach(songs) { t in
                    TrackRow(track: t) { nav.play(t, context: songs, on: player) }
                }
            }
            .padding(.horizontal, 12)
        }
    }

    // MARK: - releases

    @ViewBuilder private func releaseSection(_ title: String, _ items: [Release]) -> some View {
        if loadingDisco && releases.isEmpty {
            if title == "Albums" { SectionHeader(title: title); loading("Loading discography…") }
        } else if !items.isEmpty {
            SectionHeader(title: title)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(items) { r in
                        CoverCard(title: r.title,
                                  subtitle: [r.year, r.kind.rawValue].compactMap { $0 }.joined(separator: " · "),
                                  coverURL: r.coverURL,
                                  tooltipText: "Play “\(r.title)”",
                                  resolving: resolvingRelease == r.id) { playRelease(r) }
                    }
                }
                .padding(.horizontal, 20).padding(.vertical, 4)
            }
        }
    }

    private func loading(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text).font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20).padding(.vertical, 8)
    }

    private func empty(_ text: String) -> some View {
        Text(text).font(.subheadline).foregroundStyle(.secondary)
            .padding(.horizontal, 20).padding(.vertical, 8)
    }

    // MARK: - loading

    // play a release: match it to its YouTube Music album and play that album's
    // own track uploads directly — no per-track searching.
    private func playRelease(_ r: Release) {
        guard resolvingRelease == nil else { return }
        resolvingRelease = r.id
        Task {
            let album = await YTMusicService.album(artist: name, title: r.title, ytdlp: settings.ytdlpPath)
            resolvingRelease = nil
            if let tracks = album?.tracks, let first = tracks.first {
                nav.play(first, context: tracks, on: player)
            }
        }
    }

    private func load() async {
        // reset for a new interpret (the view is reused as the name changes)
        info = nil; songs = []; releases = []
        loadingInfo = true; loadingSongs = true; loadingDisco = true; bioExpanded = false

        async let profileTask = ArtistService.profile(for: name, lastfmKey: settings.lastfmApiKey)
        async let songTask = try? YTDLPService.shared.songs(
            by: name, limit: 12, preferSongs: settings.preferSongVersions, ytdlp: settings.ytdlpPath)

        songs = (await songTask) ?? []; loadingSongs = false
        let (i, r) = await profileTask
        info = i; loadingInfo = false
        releases = r; loadingDisco = false
    }
}
