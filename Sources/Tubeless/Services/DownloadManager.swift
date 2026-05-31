import Foundation

// one tracked MP3 download, shown as a card in the downloads overlay
struct DownloadItem: Identifiable {
    let id: String          // youtube video id (one download per track at a time)
    let title: String
    var progress: Double    // 0…1 during download
    var state: State

    enum State: Equatable {
        case downloading
        case converting     // download finished, ffmpeg is extracting/encoding
        case done(URL)
        case failed(String)
    }
}

// owns active MP3 downloads: progress, cancellation, and the transient list the
// overlay renders. one entry per track; finished ones auto-dismiss, failed ones
// linger until dismissed.
@MainActor
final class DownloadManager: ObservableObject {
    static let shared = DownloadManager()

    @Published private(set) var items: [DownloadItem] = []
    private var tasks: [String: Task<Void, Never>] = [:]

    private init() {}

    func isActive(_ id: String) -> Bool { tasks[id] != nil }

    func start(_ track: Track) {
        let id = track.id
        guard tasks[id] == nil else { return }
        items.removeAll { $0.id == id }     // clear any lingering finished/failed card
        items.append(DownloadItem(id: id, title: track.title, progress: 0, state: .downloading))

        let quality = AppSettings.shared.downloadQuality
        let ytdlp = AppSettings.shared.ytdlpPath
        let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser

        // strong self is fine: DownloadManager is an app-lifetime singleton
        tasks[id] = Task {
            do {
                let url = try await YTDLPService.shared.download(
                    id: id, quality: quality, to: folder, ytdlp: ytdlp,
                    onProgress: { pct in
                        // called off the main actor; hop back to mutate published state
                        Task { @MainActor in
                            DownloadManager.shared.update(id) {
                                $0.progress = pct
                                if pct >= 1, $0.state == .downloading { $0.state = .converting }
                            }
                        }
                    })
                self.finish(id, .done(url))
            } catch is CancellationError {
                self.remove(id)
            } catch {
                let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                self.finish(id, .failed(msg))
            }
            self.tasks[id] = nil
        }
    }

    // cancel terminates the yt-dlp process; the CancellationError path removes the card
    func cancel(_ id: String) { tasks[id]?.cancel() }

    func dismiss(_ id: String) {
        items.removeAll { $0.id == id }
        tasks[id] = nil
    }

    // MARK: - helpers

    private func update(_ id: String, _ mutate: (inout DownloadItem) -> Void) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        mutate(&items[i])
    }

    private func finish(_ id: String, _ state: DownloadItem.State) {
        update(id) {
            $0.state = state
            if case .done = state { $0.progress = 1 }
        }
        guard case .done = state else { return }
        // successful downloads clear themselves after a moment
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            self?.dismiss(id)
        }
    }

    private func remove(_ id: String) { items.removeAll { $0.id == id } }
}
