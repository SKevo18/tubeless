import AVFoundation
import Combine
import SwiftUI

enum RepeatMode: Int { case off, queue, song }

@MainActor
final class AudioPlayer: ObservableObject {
    // queue is a stable snapshot; currentIndex is a moving pointer (YouTube-Music style).
    @Published var queue: [Track] = [] { didSet { maintainCache() } }
    @Published private(set) var currentIndex: Int = -1
    @Published var autoplay: [Track] = [] { didSet { maintainCache() } }
    @Published var repeatMode: RepeatMode = .off

    @Published private(set) var isPlaying = false
    @Published private(set) var isLoading = false
    @Published private(set) var isBuildingRadio = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var segments: [SponsorSegment] = []
    @Published private(set) var skippedSegment: String?
    @Published var lastError: String?
    @Published private(set) var loadingQueue = 0    // album tracks still resolving into the queue

    @Published var volume: Double = AppSettings.shared.volume {
        didSet { applyVolumes(); AppSettings.shared.volume = volume }
    }

    var currentTrack: Track? { queue.indices.contains(currentIndex) ? queue[currentIndex] : nil }
    var hasNext: Bool {
        currentIndex + 1 < queue.count || !autoplay.isEmpty || (repeatMode == .queue && !queue.isEmpty)
    }

    private final class Stream {
        let track: Track
        let player = AVPlayer()
        let item: AVPlayerItem
        var segments: [SponsorSegment] = []
        var endObs: NSObjectProtocol?
        var envelope: Double = 1
        private var from = 1.0, to = 1.0, start = 0.0, dur = 0.0

        init(track: Track, url: URL, bufferSeconds: Double) {
            self.track = track
            item = AVPlayerItem(url: url)
            item.preferredForwardBufferDuration = bufferSeconds
            player.automaticallyWaitsToMinimizeStalling = true
            player.replaceCurrentItem(with: item)
        }
        func beginFade(to target: Double, duration: Double, now: Double) {
            from = envelope; to = target; start = now; dur = max(duration, 0.0001)
        }
        func step(now: Double) -> Bool {
            guard dur > 0 else { envelope = to; return false }
            let t = (now - start) / dur
            if t >= 1 { envelope = to; dur = 0; return false }
            envelope = from + (to - from) * max(0, t)
            return true
        }
    }

    private enum LoadFailure { case unreachable, network, other }

    private var current: Stream?
    private var fadingOut: [Stream] = []
    private var cache: [String: Stream] = [:]      // buffered streams around the pointer (prev + next)
    private var timeObserver: Any?
    private var observedPlayer: AVPlayer?
    private var fadeTimer: Timer?
    private var loadTask: Task<Void, Never>?
    private var autoplayTask: Task<Void, Never>?
    private var radioTask: Task<Void, Never>?
    private var fillTask: Task<Void, Never>?
    private var cacheTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?

    private var endGuardFired = false
    private var autoSkipCount = 0
    private var retryCount = 0

    private var listenTrack: Track?
    private var listenAccum: Double = 0
    private var listenStart: Date?

    private var lastSessionSave = Date.distantPast
    private struct SessionState: Codable {
        var queue: [Track]; var currentIndex: Int; var currentTime: Double; var wasPlaying: Bool
    }
    private let sessionURL: URL = {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tubeless", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("session.json")
    }()

    private var settings: AppSettings { .shared }
    private var library: LibraryStore { .shared }
    private var now: Double { Date().timeIntervalSinceReferenceDate }

    init() {
        applyVolumes()
        NowPlayingCenter.shared.configure(.init(
            play: { [weak self] in self?.resume() },
            pause: { [weak self] in self?.pause() },
            toggle: { [weak self] in self?.togglePlayPause() },
            next: { [weak self] in self?.next() },
            previous: { [weak self] in self?.previous() },
            seek: { [weak self] s in self?.seek(to: s) }
        ))
        restoreSession()
    }

    // MARK: - session persistence (resume last song on next launch)

    func restoreSession() {
        guard queue.isEmpty,
              let data = try? Data(contentsOf: sessionURL),
              let s = try? JSONDecoder().decode(SessionState.self, from: data),
              !s.queue.isEmpty, s.queue.indices.contains(s.currentIndex) else { return }
        queue = s.queue
        currentIndex = s.currentIndex
        // resume the song at its last position, matching whether it was playing or paused
        startStream(autoPlay: s.wasPlaying, startAt: s.currentTime, record: false)
    }

    private func saveSession() {
        lastSessionSave = Date()
        guard !queue.isEmpty, currentIndex >= 0 else { return }
        let state = SessionState(queue: queue, currentIndex: currentIndex,
                                 currentTime: currentTime, wasPlaying: isPlaying)
        if let data = try? JSONEncoder().encode(state) { try? data.write(to: sessionURL, options: .atomic) }
    }

    // MARK: - starting playback

    func play(_ track: Track, replacingQueueWith context: [Track]? = nil) {
        cancelQueueFill()
        if let context, let idx = context.firstIndex(of: track) {
            queue = context
            currentIndex = idx
            autoplay = []
        } else if let idx = queue.firstIndex(of: track) {
            currentIndex = idx
        } else {
            queue.append(track)
            currentIndex = queue.count - 1
        }
        startStream()
    }

    // resolve a list of "<artist> <title>" queries to YouTube in the background
    // and append them to the queue as they come in (album/single playback). the
    // first track is expected to be playing already; this fills the rest.
    func fillQueue(resolving queries: [String], ytdlp: String) {
        fillTask?.cancel()
        guard !queries.isEmpty else { loadingQueue = 0; return }
        loadingQueue = queries.count
        fillTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for q in queries {
                if Task.isCancelled { return }
                if let t = try? await YTDLPService.shared.firstResult(for: q, ytdlp: ytdlp) {
                    if Task.isCancelled { return }
                    self.enqueue(t)
                }
                self.loadingQueue = max(0, self.loadingQueue - 1)
            }
            self.loadingQueue = 0
        }
    }

    private func cancelQueueFill() {
        fillTask?.cancel()
        loadingQueue = 0
    }

    func playQueueItem(_ track: Track) {
        guard let idx = queue.firstIndex(of: track) else { return }
        currentIndex = idx
        startStream()
    }

    func playAutoplayItem(_ track: Track) {
        autoplay.removeAll { $0.id == track.id }
        let insertAt = min(currentIndex + 1, queue.count)
        queue.insert(track, at: insertAt)
        currentIndex = insertAt
        startStream()
    }

    // MARK: - transport

    func togglePlayPause() { isPlaying ? pause() : resume() }

    func resume() {
        guard let current, !isPlaying else { return }
        current.player.play(); isPlaying = true; listenResume(); publishNowPlaying(); saveSession()
    }

    func pause() {
        guard isPlaying else { return }
        current?.player.pause(); isPlaying = false; listenPause(); publishNowPlaying(); saveSession()
    }

    func next() {
        if repeatMode == .song { seek(to: 0); resume(); return }
        retryTask?.cancel()
        if currentIndex + 1 < queue.count { currentIndex += 1; startStream(); return }
        if !autoplay.isEmpty {
            withAnimation { queue.append(autoplay.removeFirst()); currentIndex += 1 }
            startStream(); return
        }
        if repeatMode == .queue && !queue.isEmpty { currentIndex = 0; startStream(); return }
        pause()
    }

    func previous() {
        if currentTime > 3 || currentIndex <= 0 { seek(to: 0); return }
        currentIndex -= 1; startStream()
    }

    func seek(to seconds: Double) {
        current?.player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
        currentTime = seconds
        if let meta = currentTrack?.duration, meta > 0, seconds < meta - 0.5 { endGuardFired = false }
        publishNowPlaying()
    }

    func retryCurrent() { lastError = nil; retryCount = 0; startStream() }

    // MARK: - queue editing

    func enqueue(_ track: Track) {
        guard !queue.contains(track) else { return }
        queue.append(track)
    }

    func playNext(_ track: Track) {
        guard track.id != currentTrack?.id else { return }   // already playing — no-op
        if let i = queue.firstIndex(of: track) {
            queue.remove(at: i)
            if i <= currentIndex { currentIndex -= 1 }        // keep the pointer on the playing song
        }
        queue.insert(track, at: min(currentIndex + 1, queue.count))
    }

    func removeFromQueue(at offsets: IndexSet) {
        let removingCurrent = offsets.contains(currentIndex)
        let before = offsets.filter { $0 < currentIndex }.count
        queue.remove(atOffsets: offsets)
        currentIndex -= before
        if removingCurrent { currentIndex = min(currentIndex, queue.count - 1); startStream() }
    }

    // drag-reorder a single row; keeps the pointer on whatever is playing
    func reorderQueue(from: Int, to: Int) {
        guard queue.indices.contains(from), queue.indices.contains(to), from != to else { return }
        let id = currentTrack?.id
        let t = queue.remove(at: from)
        queue.insert(t, at: to)
        if let id, let idx = queue.firstIndex(where: { $0.id == id }) { currentIndex = idx }
    }

    func shuffleUpcoming() {
        guard currentIndex + 1 < queue.count else { return }
        let head = Array(queue[...currentIndex])
        let tail = Array(queue[(currentIndex + 1)...]).shuffled()
        withAnimation(.easeInOut(duration: 0.45)) { queue = head + tail }
    }

    func cycleRepeat() {
        repeatMode = RepeatMode(rawValue: (repeatMode.rawValue + 1) % 3) ?? .off
    }

    // rebuild the queue as a radio around a seed (defaults to the current song)
    func startRadio(from seedTrack: Track? = nil) {
        guard let seed = seedTrack ?? currentTrack, !isBuildingRadio else { return }
        let wasCurrent = seed.id == currentTrack?.id
        cancelQueueFill()
        isBuildingRadio = true
        radioTask?.cancel()
        let count = settings.recommendationRefreshCount
        radioTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let recs = await Recommender.related(to: seed, limit: count)
            self.isBuildingRadio = false
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.5)) {
                self.queue = [seed] + recs.filter { $0.id != seed.id }
                self.currentIndex = 0
                self.autoplay = []
            }
            if !wasCurrent { self.startStream() }   // seed wasn't playing → start it
            self.refreshAutoplay()
        }
    }

    // MARK: - stream lifecycle

    private func startStream(autoPlay: Bool = true, startAt: Double = 0, record: Bool = true) {
        commitListen()
        loadTask?.cancel(); retryTask?.cancel()
        guard let track = currentTrack else { return }
        currentTime = startAt
        duration = track.duration ?? 0
        segments = []
        lastError = nil
        endGuardFired = false
        if record { library.recordPlayed(track) }
        beginListen(track)

        retire(current); current = nil

        if let cached = cache.removeValue(forKey: track.id) {
            segments = cached.segments
            promote(cached, autoPlay: autoPlay, startAt: startAt)
            isLoading = false
            finishStart(track)
            return
        }

        isLoading = true
        loadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let (url, segs) = try await self.resolve(track)
                if Task.isCancelled || self.currentTrack?.id != track.id { return }
                let s = Stream(track: track, url: url, bufferSeconds: self.settings.prebufferSeconds)
                s.segments = segs
                self.segments = segs
                self.promote(s, autoPlay: autoPlay, startAt: startAt)
                self.isLoading = false
                self.autoSkipCount = 0; self.retryCount = 0
                self.finishStart(track)
            } catch {
                if Task.isCancelled { return }
                self.handleLoadFailure(error, for: track)
            }
        }
    }

    private func handleLoadFailure(_ error: Error, for track: Track) {
        isLoading = false; isPlaying = false
        lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        switch classify(error) {
        case .unreachable, .other:
            guard settings.autoSkipUnreachable, hasNext, autoSkipCount < 6 else { return }
            autoSkipCount += 1
            flash("Skipped — unavailable")
            next()
        case .network:
            guard settings.autoRetry, retryCount < 4 else { return }
            retryCount += 1
            lastError = "No connection — retrying (\(retryCount)/4)…"
            retryTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard let self, !Task.isCancelled, self.currentTrack?.id == track.id else { return }
                self.startStream()
            }
        }
    }

    private func classify(_ error: Error) -> LoadFailure {
        if error is URLError { return .network }
        let m = ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription).lowercased()
        let net = ["unable to download", "resolve host", "getaddrinfo", "network is unreachable",
                   "temporary failure", "timed out", "connection refused", "no address"]
        if net.contains(where: m.contains) { return .network }
        let unreachable = ["unavailable", "private video", "removed", "has been disabled", "not available",
                           "blocked", "sign in to confirm", "members-only", "this video", "no longer"]
        if unreachable.contains(where: m.contains) { return .unreachable }
        return .other
    }

    private func promote(_ s: Stream, autoPlay: Bool = true, startAt: Double = 0) {
        current = s
        s.player.isMuted = false
        attachTimeObserver(to: s.player)
        attachEndObserver(s)
        s.player.seek(to: CMTime(seconds: max(startAt, 0), preferredTimescale: 600))
        if autoPlay && settings.fadeEnabled {
            s.envelope = 0
            s.beginFade(to: 1, duration: settings.fadeInSeconds, now: now)
            startFadeTimer()
        } else {
            s.envelope = 1
        }
        applyVolumes()
        if autoPlay {
            s.player.play(); isPlaying = true; listenResume()
        } else {
            isPlaying = false
        }
        observeDuration(of: s)
    }

    private func retire(_ s: Stream?) {
        guard let s else { return }
        if observedPlayer === s.player, let timeObserver {
            s.player.removeTimeObserver(timeObserver); self.timeObserver = nil; observedPlayer = nil
        }
        if let o = s.endObs { NotificationCenter.default.removeObserver(o); s.endObs = nil }
        if settings.fadeEnabled {
            s.beginFade(to: 0, duration: settings.fadeOutSeconds, now: now)
            fadingOut.append(s); startFadeTimer()
        } else {
            stash(s)
        }
    }

    // keep a played/used stream around (paused, buffered) so we can return to it instantly
    private func stash(_ s: Stream) {
        s.player.pause(); s.player.isMuted = true; s.player.seek(to: .zero); s.envelope = 1
        cache[s.track.id] = s
    }

    private func finishStart(_ track: Track) {
        publishNowPlaying()
        refreshAutoplay()
        maintainCache()
        saveSession()
    }

    private func resolve(_ track: Track) async throws -> (URL, [SponsorSegment]) {
        async let urlReq = YTDLPService.shared.audioStreamURL(for: track.id, ytdlp: settings.ytdlpPath)
        async let segReq = SponsorBlock.segments(videoID: track.id, categories: settings.sponsorBlockCategories)
        let url = try await urlReq
        let segs = (try? await segReq) ?? []
        return (url, segs)
    }

    // MARK: - autoplay

    private func refreshAutoplay() {
        guard settings.autoQueueRecommendations, autoplay.isEmpty, let cur = currentTrack else { return }
        autoplayTask?.cancel()
        let count = settings.recommendationRefreshCount
        autoplayTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let recs = await Recommender.related(to: cur, limit: count)
            guard !Task.isCancelled, self.currentTrack?.id == cur.id else { return }
            let inQueue = Set(self.queue.map(\.id))
            self.autoplay = recs.filter { !inQueue.contains($0.id) }
        }
    }

    // MARK: - caching (prev + next window)

    private func maintainCache() {
        let n = max(0, settings.prebufferCount)
        var window: [Track] = []
        // currentIndex can transiently exceed the queue (e.g. queue reassigned
        // before currentIndex during a radio rebuild) — clamp so lo <= hi always
        if currentIndex >= 0 && !queue.isEmpty {
            let idx = min(currentIndex, queue.count - 1)
            let lo = max(0, idx - n)
            let hi = min(queue.count - 1, idx + n)
            window += Array(queue[lo...hi])
        }
        window += Array(autoplay.prefix(n))
        let curID = currentTrack?.id
        let windowIDs = Set(window.map(\.id))
        for (id, s) in cache where !windowIDs.contains(id) || id == curID {
            s.player.pause(); cache[id] = nil
        }
        let targets = window.filter { $0.id != curID && cache[$0.id] == nil }
        guard !targets.isEmpty else { return }
        cacheTask?.cancel()
        cacheTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for t in targets {
                if Task.isCancelled { return }
                if self.cache[t.id] != nil || t.id == self.currentTrack?.id { continue }
                guard let (url, segs) = try? await self.resolve(t) else { continue }
                if Task.isCancelled { return }
                let s = Stream(track: t, url: url, bufferSeconds: self.settings.prebufferSeconds)
                s.player.isMuted = true
                s.segments = segs
                self.cache[t.id] = s
            }
        }
    }

    // MARK: - fades

    private func startFadeTimer() {
        guard fadeTimer == nil else { return }
        fadeTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.stepFades() }
        }
    }

    private func stepFades() {
        let t = now
        var animating = false
        if let c = current, c.step(now: t) { animating = true }
        for s in fadingOut where s.step(now: t) { animating = true }
        applyVolumes()
        fadingOut.removeAll { s in
            if s.envelope <= 0.001 { stash(s); return true }
            return false
        }
        if !animating && fadingOut.isEmpty { fadeTimer?.invalidate(); fadeTimer = nil }
    }

    private func applyVolumes() {
        if let c = current { c.player.volume = Float(volume * c.envelope) }
        for s in fadingOut { s.player.volume = Float(volume * s.envelope) }
    }

    // MARK: - observers

    private func attachTimeObserver(to player: AVPlayer) {
        if let timeObserver, let observedPlayer { observedPlayer.removeTimeObserver(timeObserver) }
        observedPlayer = player
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            let s = time.seconds
            Task { @MainActor in self?.tick(s) }
        }
    }

    private func tick(_ seconds: Double) {
        guard seconds.isFinite else { return }
        currentTime = seconds
        if isPlaying, Date().timeIntervalSince(lastSessionSave) > 4 { saveSession() }
        if let meta = currentTrack?.duration, meta > 0, !endGuardFired, seconds >= meta - 0.3 {
            endGuardFired = true
            next()
            return
        }
        for seg in segments where seconds >= seg.start && seconds < seg.end - 0.2 {
            current?.player.seek(to: CMTime(seconds: seg.end, preferredTimescale: 600))
            flash("Skipped " + seg.category.replacingOccurrences(of: "_", with: " "))
            break
        }
    }

    private func attachEndObserver(_ s: Stream) {
        let track = s.track
        s.endObs = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: s.item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.currentTrack?.id == track.id else { return }
                self.next()
            }
        }
    }

    private func observeDuration(of s: Stream) {
        guard s.track.duration == nil else { return }
        Task { @MainActor [weak self] in
            let d = try? await s.item.asset.load(.duration)
            guard let self, let d, d.seconds.isFinite, d.seconds > 0,
                  self.current?.player === s.player else { return }
            self.duration = d.seconds
            self.publishNowPlaying()
        }
    }

    private func flash(_ message: String) {
        skippedSegment = message
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_900_000_000)
            if self?.skippedSegment == message { self?.skippedSegment = nil }
        }
    }

    // MARK: - listen scoring

    private func beginListen(_ track: Track) { listenTrack = track; listenAccum = 0; listenStart = nil }
    private func listenResume() { if listenStart == nil { listenStart = Date() } }
    private func listenPause() {
        if let s = listenStart { listenAccum += Date().timeIntervalSince(s); listenStart = nil }
    }
    private func commitListen() {
        listenPause()
        if let t = listenTrack, listenAccum >= 1 { library.recordListen(t, seconds: listenAccum) }
        listenTrack = nil; listenAccum = 0
    }

    // MARK: - system integration

    private func publishNowPlaying() {
        NowPlayingCenter.shared.update(track: currentTrack, isPlaying: isPlaying,
                                       elapsed: currentTime, duration: duration)
        publishDiscord()
    }

    private func publishDiscord() {
        guard settings.discordRPCEnabled, !settings.discordClientID.isEmpty, let track = currentTrack else {
            if !settings.discordRPCEnabled { Task { await DiscordRPC.shared.clear() } }
            return
        }
        let clientID = settings.discordClientID
        let title = track.title, artist = track.displayChannel
        let image = track.thumbnailURL?.absoluteString
        var start: Double?, end: Double?
        if isPlaying, duration > 0 {
            let n = Date().timeIntervalSince1970
            start = n - currentTime; end = n - currentTime + duration
        }
        Task {
            await DiscordRPC.shared.updateNowPlaying(
                title: title, artist: artist, imageURL: image,
                startEpoch: start, endEpoch: end, clientID: clientID)
        }
    }
}
