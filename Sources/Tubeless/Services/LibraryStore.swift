import Foundation
import Combine

// persists recently-played history, liked songs and playlists to
// ~/Library/Application Support/Tubeless/library.json
@MainActor
final class LibraryStore: ObservableObject {
    static let shared = LibraryStore()

    @Published private(set) var recentlyPlayed: [Track] = []
    @Published private(set) var liked: [Track] = []
    @Published private(set) var playlists: [Playlist] = []
    @Published private(set) var scores: [String: SongStat] = [:]

    // per-song engagement used to weight recommendations
    struct SongStat: Codable {
        var track: Track
        var playCount: Int
        var listenSeconds: Double
        var lastPlayed: Date
    }

    private let fileURL: URL
    private var recentLimit: Int { max(10, AppSettings.shared.recentlyPlayedLimit) }

    private init() {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tubeless", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("library.json")
        load()
    }

    // MARK: - recently played

    func recordPlayed(_ track: Track) {
        recentlyPlayed.removeAll { $0.id == track.id }
        recentlyPlayed.insert(track, at: 0)
        if recentlyPlayed.count > recentLimit {
            recentlyPlayed = Array(recentlyPlayed.prefix(recentLimit))
        }
        save()
    }

    // MARK: - likes / library

    func isLiked(_ track: Track) -> Bool { liked.contains { $0.id == track.id } }

    func toggleLike(_ track: Track) {
        if isLiked(track) { liked.removeAll { $0.id == track.id } }
        else { liked.insert(track, at: 0) }
        save()
    }

    // MARK: - playlists

    @discardableResult
    func createPlaylist(name: String, tracks: [Track] = []) -> Playlist {
        let p = Playlist(name: name, tracks: tracks)
        playlists.append(p)
        save()
        return p
    }

    func renamePlaylist(_ id: UUID, to name: String) {
        guard let i = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[i].name = name
        save()
    }

    func deletePlaylist(_ id: UUID) {
        playlists.removeAll { $0.id == id }
        save()
    }

    func addToPlaylist(_ track: Track, playlistID: UUID) {
        guard let i = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        guard !playlists[i].tracks.contains(where: { $0.id == track.id }) else { return }
        playlists[i].tracks.append(track)
        save()
    }

    func removeFromPlaylist(_ track: Track, playlistID: UUID) {
        guard let i = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        playlists[i].tracks.removeAll { $0.id == track.id }
        save()
    }

    // drag-reorder a single track within a playlist
    func moveInPlaylist(_ playlistID: UUID, from: Int, to: Int) {
        guard let i = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        guard playlists[i].tracks.indices.contains(from),
              playlists[i].tracks.indices.contains(to), from != to else { return }
        let t = playlists[i].tracks.remove(at: from)
        playlists[i].tracks.insert(t, at: to)
        save()
    }

    // MARK: - scoring

    // accumulate listen time + play count for a finished play
    func recordListen(_ track: Track, seconds: Double) {
        var st = scores[track.id] ?? SongStat(track: track, playCount: 0, listenSeconds: 0, lastPlayed: Date())
        st.track = track
        st.listenSeconds += seconds
        st.playCount += 1
        st.lastPlayed = Date()
        scores[track.id] = st
        save()
    }

    // engagement score: minutes listened + plays + completion + a like bonus
    func score(for id: String) -> Double {
        guard let st = scores[id] else { return isLikedID(id) ? 5 : 0 }
        let completion: Double = {
            guard let d = st.track.duration, d > 0 else { return 0 }
            return min(st.listenSeconds / d, Double(st.playCount))
        }()
        return st.listenSeconds / 60 + Double(st.playCount) + completion + (isLikedID(id) ? 5 : 0)
    }

    // best seed tracks for discovery: liked + most-engaged + recent, de-duped
    func topSeeds(limit: Int) -> [Track] {
        let scored = scores.values
            .sorted { score(for: $0.track.id) > score(for: $1.track.id) }
            .map(\.track)
        var seen = Set<String>(), out: [Track] = []
        for t in liked + scored + recentlyPlayed {
            if seen.insert(t.id).inserted { out.append(t) }
            if out.count >= limit { break }
        }
        return out
    }

    // most-engaged songs, for the Library "Most played" view
    func mostPlayed(limit: Int) -> [SongStat] {
        Array(scores.values
            .filter { $0.playCount > 0 }
            .sorted { score(for: $0.track.id) > score(for: $1.track.id) }
            .prefix(limit))
    }

    private func isLikedID(_ id: String) -> Bool { liked.contains { $0.id == id } }

    // MARK: - persistence

    private struct Snapshot: Codable {
        var recentlyPlayed: [Track]
        var liked: [Track]
        var playlists: [Playlist]
        var scores: [String: SongStat]
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let snap = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        recentlyPlayed = snap.recentlyPlayed
        liked = snap.liked
        playlists = snap.playlists
        scores = snap.scores
    }

    private func save() {
        let snap = Snapshot(recentlyPlayed: recentlyPlayed, liked: liked,
                            playlists: playlists, scores: scores)
        guard let data = try? JSONEncoder().encode(snap) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
