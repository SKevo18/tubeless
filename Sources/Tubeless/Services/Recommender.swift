import Foundation

// produces "radio" (one track), "discovery" (history) and queue-based
// recommendations. uses Last.fm when a key is set, else YouTube's radio mix.
enum Recommender {
    // similar songs for the expanded-player "Related" panel (single seed)
    static func related(to track: Track, limit: Int) async -> [Track] {
        let s = await snapshot()
        if !s.lastfmKey.isEmpty {
            let (artist, title) = track.artistAndTitle
            let sims = await LastFM.similar(artist: artist, track: title, apiKey: s.lastfmKey, limit: limit)
            let mapped = await resolve(sims.map { ($0, 1.0) }, ytdlp: s.ytdlp, exclude: [track.id], limit: limit)
            if !mapped.isEmpty { return mapped }
        }
        // youtube's mix is most-similar-first, so its head is dominated by the seed's
        // own artist. pull a wide slice and spread it across artists for real variety.
        let pool = (try? await YTDLPService.shared.radio(for: track.id, limit: poolSize(for: limit), ytdlp: s.ytdlp)) ?? []
        return diversify(pool, limit: limit)
    }

    // home Discovery, seeded from the user's most-engaged songs
    static func discovery(seeds: [Track], limit: Int) async -> [Track] {
        await recommend(seeds: seeds, limit: limit)
    }

    // aggregate recommendations across several seeds, ranked by how often each
    // candidate is suggested across them (so queue-wide taste wins out)
    static func recommend(seeds: [Track], limit: Int) async -> [Track] {
        guard let first = seeds.first else { return [] }
        let s = await snapshot()
        let exclude = Set(seeds.map(\.id))

        if !s.lastfmKey.isEmpty {
            // tally "artist - title" candidates weighted by seed order (earlier = stronger)
            var weights: [String: (sim: LastFM.SimilarTrack, w: Double)] = [:]
            for (i, seed) in seeds.prefix(6).enumerated() {
                let (artist, title) = seed.artistAndTitle
                let sims = await LastFM.similar(artist: artist, track: title, apiKey: s.lastfmKey, limit: 10)
                let seedWeight = 1.0 / Double(i + 1)
                for sim in sims {
                    let key = (sim.artist + " - " + sim.title).lowercased()
                    if seeds.contains(where: { $0.artistAndTitle.title.caseInsensitiveCompare(sim.title) == .orderedSame }) { continue }
                    weights[key, default: (sim, 0)].w += seedWeight
                }
            }
            let ranked = weights.values.sorted { $0.w > $1.w }.map { ($0.sim, $0.w) }
            let mapped = await resolve(ranked, ytdlp: s.ytdlp, exclude: exclude, limit: limit)
            if !mapped.isEmpty { return mapped }
        }

        // fallback: merge wide YouTube radio mixes from the first couple of seeds
        var out: [Track] = []; var seen = exclude
        for seed in seeds.prefix(3) {
            let radio = (try? await YTDLPService.shared.radio(for: seed.id, limit: poolSize(for: limit), ytdlp: s.ytdlp)) ?? []
            for t in radio where seen.insert(t.id).inserted { out.append(t) }
        }
        if out.isEmpty {
            out = (try? await YTDLPService.shared.radio(for: first.id, limit: poolSize(for: limit), ytdlp: s.ytdlp)) ?? []
        }
        return diversify(out, limit: limit)
    }

    // MARK: - helpers

    // how many mix entries to pull before diversifying — wide enough to get past
    // the same-artist head of the mix, capped so the fetch stays cheap.
    private static func poolSize(for limit: Int) -> Int { min(max(limit * 4, 40), 80) }

    // round-robin across artists so one interpret can't dominate; preserves the
    // mix's relative ordering within each artist.
    private static func diversify(_ tracks: [Track], limit: Int) -> [Track] {
        var byArtist: [String: [Track]] = [:]
        var order: [String] = []
        for t in tracks {
            let key = t.artist.lowercased()
            if byArtist[key] == nil { order.append(key) }
            byArtist[key, default: []].append(t)
        }
        var out: [Track] = []
        var round = 0
        while out.count < limit {
            var advanced = false
            for key in order {
                guard let group = byArtist[key], round < group.count else { continue }
                out.append(group[round])
                advanced = true
                if out.count >= limit { break }
            }
            if !advanced { break }
            round += 1
        }
        return out
    }

    private struct Cfg { let lastfmKey: String; let ytdlp: String }

    @MainActor private static func snapshot() -> Cfg {
        Cfg(lastfmKey: AppSettings.shared.lastfmApiKey, ytdlp: AppSettings.shared.ytdlpPath)
    }

    // map ranked "artist - title" candidates to real YouTube tracks
    private static func resolve(_ candidates: [(LastFM.SimilarTrack, Double)],
                                ytdlp: String, exclude: Set<String>, limit: Int) async -> [Track] {
        var out: [Track] = []
        for (sim, _) in candidates.prefix(limit + 6) {
            if let t = try? await YTDLPService.shared.firstResult(for: "\(sim.artist) \(sim.title)", ytdlp: ytdlp),
               !exclude.contains(t.id), !out.contains(where: { $0.id == t.id }) {
                out.append(t)
            }
            if out.count >= limit { break }
        }
        return out
    }
}
