import SwiftUI

struct ContentView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var nav: AppNavigation
    @EnvironmentObject var player: AudioPlayer
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                SidebarView(showSettings: $showSettings).frame(width: 212)
                Divider()
                VStack(spacing: 0) {
                    TopBar()
                    Divider()
                    mainArea
                }
            }
            Divider()
            NowPlayingBar()
        }
        .background(.background)
        .sheet(isPresented: $showSettings) {
            SettingsView().environmentObject(settings)
        }
    }

    @ViewBuilder private var mainArea: some View {
        ZStack {
            pageContent
            if nav.expanded && player.currentTrack != nil {
                ExpandedPlayerView()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.22), value: nav.expanded)
        .overlay(alignment: .topLeading) {
            if nav.showSuggestions && !nav.suggestions.isEmpty {
                SuggestionsList().padding(.leading, 20).padding(.top, 4)
            }
        }
    }

    @ViewBuilder private var pageContent: some View {
        switch nav.page {
        case .home: HomeView()
        case .search: SearchView()
        case .library: LibraryView()
        case .liked: LikedView()
        case .playlist(let id): PlaylistView(playlistID: id)
        }
    }
}

struct TopBar: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var nav: AppNavigation
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search songs, artists…", text: $nav.query)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit { nav.runSearch(on: settings) }
                if nav.searching { ProgressView().controlSize(.small) }
                else if !nav.query.isEmpty {
                    Button { nav.query = ""; nav.searchResults = []; nav.suggestions = [] } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.quaternary.opacity(0.5), in: Capsule())
            .frame(maxWidth: 520)
            Spacer()
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .onChange(of: focused) { isFocused in
            if isFocused {
                nav.showSuggestions = true
            } else {
                // small delay so a suggestion click can register before hiding
                Task { try? await Task.sleep(nanoseconds: 150_000_000); nav.showSuggestions = false }
            }
        }
        .task(id: nav.query) {
            guard focused else { return }
            // collapse the player once the user actually types a query (not on mere focus,
            // which can happen automatically on launch and would hide a remembered player)
            if !nav.query.isEmpty { nav.expanded = false }
            try? await Task.sleep(nanoseconds: 220_000_000)
            if Task.isCancelled { return }
            nav.suggestions = await YTSuggest.fetch(nav.query)
        }
    }
}

struct SuggestionsList: View {
    @EnvironmentObject var nav: AppNavigation
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(nav.suggestions, id: \.self) { s in
                Button { nav.selectSuggestion(s, on: settings) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").font(.caption).foregroundStyle(.secondary)
                        Text(s).lineLimit(1)
                        Spacer()
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if s != nav.suggestions.last { Divider() }
            }
        }
        .frame(width: 480, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary))
        .shadow(radius: 10, y: 4)
    }
}
