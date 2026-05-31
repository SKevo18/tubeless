import AppKit
import SwiftUI

// a floating stack of download cards, bottom-right of the content area (above the
// now-playing bar). each card shows live progress and can be cancelled.
struct DownloadsOverlay: View {
    @EnvironmentObject var downloads: DownloadManager

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            ForEach(downloads.items) { DownloadCard(item: $0) }
        }
        .padding(16)
        .animation(.spring(response: 0.32, dampingFraction: 0.85), value: downloads.items.map(\.id))
    }
}

struct DownloadCard: View {
    let item: DownloadItem
    @EnvironmentObject var downloads: DownloadManager

    var body: some View {
        HStack(spacing: 10) {
            icon
            VStack(alignment: .leading, spacing: 5) {
                Text(item.title).font(.caption.weight(.medium)).lineLimit(1)
                detail
            }
            Spacer(minLength: 4)
            trailing
        }
        .padding(10)
        .frame(width: 280)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary))
        .shadow(radius: 8, y: 3)
        .transition(.move(edge: .trailing).combined(with: .opacity))
    }

    @ViewBuilder private var icon: some View {
        switch item.state {
        case .downloading, .converting:
            Image(systemName: "arrow.down.circle").foregroundStyle(.tint)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }

    @ViewBuilder private var detail: some View {
        switch item.state {
        case .downloading:
            ProgressView(value: item.progress)
                .progressViewStyle(.linear).controlSize(.small)
            Text("\(Int(item.progress * 100))%").font(.caption2).foregroundStyle(.secondary)
        case .converting:
            ProgressView().progressViewStyle(.linear).controlSize(.small)
            Text("Converting…").font(.caption2).foregroundStyle(.secondary)
        case .done:
            Text("Saved to Downloads").font(.caption2).foregroundStyle(.secondary)
        case .failed(let msg):
            Text(msg).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
        }
    }

    @ViewBuilder private var trailing: some View {
        switch item.state {
        case .downloading, .converting:
            Button { downloads.cancel(item.id) } label: { Image(systemName: "xmark") }
                .buttonStyle(.icon).foregroundStyle(.secondary).tooltip("Cancel download")
        case .done(let url):
            Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.icon).foregroundStyle(.secondary).tooltip("Show in Finder")
        case .failed:
            Button { downloads.dismiss(item.id) } label: { Image(systemName: "xmark") }
                .buttonStyle(.icon).foregroundStyle(.secondary).tooltip("Dismiss")
        }
    }
}
