import Foundation

// A YouTube Music album. Unlike the old MusicBrainz path (which matched each
// track title back to a separate YouTube search), `tracks` already holds the
// album's own canonical uploads — one flat resolve gives title, cover and the
// exact playable video ids, so playback is instant and correct.
struct MusicAlbum: Identifiable, Hashable {
    let id: String          // YT Music browse id (MPREb…)
    let title: String
    let artist: String
    let year: String?
    let coverURL: URL?
    let tracks: [Track]

    var subtitle: String {
        [year, artist.isEmpty ? nil : artist].compactMap { $0 }.joined(separator: " · ")
    }
}

// a YouTube Music artist hit (canonical name + channel). the image is the
// channel's thumbnail (a video still) — the real artist photo still comes from
// Wikipedia on the artist page, which yt-dlp can't provide.
struct MusicArtist: Identifiable, Hashable {
    let id: String          // channel id (UC…)
    let name: String
    let imageURL: URL?
}

// a YouTube Music playlist, resolved to its tracks so it can be played directly
struct MusicPlaylist: Identifiable, Hashable {
    let id: String          // playlist browse id (VL…)
    let title: String
    let coverURL: URL?
    let tracks: [Track]
}

// reads structured data straight from music.youtube.com via yt-dlp. albums,
// artists and playlists are the sweet spot: a single flat call resolves a whole
// collection cheaply, where per-song metadata would need slow per-video fetches.
enum YTMusicService {
    // cap concurrent yt-dlp resolves so a search can't spawn a swarm of processes
    private static let gate = Semaphore(6)

    static func searchAlbums(_ query: String, limit: Int, ytdlp: String) async -> [MusicAlbum] {
        let urls = await flatHits(query, section: "albums", idPrefix: "MPREb", limit: limit, ytdlp: ytdlp)
        return await resolveAll(urls) { await resolveAlbum($0, ytdlp: ytdlp) }
    }

    static func searchArtists(_ query: String, limit: Int, ytdlp: String) async -> [MusicArtist] {
        let urls = await flatHits(query, section: "artists", idPrefix: "UC", limit: limit, ytdlp: ytdlp)
        return await resolveAll(urls) { await resolveArtist($0, ytdlp: ytdlp) }
    }

    static func searchPlaylists(_ query: String, limit: Int, ytdlp: String) async -> [MusicPlaylist] {
        // featured playlists carry the real "VL…" browse ids; albums/videos that
        // the section also returns are filtered out by the prefix.
        let urls = await flatHits(query, section: "featured_playlists", idPrefix: "VL", limit: limit, ytdlp: ytdlp)
        return await resolveAll(urls) { await resolvePlaylist($0, ytdlp: ytdlp) }
    }

    // best YT Music album for an "<artist> <title>" pair, for artist-page
    // discography playback — an album-level match instead of per-track searching.
    static func album(artist: String, title: String, ytdlp: String) async -> MusicAlbum? {
        let urls = await flatHits("\(artist) \(title)", section: "albums", idPrefix: "MPREb", limit: 1, ytdlp: ytdlp)
        guard let url = urls.first else { return nil }
        return await resolveAlbum(url, ytdlp: ytdlp)
    }

    // MARK: - flat search

    // run a filtered music search and return the browse URLs of matching hits.
    // a music search mixes types into one section, so keep only entries whose
    // browse id has the prefix we want (album/artist/playlist).
    private static func flatHits(_ query: String, section: String, idPrefix: String,
                                 limit: Int, ytdlp: String) async -> [String] {
        let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let url = "https://music.youtube.com/search?q=\(q)#\(section)"
        // over-fetch a little: filtering by id prefix drops some raw hits
        let data = try? await YTDLPService.runProcess(
            ["--flat-playlist", "--dump-json", "--no-warnings", "--ignore-errors",
             "--playlist-end", "\(limit * 2 + 2)", url],
            ytdlp: ytdlp)
        guard let data else { return [] }
        var out: [String] = []
        var seen = Set<String>()
        for line in data.split(separator: 0x0A) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let id = obj["id"] as? String, id.hasPrefix(idPrefix),
                  let u = obj["url"] as? String, u.contains("/browse/"),
                  seen.insert(id).inserted else { continue }
            out.append(u)
            if out.count == limit { break }
        }
        return out
    }

    // MARK: - resolve

    private static func resolveAlbum(_ url: String, ytdlp: String) async -> MusicAlbum? {
        guard let root = await dumpCollection(url, ytdlp: ytdlp) else { return nil }
        let entries = (root["entries"] as? [[String: Any]]) ?? []
        let tracks = parseTracks(entries, fallbackArtist: root["channel"] as? String)
        guard let first = tracks.first else { return nil }
        // in flat mode the album-level artist is absent; the tracks carry it.
        // (YT Music exposes no reliable release year here, so we omit it.)
        let artist = (root["channel"] as? String) ?? (root["uploader"] as? String) ?? first.artist
        return MusicAlbum(
            id: (root["id"] as? String) ?? url,
            title: stripKindPrefix((root["title"] as? String) ?? ""),
            artist: artist,
            year: yearString(root["release_year"]),
            coverURL: bestThumbnail(root),
            tracks: tracks)
    }

    private static func resolvePlaylist(_ url: String, ytdlp: String) async -> MusicPlaylist? {
        guard let root = await dumpCollection(url, ytdlp: ytdlp) else { return nil }
        let tracks = parseTracks((root["entries"] as? [[String: Any]]) ?? [], fallbackArtist: nil)
        guard !tracks.isEmpty else { return nil }
        return MusicPlaylist(
            id: (root["id"] as? String) ?? url,
            title: (root["title"] as? String) ?? "Playlist",
            coverURL: bestThumbnail(root) ?? tracks.first?.thumbnailURL,
            tracks: tracks)
    }

    private static func resolveArtist(_ url: String, ytdlp: String) async -> MusicArtist? {
        guard let root = await dumpCollection(url, ytdlp: ytdlp) else { return nil }
        // `channel` is the clean name ("Daft Punk"); `title` is the noisier
        // "Uploads from Daft Punk - Topic". drop auto-generated "… - Topic"
        // channels, which are tribute/upload buckets rather than real artists.
        guard let name = (root["channel"] as? String)?.trimmingCharacters(in: .whitespaces),
              !name.isEmpty, !name.hasSuffix("- Topic") else { return nil }
        return MusicArtist(
            id: (root["id"] as? String) ?? url,
            name: name,
            imageURL: bestThumbnail(root))
    }

    private static func dumpCollection(_ url: String, ytdlp: String) async -> [String: Any]? {
        guard let data = try? await YTDLPService.runProcess(
            ["--flat-playlist", "--dump-single-json", "--no-warnings", "--ignore-errors", url],
            ytdlp: ytdlp) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    // MARK: - parsing helpers

    private static func parseTracks(_ entries: [[String: Any]], fallbackArtist: String?) -> [Track] {
        var out: [Track] = []
        var seen = Set<String>()
        for obj in entries {
            guard let id = obj["id"] as? String, !id.isEmpty, seen.insert(id).inserted else { continue }
            let title = (obj["title"] as? String) ?? "Untitled"
            let channel = (obj["channel"] as? String) ?? (obj["uploader"] as? String) ?? fallbackArtist ?? ""
            let duration = (obj["duration"] as? Double) ?? (obj["duration"] as? NSNumber)?.doubleValue
            out.append(Track(id: id, title: title, channel: channel, duration: duration))
        }
        return out
    }

    // largest available thumbnail url (yt-dlp orders them ascending)
    private static func bestThumbnail(_ root: [String: Any]) -> URL? {
        guard let thumbs = root["thumbnails"] as? [[String: Any]] else { return nil }
        for t in thumbs.reversed() {
            if let s = t["url"] as? String, let u = URL(string: s) { return u }
        }
        return nil
    }

    private static func yearString(_ value: Any?) -> String? {
        if let i = value as? Int { return String(i) }
        if let n = value as? NSNumber { return n.stringValue }
        if let s = value as? String, !s.isEmpty { return s }
        return nil
    }

    // YT Music prefixes album titles with their type ("Album - Discovery")
    private static func stripKindPrefix(_ title: String) -> String {
        for prefix in ["Album - ", "Single - ", "EP - "] where title.hasPrefix(prefix) {
            return String(title.dropFirst(prefix.count))
        }
        return title
    }

    // run resolves with bounded concurrency, preserving input order
    private static func resolveAll<T>(_ urls: [String],
                                      _ resolve: @escaping (String) async -> T?) async -> [T] {
        await withTaskGroup(of: (Int, T?).self) { group in
            for (i, url) in urls.enumerated() {
                group.addTask {
                    await gate.wait()
                    let value = await resolve(url)
                    await gate.signal()
                    return (i, value)
                }
            }
            var buf = [T?](repeating: nil, count: urls.count)
            for await (i, value) in group { buf[i] = value }
            return buf.compactMap { $0 }
        }
    }
}

// a minimal async counting semaphore for bounding concurrent work
actor Semaphore {
    private var permits: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(_ permits: Int) { self.permits = permits }

    func wait() async {
        if permits > 0 { permits -= 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func signal() {
        if waiters.isEmpty { permits += 1 }
        else { waiters.removeFirst().resume() }
    }
}
