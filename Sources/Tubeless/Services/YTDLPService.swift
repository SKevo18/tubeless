import Foundation

enum YTError: LocalizedError {
    case ytdlpMissing(String)
    case processFailed(String)
    case noStream

    var errorDescription: String? {
        switch self {
        case .ytdlpMissing(let p): return "yt-dlp not found at \(p). Set the correct path in Settings."
        case .processFailed(let m): return "yt-dlp failed: \(m)"
        case .noStream: return "No playable audio stream was returned."
        }
    }
}

// wraps the yt-dlp binary. actor serializes process spawning.
actor YTDLPService {
    static let shared = YTDLPService()

    // search youtube and return lightweight metadata (no stream resolution).
    func search(_ query: String, limit: Int, preferSongs: Bool, ytdlp: String) async throws -> [Track] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        let data = try await run(
            ["--flat-playlist", "--dump-json", "--no-warnings",
             "--ignore-errors", "ytsearch\(limit):\(q)"],
            ytdlp: ytdlp)
        var tracks = parse(data)
        if preferSongs { tracks.sort { songScore($0) > songScore($1) } }
        return tracks
    }

    // best single match for a query (used to map Last.fm results onto YouTube).
    func firstResult(for query: String, ytdlp: String) async throws -> Track? {
        try await search(query, limit: 1, preferSongs: true, ytdlp: ytdlp).first
    }

    // resolve a direct, AVPlayer-compatible (m4a/AAC) audio URL for a video id.
    // itag 140 is the standard full-length 128k AAC track; preferring it avoids
    // partial/throttled DASH streams that cut out mid-song.
    func audioStreamURL(for id: String, ytdlp: String) async throws -> URL {
        let data = try await run(
            ["-f", "140/bestaudio[ext=m4a]/bestaudio[acodec^=mp4a]/bestaudio",
             "-g", "--no-warnings", "--no-playlist",
             "https://www.youtube.com/watch?v=\(id)"],
            ytdlp: ytdlp)
        let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let first = text.split(separator: "\n").first,
              let url = URL(string: String(first)) else { throw YTError.noStream }
        return url
    }

    // download a video's audio as MP3 at the given bitrate (needs ffmpeg). returns the file URL.
    func download(id: String, quality: String, to folder: URL, ytdlp: String) async throws -> URL {
        let template = folder.appendingPathComponent("%(title)s.%(ext)s").path
        let data = try await run(
            ["-x", "--audio-format", "mp3", "--audio-quality", "\(quality)K",
             "--no-playlist", "--no-warnings", "--add-metadata",
             "-o", template, "--print", "after_move:filepath",
             "https://www.youtube.com/watch?v=\(id)"],
            ytdlp: ytdlp)
        let path = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: "\n").last ?? ""
        guard !path.isEmpty else { throw YTError.processFailed("Download produced no file.") }
        return URL(fileURLWithPath: path)
    }

    // import a YouTube playlist URL → (title, tracks)
    func playlist(url: String, ytdlp: String) async throws -> (title: String, tracks: [Track]) {
        let data = try await run(
            ["--flat-playlist", "--dump-single-json", "--no-warnings", "--ignore-errors",
             url.trimmingCharacters(in: .whitespacesAndNewlines)],
            ytdlp: ytdlp)
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw YTError.processFailed("Could not read playlist.")
        }
        let title = (root["title"] as? String) ?? "Imported playlist"
        let entries = (root["entries"] as? [[String: Any]]) ?? []
        var tracks: [Track] = []
        var seen = Set<String>()
        for obj in entries {
            guard let id = obj["id"] as? String, !id.isEmpty, seen.insert(id).inserted else { continue }
            let t = (obj["title"] as? String) ?? "Untitled"
            let ch = (obj["channel"] as? String) ?? (obj["uploader"] as? String) ?? ""
            let dur = (obj["duration"] as? Double) ?? (obj["duration"] as? NSNumber)?.doubleValue
            tracks.append(Track(id: id, title: t, channel: ch, duration: dur))
        }
        return (title, tracks)
    }

    // youtube's auto-generated "radio" mix (RD<id>) = free recommendations.
    func radio(for id: String, limit: Int, ytdlp: String) async throws -> [Track] {
        let data = try await run(
            ["--flat-playlist", "--dump-json", "--no-warnings", "--ignore-errors",
             "--playlist-end", "\(limit + 1)",
             "https://www.youtube.com/watch?v=\(id)&list=RD\(id)"],
            ytdlp: ytdlp)
        return parse(data).filter { $0.id != id }
    }

    // MARK: - helpers

    private func parse(_ data: Data) -> [Track] {
        var out: [Track] = []
        var seen = Set<String>()
        for line in data.split(separator: 0x0A) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let id = obj["id"] as? String, !id.isEmpty, !seen.contains(id)
            else { continue }
            seen.insert(id)
            let title = (obj["title"] as? String) ?? "Untitled"
            let channel = (obj["channel"] as? String)
                ?? (obj["uploader"] as? String)
                ?? (obj["playlist_uploader"] as? String) ?? ""
            let duration = (obj["duration"] as? Double)
                ?? (obj["duration"] as? NSNumber)?.doubleValue
            out.append(Track(id: id, title: title, channel: channel, duration: duration))
        }
        return out
    }

    // rank "song" versions above music videos / live / lyric clips
    private func songScore(_ t: Track) -> Int {
        var s = 0
        let title = t.title.lowercased()
        if t.isTopic { s += 5 }
        if title.contains("audio") { s += 2 }
        if title.contains("official video") || title.contains("music video") { s -= 2 }
        if title.contains("live") { s -= 2 }
        if title.contains("lyric") { s -= 1 }
        if title.contains("cover") || title.contains("remix") { s -= 1 }
        return s
    }

    private func run(_ args: [String], ytdlp: String) async throws -> Data {
        guard FileManager.default.isExecutableFile(atPath: ytdlp) else {
            throw YTError.ytdlpMissing(ytdlp)
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ytdlp)
        proc.arguments = args
        let out = Pipe(), err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        try proc.run()
        // read fully before waiting to avoid pipe-buffer deadlock on large output
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        // yt-dlp returns nonzero with --ignore-errors yet still emits valid lines;
        // only fail hard when we got nothing usable back.
        if proc.terminationStatus != 0 && data.isEmpty {
            let msg = String(data: errData, encoding: .utf8) ?? "exit \(proc.terminationStatus)"
            throw YTError.processFailed(msg.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return data
    }
}
