import SwiftUI

// interactive seek bar that paints SponsorBlock segments in their category color
struct SponsorTimeline: View {
    let duration: Double
    let currentTime: Double
    let segments: [SponsorSegment]
    let onSeek: (Double) -> Void

    @EnvironmentObject var settings: AppSettings
    @State private var dragFraction: Double?

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let dur = max(duration, 0.001)
            let fraction = dragFraction ?? (currentTime / dur)
            let progressW = min(max(fraction, 0), 1) * w

            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary).frame(height: 5)            // base track
                Capsule().fill(.tint).frame(width: progressW, height: 5) // played

                if settings.showSegmentsOnTimeline {
                    ForEach(segments, id: \.self) { seg in
                        let x = (seg.start / dur) * w
                        let segW = max(((seg.end - seg.start) / dur) * w, 2)
                        Capsule()
                            .fill(settings.color(for: seg.category))
                            .frame(width: segW, height: 6)
                            .offset(x: x)
                    }
                }

                Circle().fill(.tint)
                    .frame(width: 11, height: 11)
                    .offset(x: min(max(progressW - 5.5, 0), w - 11))
                    .shadow(radius: 1)
            }
            .frame(height: 14)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in dragFraction = min(max(v.location.x / w, 0), 1) }
                    .onEnded { v in
                        let f = min(max(v.location.x / w, 0), 1)
                        dragFraction = nil
                        onSeek(f * dur)
                    }
            )
        }
        .frame(height: 16)
    }
}
