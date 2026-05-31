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

    // songs *by* a specific artist: search wide, then keep only uploads on the
    // artist's own channel (usually the auto-generated "<artist> - Topic"), so a
    // bare name like "Marina" can't pull in unrelated title matches.
    func songs(by artist: String, limit: Int, preferSongs: Bool, ytdlp: String) async throws -> [Track] {
        let pool = try await search(artist, limit: max(limit * 3, 30), preferSongs: preferSongs, ytdlp: ytdlp)
        let key = Self.normalize(artist)
        guard !key.isEmpty else { return Array(pool.prefix(limit)) }
        let matched = pool.filter { t in
            let ch = Self.normalize(t.displayChannel)
            return !ch.isEmpty && (ch.contains(key) || key.contains(ch))
        }
        // fall back to the raw pool only if nothing matched (very obscure artists)
        return Array((matched.isEmpty ? pool : matched).prefix(limit))
    }

    // diacritic/punctuation-insensitive key for loose artist/channel comparison
    static func normalize(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
    }

    // resolve a direct, AVPlayer-compatible (m4a/AAC) audio URL for a video id.
    // itag 140 is the standard full-length 128k AAC track; preferring it avoids
    // partial/throttled DASH streams that cut out mid-song.
    //
    // the android_vr client returns itag 140 without any JS signature solving, so
    // it resolves in ~2s vs ~4s for yt-dlp's default client probing. fall back to
    // the default clients only if it fails (rare: age-gated/region-locked videos).
    func audioStreamURL(for id: String, ytdlp: String) async throws -> URL {
        do {
            return try await streamURL(for: id, ytdlp: ytdlp, client: "android_vr")
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return try await streamURL(for: id, ytdlp: ytdlp, client: nil)
        }
    }

    private func streamURL(for id: String, ytdlp: String, client: String?) async throws -> URL {
        var args = ["-f", "140/bestaudio[ext=m4a]/bestaudio[acodec^=mp4a]/bestaudio",
                    "-g", "--no-warnings", "--no-playlist"]
        if let client { args += ["--extractor-args", "youtube:player_client=\(client)"] }
        args.append("https://www.youtube.com/watch?v=\(id)")
        let data = try await run(args, ytdlp: ytdlp)
        let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let first = text.split(separator: "\n").first,
              let url = URL(string: String(first)) else { throw YTError.noStream }
        return url
    }

    // download a video's audio as MP3 at the given bitrate (needs ffmpeg). streams
    // download progress (0…1) via `onProgress`, is cancellable, and returns the
    // final file URL. `--newline` + a custom progress template make each update a
    // parseable "DLPROG|<percent>" line on stdout; `--print after_move` gives the
    // final path as "DONE|<path>".
    func download(id: String, quality: String, to folder: URL, ytdlp: String,
                  onProgress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        guard FileManager.default.isExecutableFile(atPath: ytdlp) else {
            throw YTError.ytdlpMissing(ytdlp)
        }
        try Task.checkCancellation()
        let template = folder.appendingPathComponent("%(title)s.%(ext)s").path
        // --print makes yt-dlp quiet; --progress forces the progress lines back on
        let args = ["-x", "--audio-format", "mp3", "--audio-quality", "\(quality)K",
                    "--no-playlist", "--no-warnings", "--add-metadata",
                    "--newline", "--progress",
                    "--progress-template", "download:DLPROG|%(progress._percent_str)s",
                    "--print", "after_move:DONE|%(filepath)s",
                    "-o", template,
                    "https://www.youtube.com/watch?v=\(id)"]
        let box = ProcessBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    let proc = Process()
                    proc.executableURL = URL(fileURLWithPath: ytdlp)
                    proc.arguments = args
                    let out = Pipe(), err = Pipe()
                    proc.standardOutput = out
                    proc.standardError = err
                    do { try box.start(proc) }
                    catch { cont.resume(throwing: error); return }
                    let handle = out.fileHandleForReading
                    var buffer = Data()
                    var resultPath: String?
                    // read stdout incrementally; availableData returns empty at EOF
                    while case let chunk = handle.availableData, !chunk.isEmpty {
                        buffer.append(chunk)
                        while let nl = buffer.firstIndex(of: 0x0A) {
                            let line = String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self)
                            buffer.removeSubrange(buffer.startIndex...nl)
                            if line.hasPrefix("DLPROG|") {
                                if let pct = Self.parsePercent(line) { onProgress(pct) }
                            } else if line.hasPrefix("DONE|") {
                                resultPath = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                            }
                        }
                    }
                    let errData = err.fileHandleForReading.readDataToEndOfFile()
                    proc.waitUntilExit()
                    if box.isCancelled {
                        cont.resume(throwing: CancellationError())
                    } else if let path = resultPath, !path.isEmpty {
                        cont.resume(returning: URL(fileURLWithPath: path))
                    } else {
                        let msg = String(data: errData, encoding: .utf8) ?? "exit \(proc.terminationStatus)"
                        cont.resume(throwing: YTError.processFailed(
                            msg.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? "Download produced no file." : msg.trimmingCharacters(in: .whitespacesAndNewlines)))
                    }
                }
            }
        } onCancel: {
            box.cancel()
        }
    }

    // "DLPROG|  4.9%" → 0.049
    private static func parsePercent(_ line: String) -> Double? {
        let parts = line.split(separator: "|")
        guard parts.count >= 2 else { return nil }
        let s = parts[1].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "%", with: "")
        guard let v = Double(s) else { return nil }
        return min(max(v / 100, 0), 1)
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
        try await Self.runProcess(args, ytdlp: ytdlp)
    }

    // every yt-dlp call funnels through here. it runs off the cooperative pool
    // (so resolves can fan out in parallel) and, crucially, terminates the child
    // process when the surrounding Task is cancelled — e.g. when the user starts
    // a new search or navigates away — instead of letting it run to completion.
    static func runProcess(_ args: [String], ytdlp: String) async throws -> Data {
        guard FileManager.default.isExecutableFile(atPath: ytdlp) else {
            throw YTError.ytdlpMissing(ytdlp)
        }
        try Task.checkCancellation()
        let box = ProcessBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    let proc = Process()
                    proc.executableURL = URL(fileURLWithPath: ytdlp)
                    proc.arguments = args
                    let out = Pipe(), err = Pipe()
                    proc.standardOutput = out
                    proc.standardError = err
                    // launches unless the task was already cancelled
                    do { try box.start(proc) }
                    catch { cont.resume(throwing: error); return }
                    // read fully before waiting to avoid pipe-buffer deadlock on large output
                    let data = out.fileHandleForReading.readDataToEndOfFile()
                    let errData = err.fileHandleForReading.readDataToEndOfFile()
                    proc.waitUntilExit()
                    if box.isCancelled {
                        // process was terminated mid-flight; report it as cancellation
                        cont.resume(throwing: CancellationError())
                    } else if proc.terminationStatus != 0 && data.isEmpty {
                        // yt-dlp returns nonzero with --ignore-errors yet still emits valid
                        // lines; only fail hard when we got nothing usable back.
                        let msg = String(data: errData, encoding: .utf8) ?? "exit \(proc.terminationStatus)"
                        cont.resume(throwing: YTError.processFailed(msg.trimmingCharacters(in: .whitespacesAndNewlines)))
                    } else {
                        cont.resume(returning: data)
                    }
                }
            }
        } onCancel: {
            box.cancel()
        }
    }
}

// guards the yt-dlp process so the cancellation handler can terminate it without
// racing the background launch: `start` and `cancel` are serialized, and a
// process is only signalled once it has actually launched.
private final class ProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var proc: Process?
    private var didCancel = false

    // launch the process unless the task was cancelled first (throws if so)
    func start(_ proc: Process) throws {
        lock.lock(); defer { lock.unlock() }
        if didCancel { throw CancellationError() }
        try proc.run()
        self.proc = proc
    }

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return didCancel
    }

    func cancel() {
        lock.lock()
        didCancel = true
        let launched = proc
        lock.unlock()
        launched?.terminate()
    }
}
