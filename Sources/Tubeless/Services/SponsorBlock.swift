import Foundation

struct SponsorSegment: Hashable {
    let start: Double
    let end: Double
    let category: String
}

enum SponsorBlock {
    // fetch skippable segments for a video. returns [] when none exist (API 404s).
    static func segments(videoID: String, categories: [String]) async throws -> [SponsorSegment] {
        guard !categories.isEmpty else { return [] }
        var comp = URLComponents(string: "https://sponsor.ajay.app/api/skipSegments")!
        comp.queryItems = [URLQueryItem(name: "videoID", value: videoID)]
            + categories.map { URLQueryItem(name: "category", value: $0) }
        guard let url = comp.url else { return [] }

        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        let (data, resp) = try await URLSession.shared.data(for: req)
        // 404 = "no segments for this video", which is normal, not an error
        if let http = resp as? HTTPURLResponse, http.statusCode == 404 { return [] }

        guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return arr.compactMap { obj in
            guard let seg = obj["segment"] as? [Double], seg.count == 2,
                  let cat = obj["category"] as? String else { return nil }
            return SponsorSegment(start: seg[0], end: seg[1], category: cat)
        }
        .sorted { $0.start < $1.start }
    }
}
