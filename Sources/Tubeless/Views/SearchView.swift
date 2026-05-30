import SwiftUI

struct SearchView: View {
    @EnvironmentObject var nav: AppNavigation
    @EnvironmentObject var player: AudioPlayer

    var body: some View {
        if let err = nav.searchError {
            placeholder("exclamationmark.triangle", "Search failed", err)
        } else if nav.searchResults.isEmpty {
            placeholder("magnifyingglass", "Search YouTube",
                        "Song versions are preferred over music videos.")
        } else {
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(nav.searchResults) { track in
                        TrackRow(track: track) { nav.play(track, context: nav.searchResults, on: player) }
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
            }
        }
    }

    private func placeholder(_ icon: String, _ title: String, _ subtitle: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 38)).foregroundStyle(.tertiary)
            Text(title).font(.headline)
            Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
