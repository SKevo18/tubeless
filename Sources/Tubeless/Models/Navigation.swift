import SwiftUI

enum Page: Hashable {
    case home
    case search
    case library
    case playlist(UUID)
    case liked
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
        Task {
            do {
                let found = try await YTDLPService.shared.search(
                    q, limit: 25, preferSongs: settings.preferSongVersions, ytdlp: settings.ytdlpPath)
                searchResults = found
                if found.isEmpty { searchError = "No results." }
            } catch {
                searchError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                searchResults = []
            }
            searching = false
        }
    }
}
