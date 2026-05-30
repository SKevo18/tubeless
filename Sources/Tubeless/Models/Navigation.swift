import SwiftUI

enum Page: Hashable {
    case home
    case search
    case library
    case playlist(UUID)
    case liked
    case artist(String)     // interpret detail page, keyed by artist name
}

// an artist hit derived from the song results (name + a representative thumbnail
// taken from one of their songs), shown in the search "Artists" section
struct ArtistResult: Identifiable, Hashable {
    let name: String
    let imageURL: URL?
    var id: String { name }
}

@MainActor
final class AppNavigation: ObservableObject {
    @Published var page: Page = .home
    // big "now playing" view visible — remembered across launches
    @Published var expanded = AppSettings.shared.playerExpanded {
        didSet { AppSettings.shared.playerExpanded = expanded }
    }
    @Published var query = ""
    @Published var searchResults: [Track] = []
    @Published var searchArtists: [ArtistResult] = []
    @Published var searchAlbums: [AlbumResult] = []
    @Published var searchPlaylists: [Playlist] = []
    @Published var searching = false
    @Published var searchError: String?
    @Published var suggestions: [String] = []
    @Published var showSuggestions = false

    // discovery is cached for the session so Home doesn't refetch on every visit
    @Published var discovery: [Track] = []
    @Published var discoveryLoading = false
    private var discoveryLoaded = false

    func loadDiscovery(force: Bool = false) {
        guard force || !discoveryLoaded, !discoveryLoading else { return }
        let seeds = LibraryStore.shared.topSeeds(limit: 6)
        guard !seeds.isEmpty else { discovery = []; discoveryLoaded = true; return }
        discoveryLoading = true
        Task { @MainActor in
            let recs = await Recommender.discovery(seeds: seeds,
                                                   limit: AppSettings.shared.recommendationRefreshCount)
            discovery = recs
            discoveryLoading = false
            discoveryLoaded = true
        }
    }

    // single-click: play a track and reveal the expanded player
    func play(_ track: Track, context: [Track]?, on player: AudioPlayer) {
        player.play(track, replacingQueueWith: context)
        expanded = true
    }

    // play a collection in shuffled order
    func playShuffled(_ tracks: [Track], on player: AudioPlayer) {
        let shuffled = tracks.shuffled()
        guard let first = shuffled.first else { return }
        play(first, context: shuffled, on: player)
    }

    // start a radio seeded from a collection's first track
    func startRadio(from tracks: [Track], on player: AudioPlayer) {
        guard let first = tracks.first else { return }
        player.startRadio(from: first)
        expanded = true
    }

    // page to return to from an interpret page (no full history stack needed)
    private var lastPage: Page = .home

    // open an interpret (artist) detail page; remembers where we came from
    func showArtist(_ name: String) {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        if case .artist = page {} else { lastPage = page }
        page = .artist(name)
        expanded = false
    }

    func goBack() { page = lastPage }

    func selectSuggestion(_ s: String, on settings: AppSettings) {
        query = s
        suggestions = []
        showSuggestions = false
        runSearch(on: settings)
    }

    func runSearch(on settings: AppSettings) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        page = .search
        expanded = false        // collapse the big player when searching
        showSuggestions = false
        searching = true
        searchError = nil
        searchResults = []; searchArtists = []; searchAlbums = []
        // local playlists match instantly by name
        searchPlaylists = LibraryStore.shared.playlists.filter {
            $0.name.range(of: q, options: .caseInsensitive) != nil
        }
        Task {
            // albums (MusicBrainz) resolve in parallel with the YouTube song search
            async let albumsTask = ArtistService.searchReleases(q, limit: 12)
            var found: [Track] = []
            var failure: String?
            do {
                found = try await YTDLPService.shared.search(
                    q, limit: 25, preferSongs: settings.preferSongVersions, ytdlp: settings.ytdlpPath)
            } catch {
                failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            searchResults = found
            searchArtists = Self.deriveArtists(from: found, limit: 10)
            searchAlbums = await albumsTask
            let nothing = found.isEmpty && searchArtists.isEmpty
                && searchAlbums.isEmpty && searchPlaylists.isEmpty
            searchError = nothing ? (failure ?? "No results.") : nil
            searching = false
        }
    }

    // distinct artists from the song results: only "<artist> - Topic" uploads
    // name an artist reliably, so derive from those, rank by how many songs each
    // contributed, and borrow one song's thumbnail as a stand-in image.
    private static func deriveArtists(from tracks: [Track], limit: Int) -> [ArtistResult] {
        var counts: [String: Int] = [:]
        var image: [String: URL?] = [:]
        var order: [String] = []
        for t in tracks where t.isTopic {
            let name = t.displayChannel.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            if counts[name] == nil { order.append(name); image[name] = t.thumbnailURL }
            counts[name, default: 0] += 1
        }
        return order
            .sorted { counts[$0]! > counts[$1]! }
            .prefix(limit)
            .map { ArtistResult(name: $0, imageURL: image[$0] ?? nil) }
    }
}
