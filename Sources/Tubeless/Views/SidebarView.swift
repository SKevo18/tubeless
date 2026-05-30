import SwiftUI

struct SidebarView: View {
    @Binding var showSettings: Bool
    @EnvironmentObject var nav: AppNavigation
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var player: AudioPlayer
    @State private var newPlaylistName = ""
    @State private var creating = false
    @State private var importing = false
    @State private var importURL = ""
    @State private var importBusy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "waveform.circle.fill").font(.title2).foregroundStyle(.tint)
                Text("Tubeless").font(.title3.bold())
            }
            .padding(.horizontal, 18).padding(.top, 18).padding(.bottom, 16)

            navItem("Home", "house.fill", page: .home)
            navItem("Search", "magnifyingglass", page: .search)
            navItem("Library", "square.stack.fill", page: .library)
            navItem("Liked Songs", "heart.fill", page: .liked, badge: library.liked.count)

            HStack(spacing: 10) {
                Text("PLAYLISTS").font(.caption.bold()).foregroundStyle(.secondary)
                Spacer()
                if importBusy { ProgressView().controlSize(.small) }
                Button { importURL = ""; importing = true } label: { Image(systemName: "square.and.arrow.down") }
                    .buttonStyle(.icon).foregroundStyle(.secondary)
                    .tooltip("Import a YouTube playlist by link")
                Button { creating = true } label: { Image(systemName: "plus") }
                    .buttonStyle(.icon).foregroundStyle(.secondary)
                    .tooltip("New empty playlist")
            }
            .padding(.horizontal, 18).padding(.top, 18).padding(.bottom, 6)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(library.playlists) { p in
                        playlistItem(p)
                    }
                }
            }

            Spacer(minLength: 0)
            Divider().padding(.horizontal, 12)
            Button { showSettings = true } label: {
                Label("Settings", systemImage: "gearshape")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18).padding(.vertical, 12)
                    .rowLink()
            }
            .buttonStyle(.plain).tooltip("Settings")
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.background.opacity(0.6))
        .dismissesFocusOnTap()
        .alert("New Playlist", isPresented: $creating) {
            TextField("Name", text: $newPlaylistName)
            Button("Create") {
                let name = newPlaylistName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { library.createPlaylist(name: name) }
                newPlaylistName = ""
            }
            Button("Cancel", role: .cancel) { newPlaylistName = "" }
        }
        .alert("Import YouTube Playlist", isPresented: $importing) {
            TextField("Playlist URL", text: $importURL)
            Button("Import") { importPlaylist() }
            Button("Cancel", role: .cancel) { importURL = "" }
        } message: {
            Text("Paste a YouTube playlist link. Its songs will be added as a new playlist.")
        }
    }

    private func importPlaylist() {
        let url = importURL.trimmingCharacters(in: .whitespacesAndNewlines)
        importURL = ""
        guard !url.isEmpty else { return }
        importBusy = true
        Task {
            let result = try? await YTDLPService.shared.playlist(url: url, ytdlp: AppSettings.shared.ytdlpPath)
            if let result, !result.tracks.isEmpty {
                library.createPlaylist(name: result.title, tracks: result.tracks)
                nav.page = .library
            }
            importBusy = false
        }
    }

    private func navItem(_ title: String, _ icon: String, page: Page, badge: Int = 0) -> some View {
        let selected = nav.page == page
        return Button {
            nav.page = page; nav.expanded = false
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon).frame(width: 20)
                Text(title)
                Spacer()
                if badge > 0 {
                    Text("\(badge)").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 9)
            .rowLink(selected: selected)
        }
        .buttonStyle(.plain)
    }

    private func playlistItem(_ p: Playlist) -> some View {
        let selected = nav.page == .playlist(p.id)
        return Button {
            nav.page = .playlist(p.id); nav.expanded = false
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "music.note.list").font(.caption).foregroundStyle(.secondary)
                Text(p.name).lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 18).padding(.vertical, 7)
            .rowLink(selected: selected)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Play") { if let f = p.tracks.first { nav.play(f, context: p.tracks, on: player) } }
            Button("Shuffle") { nav.playShuffled(p.tracks, on: player) }
            Button("Start radio") { nav.startRadio(from: p.tracks, on: player) }
            Divider()
            Button("Delete", role: .destructive) { library.deletePlaylist(p.id) }
        }
    }
}
