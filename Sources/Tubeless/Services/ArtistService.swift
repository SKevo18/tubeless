import Foundation

// interpret ("artist") metadata aggregated from free, key-less sources. Identity
// is anchored to MusicBrainz (a music-only DB) so we never grab an unrelated
// Wikipedia page that merely shares the name; the bio/image come from the exact
// Wikipedia article MusicBrainz links to. Last.fm is layered in only with a key.
struct ArtistInfo {
    var name: String
    var bio: String?
    var imageURL: URL?
    var wikipediaURL: URL?
    var listeners: Int?

    // last.fm has a stable per-artist URL even without an API key
    var lastfmURL: URL? { ArtistService.lastfmURL(for: name) }
    var youtubeMusicURL: URL? {
        guard let q = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }
        return URL(string: "https://music.youtube.com/search?q=\(q)")
    }
}

// a MusicBrainz release-group (album / single / EP) for the discography sections
struct Release: Identifiable, Hashable {
    enum Kind: String { case album = "Album", single = "Single", ep = "EP" }
    let id: String              // musicbrainz release-group id
    let title: String
    let year: String?
    let kind: Kind

    // Cover Art Archive returns 404 when no art exists; Artwork shows a placeholder
    var coverURL: URL? { URL(string: "https://coverartarchive.org/release-group/\(id)/front-250") }
}

enum ArtistService {
    // identify this client to MusicBrainz/Wikipedia as their guidelines ask
    private static let userAgent = "Tubeless/1.0 ( https://github.com/SKevo18/tubeless-audio-mac )"

    static func lastfmURL(for name: String) -> URL? {
        guard let slug = name.replacingOccurrences(of: " ", with: "+")
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        return URL(string: "https://www.last.fm/music/\(slug)")
    }

    // full profile in one pass: resolve the MusicBrainz artist, follow its
    // Wikipedia link for the bio/image, and list its release-groups.
    static func profile(for name: String, lastfmKey: String) async -> (info: ArtistInfo, releases: [Release]) {
        var info = ArtistInfo(name: name)
        let mb = await musicBrainzArtist(for: name)

        // resolve the exact Wikipedia article this artist links to (direct
        // relation, else via Wikidata), then read that page — never a name match.
        var wikiTitle = mb?.wikipediaTitle
        if wikiTitle == nil, let wd = mb?.wikidataID { wikiTitle = await wikidataEnwikiTitle(wd) }
        if let title = wikiTitle, let wiki = await wikipediaSummary(title) {
            info.bio = wiki["extract"] as? String
            info.imageURL = ((wiki["thumbnail"] as? [String: Any])?["source"] as? String).flatMap(URL.init)
            info.wikipediaURL = (((wiki["content_urls"] as? [String: Any])?["desktop"]
                                  as? [String: Any])?["page"] as? String).flatMap(URL.init)
        }

        if !lastfmKey.isEmpty, let lfm = await lastfm(for: name, apiKey: lastfmKey) {
            info.listeners = lfm.listeners
            if (info.bio ?? "").isEmpty { info.bio = lfm.bio }
        }

        let releases = mb != nil ? await releaseGroups(artistID: mb!.id) : []
        return (info, releases)
    }

    // MARK: - MusicBrainz

    private struct MBArtist { let id: String; let wikidataID: String?; let wikipediaTitle: String? }

    // search for the artist, then look it up with URL relations to find its
    // Wikipedia / Wikidata links
    private static func musicBrainzArtist(for name: String) async -> MBArtist? {
        var search = URLComponents(string: "https://musicbrainz.org/ws/2/artist")!
        search.queryItems = [
            .init(name: "query", value: "artist:\"\(name)\""),
            .init(name: "fmt", value: "json"),
            .init(name: "limit", value: "1"),
        ]
        guard let url = search.url, let data = await get(url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = (root["artists"] as? [[String: Any]])?.first?["id"] as? String else { return nil }

        var wikidataID: String?
        var wikipediaTitle: String?
        if let relData = await get(URL(string:
            "https://musicbrainz.org/ws/2/artist/\(id)?inc=url-rels&fmt=json")!),
           let relRoot = try? JSONSerialization.jsonObject(with: relData) as? [String: Any],
           let relations = relRoot["relations"] as? [[String: Any]] {
            for rel in relations {
                let type = rel["type"] as? String
                guard let resource = (rel["url"] as? [String: Any])?["resource"] as? String else { continue }
                if type == "wikidata", let q = resource.split(separator: "/").last { wikidataID = String(q) }
                if type == "wikipedia" { wikipediaTitle = pageTitle(fromWikipediaURL: resource) }
            }
        }
        return MBArtist(id: id, wikidataID: wikidataID, wikipediaTitle: wikipediaTitle)
    }

    private static func releaseGroups(artistID: String) async -> [Release] {
        var comp = URLComponents(string: "https://musicbrainz.org/ws/2/release-group")!
        comp.queryItems = [
            .init(name: "artist", value: artistID),
            .init(name: "fmt", value: "json"),
            .init(name: "limit", value: "100"),
        ]
        guard let url = comp.url, let data = await get(url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let groups = root["release-groups"] as? [[String: Any]] else { return [] }

        var out: [Release] = []
        var seen = Set<String>()
        for g in groups {
            guard let id = g["id"] as? String, let title = g["title"] as? String else { continue }
            // skip compilations / live / remix collections to keep the list focused
            let secondary = (g["secondary-types"] as? [String]) ?? []
            if !secondary.isEmpty { continue }
            let kind: Release.Kind
            switch (g["primary-type"] as? String) {
            case "Album": kind = .album
            case "Single": kind = .single
            case "EP": kind = .ep
            default: continue
            }
            let dedupe = "\(kind.rawValue)|\(title.lowercased())"
            guard seen.insert(dedupe).inserted else { continue }
            let year = (g["first-release-date"] as? String)?.prefix(4)
            out.append(Release(id: id, title: title, year: year.map(String.init), kind: kind))
        }
        // newest first, undated last
        return out.sorted { ($0.year ?? "0") > ($1.year ?? "0") }
    }

    // ordered track titles of a release-group's first release, for playback.
    // one request (browse release with inc=recordings).
    static func tracklist(releaseGroupID id: String) async -> [String] {
        var comp = URLComponents(string: "https://musicbrainz.org/ws/2/release")!
        comp.queryItems = [
            .init(name: "release-group", value: id),
            .init(name: "inc", value: "recordings"),
            .init(name: "fmt", value: "json"),
            .init(name: "limit", value: "1"),
        ]
        guard let url = comp.url, let data = await get(url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let media = (root["releases"] as? [[String: Any]])?.first?["media"] as? [[String: Any]] else { return [] }
        var titles: [String] = []
        for m in media {
            for track in (m["tracks"] as? [[String: Any]]) ?? [] {
                if let title = track["title"] as? String, !title.isEmpty { titles.append(title) }
            }
        }
        return titles
    }

    // MARK: - Wikidata → Wikipedia

    // most MusicBrainz artists link only to Wikidata now; resolve its English
    // Wikipedia sitelink title
    private static func wikidataEnwikiTitle(_ qid: String) async -> String? {
        let url = URL(string: "https://www.wikidata.org/w/api.php?action=wbgetentities&ids=\(qid)"
                      + "&props=sitelinks&sitefilter=enwiki&format=json")!
        guard let data = await get(url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entity = (root["entities"] as? [String: Any])?[qid] as? [String: Any],
              let sitelinks = entity["sitelinks"] as? [String: Any] else { return nil }
        return (sitelinks["enwiki"] as? [String: Any])?["title"] as? String
    }

    // pull the page title out of an en.wikipedia.org/wiki/<Title> URL
    private static func pageTitle(fromWikipediaURL urlString: String) -> String? {
        guard let url = URL(string: urlString), url.host?.contains("en.wikipedia.org") == true,
              let last = url.pathComponents.last else { return nil }
        return last.removingPercentEncoding?.replacingOccurrences(of: "_", with: " ")
    }

    private static func wikipediaSummary(_ title: String) async -> [String: Any]? {
        let path = title.replacingOccurrences(of: " ", with: "_")
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? title
        guard let url = URL(string: "https://en.wikipedia.org/api/rest_v1/page/summary/\(path)?redirect=true"),
              let data = await get(url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return root
    }

    // MARK: - Last.fm

    private struct LFM { let bio: String?; let listeners: Int? }

    private static func lastfm(for name: String, apiKey: String) async -> LFM? {
        var comp = URLComponents(string: "https://ws.audioscrobbler.com/2.0/")!
        comp.queryItems = [
            .init(name: "method", value: "artist.getinfo"),
            .init(name: "artist", value: name),
            .init(name: "api_key", value: apiKey),
            .init(name: "format", value: "json"),
            .init(name: "autocorrect", value: "1"),
        ]
        guard let url = comp.url, let data = await get(url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let artist = root["artist"] as? [String: Any] else { return nil }
        var bio = (artist["bio"] as? [String: Any])?["summary"] as? String
        bio = bio.map(stripHTML)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let listeners = ((artist["stats"] as? [String: Any])?["listeners"] as? String).flatMap { Int($0) }
        return LFM(bio: (bio?.isEmpty == true) ? nil : bio, listeners: listeners)
    }

    // MARK: - helpers

    private static func get(_ url: URL) async -> Data? {
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true
        else { return nil }
        return data
    }

    private static func stripHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
    }
}
