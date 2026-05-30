import SwiftUI

struct LibraryView: View {
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var nav: AppNavigation
    @EnvironmentObject var player: AudioPlayer

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SectionHeader(title: "Library")

                row(icon: "heart.fill", title: "Liked Songs",
                    subtitle: "\(library.liked.count) songs") { nav.page = .liked }

                if !library.playlists.isEmpty {
                    Text("Playlists").font(.headline)
                        .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 4)
                    ForEach(library.playlists) { p in
                        row(icon: "music.note.list", title: p.name,
                            subtitle: "\(p.tracks.count) songs") { nav.page = .playlist(p.id) }
                    }
                }

                let topPlayed = library.mostPlayed(limit: 25)
                if !topPlayed.isEmpty {
                    Text("Most played").font(.headline)
                        .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 4)
                    LazyVStack(spacing: 2) {
                        ForEach(Array(topPlayed.enumerated()), id: \.element.track.id) { i, st in
                            statRow(rank: i + 1, stat: st, context: topPlayed.map(\.track))
                        }
                    }
                    .padding(.horizontal, 12)
                }

                if !library.recentlyPlayed.isEmpty {
                    Text("Recently played").font(.headline)
                        .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 4)
                    LazyVStack(spacing: 2) {
                        ForEach(library.recentlyPlayed) { t in
                            TrackRow(track: t) { nav.play(t, context: library.recentlyPlayed, on: player) }
                        }
                    }
                    .padding(.horizontal, 12)
                }
            }
            .padding(.bottom, 24)
        }
    }

    private func statRow(rank: Int, stat: LibraryStore.SongStat, context: [Track]) -> some View {
        HStack(spacing: 12) {
            Text("\(rank)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 22, alignment: .trailing)
            Artwork(url: stat.track.thumbnailURL)
            VStack(alignment: .leading, spacing: 2) {
                Text(stat.track.title).lineLimit(1)
                Text("\(stat.playCount) play\(stat.playCount == 1 ? "" : "s") · \(listenText(stat.listenSeconds)) listened")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 4).padding(.horizontal, 8)
        .contentShape(Rectangle())
        .onTapGesture { nav.play(stat.track, context: context, on: player) }
    }

    private func listenText(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m" }
        return "\(total)s"
    }

    private func row(icon: String, title: String, subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .frame(width: 46, height: 46)
                    .background(.tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading) {
                    Text(title)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 20).padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct LikedView: View {
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var player: AudioPlayer
    @EnvironmentObject var nav: AppNavigation

    var body: some View {
        TrackListPage(title: "Liked Songs", systemImage: "heart.fill", tracks: library.liked)
    }
}

struct PlaylistView: View {
    let playlistID: UUID
    @EnvironmentObject var library: LibraryStore

    var body: some View {
        if let p = library.playlists.first(where: { $0.id == playlistID }) {
            TrackListPage(title: p.name, systemImage: "music.note.list",
                          tracks: p.tracks, playlistID: p.id)
        } else {
            Text("Playlist not found").foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// shared header + play-all + track list used by Liked and Playlist pages
struct TrackListPage: View {
    let title: String
    let systemImage: String
    let tracks: [Track]
    var playlistID: UUID? = nil

    @EnvironmentObject var player: AudioPlayer
    @EnvironmentObject var nav: AppNavigation
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 16) {
                    Image(systemName: systemImage)
                        .font(.system(size: 40)).foregroundStyle(.white)
                        .frame(width: 120, height: 120)
                        .background(LinearGradient(colors: [settings.accentColor, settings.accentColor.opacity(0.5)],
                                                   startPoint: .top, endPoint: .bottom),
                                    in: RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 6) {
                        Text(title).font(.largeTitle.bold())
                        Text("\(tracks.count) songs").foregroundStyle(.secondary)
                        Button {
                            if let first = tracks.first { nav.play(first, context: tracks, on: player) }
                        } label: {
                            Label("Play", systemImage: "play.fill")
                                .padding(.horizontal, 18).padding(.vertical, 8)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(tracks.isEmpty)
                        .padding(.top, 4)
                    }
                    Spacer()
                }
                .padding(20)

                if tracks.isEmpty {
                    Text("No songs yet.").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 160)
                } else {
                    LazyVStack(spacing: 2) {
                        ForEach(tracks) { t in
                            TrackRow(track: t, inPlaylist: playlistID) { nav.play(t, context: tracks, on: player) }
                        }
                    }
                    .padding(.horizontal, 12)
                }
            }
            .padding(.bottom, 24)
        }
    }
}
