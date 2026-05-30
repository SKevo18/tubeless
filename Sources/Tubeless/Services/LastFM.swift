import Foundation

// thin Last.fm client for similarity-based recommendations (optional, needs API key)
enum LastFM {
    struct SimilarTrack { let artist: String; let title: String }

    static func similar(artist: String, track: String, apiKey: String, limit: Int) async -> [SimilarTrack] {
        guard !apiKey.isEmpty else { return [] }
        var comp = URLComponents(string: "https://ws.audioscrobbler.com/2.0/")!
        comp.queryItems = [
            .init(name: "method", value: "track.getsimilar"),
            .init(name: "artist", value: artist),
            .init(name: "track", value: track),
            .init(name: "api_key", value: apiKey),
            .init(name: "format", value: "json"),
            .init(name: "limit", value: "\(limit)"),
            .init(name: "autocorrect", value: "1"),
        ]
        guard let url = comp.url else { return [] }
        var req = URLRequest(url: url); req.timeoutInterval = 8
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let wrap = root["similartracks"] as? [String: Any] else { return [] }

        let raw = (wrap["track"] as? [[String: Any]]) ?? []
        return raw.compactMap { obj in
            guard let name = obj["name"] as? String else { return nil }
            let art = (obj["artist"] as? [String: Any])?["name"] as? String ?? artist
            return SimilarTrack(artist: art, title: name)
        }
    }
}
