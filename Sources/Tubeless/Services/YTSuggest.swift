import Foundation

// free YouTube search autocomplete (no key). returns suggestion strings.
enum YTSuggest {
    static func fetch(_ query: String) async -> [String] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2 else { return [] }
        var comp = URLComponents(string: "https://suggestqueries.google.com/complete/search")!
        comp.queryItems = [
            .init(name: "client", value: "firefox"),
            .init(name: "ds", value: "yt"),
            .init(name: "q", value: q),
        ]
        guard let url = comp.url else { return [] }
        var req = URLRequest(url: url); req.timeoutInterval = 5
        guard let (data, _) = try? await URLSession.shared.data(for: req) else { return [] }
        // response shape: ["query", ["suggestion1", "suggestion2", ...]]
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [Any],
              root.count > 1, let list = root[1] as? [String] else { return [] }
        return Array(list.prefix(8))
    }
}
