import SwiftUI
import UniformTypeIdentifiers
import AppKit

// drag-to-reorder for the custom ScrollView track lists (List's .onMove isn't
// available here). Rather than swapping live as the cursor passes each row
// (which makes the list jitter), it only marks the hovered row as the drop
// target and commits a single move on drop. `move` gets source/target indices.
struct TrackDropDelegate: DropDelegate {
    let item: Track
    let tracks: [Track]
    @Binding var dragging: Track?
    @Binding var dropTarget: String?
    let move: (Int, Int) -> Void

    func dropEntered(info: DropInfo) {
        if dragging?.id != item.id { dropTarget = item.id }
    }

    // clear the insertion bar when the cursor leaves this row without entering
    // another — including when the drag leaves the app entirely
    func dropExited(info: DropInfo) {
        if dropTarget == item.id { dropTarget = nil }
    }

    func dropUpdated(info: DropInfo) -> DropProposal { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        defer { dragging = nil; dropTarget = nil }
        guard let dragging, dragging.id != item.id,
              let from = tracks.firstIndex(where: { $0.id == dragging.id }),
              let to = tracks.firstIndex(where: { $0.id == item.id }) else { return false }
        withAnimation(.easeInOut(duration: 0.25)) { move(from, to) }
        return true
    }
}

extension View {
    // makes a track row draggable + a drop target for reordering within `tracks`
    func reorderable(_ track: Track, in tracks: [Track],
                     dragging: Binding<Track?>, dropTarget: Binding<String?>,
                     move: @escaping (Int, Int) -> Void) -> some View {
        modifier(ReorderableRow(track: track, tracks: tracks,
                                dragging: dragging, dropTarget: dropTarget, move: move))
    }
}

private struct ReorderableRow: ViewModifier {
    let track: Track
    let tracks: [Track]
    @Binding var dragging: Track?
    @Binding var dropTarget: String?
    let move: (Int, Int) -> Void

    // bar sits on the side the dragged row is coming from, so it reads as "lands here"
    private var topEdge: Bool {
        guard let d = dragging,
              let from = tracks.firstIndex(where: { $0.id == d.id }),
              let to = tracks.firstIndex(where: { $0.id == track.id }) else { return true }
        return from > to
    }

    func body(content: Content) -> some View {
        content
            .overlay(alignment: topEdge ? .top : .bottom) {
                if dropTarget == track.id, dragging?.id != track.id {
                    Capsule().fill(.tint).frame(height: 2).padding(.horizontal, 6)
                }
            }
            .onDrag {
                dragging = track
                // dropping outside the app pastes the YouTube Music link; vend both
                // a URL (browsers) and plain text (editors/fields)
                let provider = NSItemProvider()
                provider.registerObject(track.musicURL() as NSURL, visibility: .all)
                provider.registerObject(track.musicURL().absoluteString as NSString, visibility: .all)
                return provider
            }
            .onDrop(of: [.url, .text], delegate: TrackDropDelegate(
                item: track, tracks: tracks, dragging: $dragging,
                dropTarget: $dropTarget, move: move))
    }
}

// square artwork with graceful placeholder
struct Artwork: View {
    let url: URL?
    var size: CGFloat = 46
    var corner: CGFloat = 6

    var body: some View {
        AsyncImage(url: url) { img in
            img.resizable().aspectRatio(contentMode: .fill)
        } placeholder: {
            Rectangle().fill(.quaternary)
                .overlay(Image(systemName: "music.note").foregroundStyle(.secondary))
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: corner))
    }
}

// artwork that toggles play/pause on click; shows an icon on hover and
// keeps it visible while paused so the paused state is always obvious
struct PlayPauseArtwork: View {
    let url: URL?
    var size: CGFloat = 46
    var corner: CGFloat = 6
    @EnvironmentObject var player: AudioPlayer
    @State private var hovering = false

    var body: some View {
        Artwork(url: url, size: size, corner: corner)
            .overlay {
                if player.currentTrack != nil {
                    if player.isLoading {
                        ZStack {
                            RoundedRectangle(cornerRadius: corner).fill(.black.opacity(0.45))
                            ProgressView().controlSize(size > 80 ? .regular : .small).tint(.white)
                        }
                    } else if hovering || !player.isPlaying {
                        ZStack {
                            RoundedRectangle(cornerRadius: corner).fill(.black.opacity(0.4))
                            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: max(size * 0.26, 12), weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }
                }
            }
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture { if !player.isLoading { player.togglePlayPause() } }
            .animation(.easeInOut(duration: 0.12), value: hovering)
            .animation(.easeInOut(duration: 0.12), value: player.isLoading)
    }
}

// copies a track's YouTube Music link, optionally starting at a timestamp
// (defaults to the current playback position)
struct ShareButton: View {
    let track: Track
    @EnvironmentObject var player: AudioPlayer
    @State private var showing = false
    @State private var withTimestamp = false
    @State private var timestamp = ""
    @State private var copied = false

    var body: some View {
        Button {
            timestamp = Self.format(Int(player.currentTime))
            copied = false
            showing = true
        } label: {
            Image(systemName: "square.and.arrow.up")
        }
        .buttonStyle(.plain)
        .help("Share link")
        .popover(isPresented: $showing, arrowEdge: .bottom) { popover }
    }

    private var link: URL {
        track.musicURL(at: withTimestamp ? Self.seconds(from: timestamp) : nil)
    }

    private var popover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Share").font(.headline)
            Text(link.absoluteString)
                .font(.caption.monospaced()).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            Toggle("Start at timestamp", isOn: $withTimestamp)
            if withTimestamp {
                TextField("m:ss", text: $timestamp)
                    .textFieldStyle(.roundedBorder).frame(width: 90)
            }
            Button {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(link.absoluteString, forType: .string)
                copied = true
            } label: {
                Label(copied ? "Copied!" : "Copy link", systemImage: copied ? "checkmark" : "doc.on.doc")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(14)
        .frame(width: 250)
        .onChange(of: withTimestamp) { _ in copied = false }
        .onChange(of: timestamp) { _ in copied = false }
    }

    // "m:ss" / "h:mm:ss" / bare seconds → seconds
    private static func seconds(from text: String) -> Int {
        let parts = text.split(separator: ":").map { Int($0.trimmingCharacters(in: .whitespaces)) ?? 0 }
        guard !parts.isEmpty else { return 0 }
        return parts.reduce(0) { $0 * 60 + $1 }
    }

    private static func format(_ seconds: Int) -> String {
        let s = max(0, seconds)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

struct SectionHeader: View {
    let title: String
    var body: some View {
        Text(title).font(.title2.bold())
            .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 10)
    }
}

// a single-click-to-play list row with current highlight, like + overflow menu
struct TrackRow: View {
    let track: Track
    var inPlaylist: UUID? = nil
    var dimmed: Bool = false          // e.g. already-played items above the pointer
    var onPlay: () -> Void

    @EnvironmentObject var player: AudioPlayer
    @EnvironmentObject var library: LibraryStore
    @State private var hovering = false

    private var isCurrent: Bool { player.currentTrack?.id == track.id }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Artwork(url: track.thumbnailURL)
                if isCurrent {
                    RoundedRectangle(cornerRadius: 6).fill(.black.opacity(0.45))
                        .frame(width: 46, height: 46)
                    if player.isLoading {
                        ProgressView().controlSize(.small).tint(.white)
                    } else {
                        Image(systemName: player.isPlaying ? "speaker.wave.2.fill" : "pause.fill")
                            .foregroundStyle(.white).font(.caption)
                    }
                } else if hovering {
                    RoundedRectangle(cornerRadius: 6).fill(.black.opacity(0.4))
                        .frame(width: 46, height: 46)
                    Image(systemName: "play.fill").foregroundStyle(.white)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title).lineLimit(1)
                    .fontWeight(isCurrent ? .semibold : .regular)
                    .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                HStack(spacing: 6) {
                    if track.isTopic {
                        Text("SONG").font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(.tint.opacity(0.2), in: Capsule())
                    }
                    Text(track.displayChannel).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()

            if hovering || library.isLiked(track) {
                Button { library.toggleLike(track) } label: {
                    Image(systemName: library.isLiked(track) ? "heart.fill" : "heart")
                        .foregroundStyle(library.isLiked(track) ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                }
                .buttonStyle(.plain)
            }
            Text(track.durationText).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            if hovering {
                Menu {
                    Button("Play next") { player.playNext(track) }
                    Button("Add to queue") { player.enqueue(track) }
                    Button { player.startRadio(from: track) } label: {
                        Label("Start radio", systemImage: "dot.radiowaves.left.and.right")
                    }
                    Divider()
                    if player.downloading.contains(track.id) {
                        Button("Downloading…") {}.disabled(true)
                    } else {
                        Button { player.download(track) } label: { Label("Download MP3", systemImage: "arrow.down.circle") }
                    }
                    Button {
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.setString(track.musicURL().absoluteString, forType: .string)
                    } label: { Label("Copy link", systemImage: "square.and.arrow.up") }
                    if !library.playlists.isEmpty {
                        Menu("Add to playlist") {
                            ForEach(library.playlists) { p in
                                Button(p.name) { library.addToPlaylist(track, playlistID: p.id) }
                            }
                        }
                    }
                    if let pid = inPlaylist {
                        Divider()
                        Button("Remove from playlist", role: .destructive) {
                            library.removeFromPlaylist(track, playlistID: pid)
                        }
                    }
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
        }
        .padding(.vertical, 4).padding(.horizontal, 8)
        .background(isCurrent ? Color.primary.opacity(0.06) : (hovering ? Color.primary.opacity(0.03) : .clear),
                    in: RoundedRectangle(cornerRadius: 8))
        .opacity(dimmed && !isCurrent ? 0.55 : 1)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { onPlay() }
    }
}

// horizontal "card" for Home rows (Listen again / Discovery)
struct TrackCard: View {
    let track: Track
    let context: [Track]?
    @EnvironmentObject var player: AudioPlayer
    @EnvironmentObject var nav: AppNavigation
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                Artwork(url: track.thumbnailURL, size: 148, corner: 10)
                if hovering {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 34)).foregroundStyle(.white, .tint)
                        .padding(8).shadow(radius: 4)
                }
            }
            Text(track.cleanedTitle.isEmpty ? track.title : track.cleanedTitle)
                .font(.subheadline).lineLimit(1).frame(width: 148, alignment: .leading)
            Text(track.displayChannel).font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).frame(width: 148, alignment: .leading)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { nav.play(track, context: context, on: player) }
    }
}
