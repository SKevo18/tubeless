import Foundation

// a single playable item resolved from youtube
struct Track: Identifiable, Hashable, Codable {
    let id: String          // youtube video id
    var title: String
    var channel: String
    var duration: Double?    // seconds, may be nil from flat metadata

    var thumbnailURL: URL? {
        URL(string: "https://i.ytimg.com/vi/\(id)/mqdefault.jpg")
    }

    var watchURL: URL {
        URL(string: "https://www.youtube.com/watch?v=\(id)")!
    }

    // youtube auto-generated "song" uploads live on "<artist> - Topic" channels
    var isTopic: Bool { channel.hasSuffix("- Topic") }

    var displayChannel: String {
        guard isTopic else { return channel }
        return String(channel.dropLast(7)).trimmingCharacters(in: .whitespaces)
    }

    var artist: String { displayChannel }

    var durationText: String {
        guard let d = duration, d > 0 else { return "--:--" }
        let total = Int(d.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                     : String(format: "%d:%02d", m, s)
    }

    // strip "(Official Video)", "[Audio]", "feat. …" etc. for cleaner display / matching
    var cleanedTitle: String {
        var t = title
        let patterns = [#"\([^)]*\)"#, #"\[[^\]]*\]"#,
                        #"(?i)\s*-?\s*(official\s+)?(music\s+)?(video|audio|lyrics?|visualizer|hd|hq|mv)\b"#,
                        #"(?i)\s*ft\.?\s.*$"#, #"(?i)\s*feat\.?\s.*$"#]
        for p in patterns {
            t = t.replacingOccurrences(of: p, with: "", options: .regularExpression)
        }
        return t.trimmingCharacters(in: CharacterSet(charactersIn: " -–|"))
    }

    // best-effort (artist, title) split for Last.fm lookups
    var artistAndTitle: (artist: String, title: String) {
        let cleaned = cleanedTitle
        if !isTopic, let r = cleaned.range(of: " - ") {
            return (String(cleaned[..<r.lowerBound]).trimmingCharacters(in: .whitespaces),
                    String(cleaned[r.upperBound...]).trimmingCharacters(in: .whitespaces))
        }
        return (displayChannel, cleaned)
    }
}
