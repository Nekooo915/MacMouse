import SwiftUI

struct CursorArtworkPreview: View {
    let cursor: WindowsCursor
    @State private var startedAt = Date.now
    @State private var playing = true
    @State private var showHotSpot = true
    private let frameEnds: [TimeInterval]

    init(cursor: WindowsCursor) {
        self.cursor = cursor
        var total = 0.0
        frameEnds = cursor.frames.map {
            total += $0.duration
            return total
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            TimelineView(.animation(minimumInterval: 1 / 60, paused: !cursor.isAnimated || !playing)) { context in
                let frame = cursor.frames[playing ? frameIndex(at: context.date) : 0]
                if let representation = frame.representations.first {
                    artwork(representation)
                }
            }
            .frame(height: 220)
            .clipShape(RoundedRectangle(cornerRadius: 12))

            HStack(spacing: 12) {
                if let frame = cursor.frames.first, let first = frame.representations.first {
                    let width = first.image.width
                    let height = first.image.height
                    let hotspotX = Int(first.hotSpot.x)
                    let hotspotY = Int(first.hotSpot.y)
                    Text("\(width)×\(height)  ·  热点 \(hotspotX), \(hotspotY)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                Button {
                    showHotSpot.toggle()
                } label: {
                    Image(systemName: showHotSpot ? "scope" : "plus")
                }
                .accessibilityLabel(showHotSpot ? "隐藏热点" : "显示热点")
                .help(showHotSpot ? "隐藏热点" : "显示热点")

                if cursor.isAnimated {
                    Button {
                        startedAt = .now
                        playing.toggle()
                    } label: {
                        Image(systemName: playing ? "pause.fill" : "play.fill")
                    }
                    .accessibilityLabel(playing ? "暂停动画" : "播放动画")
                    .help(playing ? "暂停动画" : "播放动画")
                }
            }
            .buttonStyle(.borderless)
        }
    }

    private func artwork(_ representation: WindowsCursorRepresentation) -> some View {
        GeometryReader { geometry in
            let image = representation.image
            let scale = min(geometry.size.width * 0.56 / CGFloat(image.width),
                            geometry.size.height * 0.68 / CGFloat(image.height))
            let width = CGFloat(image.width) * scale
            let height = CGFloat(image.height) * scale
            let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
            ZStack(alignment: .topLeading) {
                PreviewBackdrop()
                Image(decorative: image, scale: 1, orientation: .up)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: width, height: height)
                    .position(center)
                    .shadow(color: .black.opacity(0.42), radius: 8, y: 5)
                if showHotSpot {
                    let x = center.x - width / 2 + (representation.hotSpot.x + 0.5) * scale
                    let y = center.y - height / 2 + (representation.hotSpot.y + 0.5) * scale
                    Image(systemName: "scope")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color(red: 0.48, green: 0.98, blue: 0.81))
                        .shadow(color: .black, radius: 2)
                        .position(x: x, y: y)
                }
            }
        }
        .accessibilityLabel("光标预览")
    }

    private func frameIndex(at date: Date) -> Int {
        guard let duration = frameEnds.last, duration > 0 else { return 0 }
        let elapsed = max(0, date.timeIntervalSince(startedAt)).truncatingRemainder(dividingBy: duration)
        var lower = 0
        var upper = frameEnds.count - 1
        while lower < upper {
            let middle = (lower + upper) / 2
            if elapsed < frameEnds[middle] {
                upper = middle
            } else {
                lower = middle + 1
            }
        }
        return lower
    }
}

struct PreviewBackdrop: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.10, green: 0.19, blue: 0.25),
                                    Color(red: 0.04, green: 0.09, blue: 0.14)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Canvas { context, size in
                var grid = Path()
                let spacing = 18.0
                for x in stride(from: size.width / 2 - floor(size.width / 2 / spacing) * spacing,
                                to: size.width, by: spacing) {
                    grid.move(to: CGPoint(x: x, y: 0))
                    grid.addLine(to: CGPoint(x: x, y: size.height))
                }
                for y in stride(from: size.height / 2 - floor(size.height / 2 / spacing) * spacing,
                                to: size.height, by: spacing) {
                    grid.move(to: CGPoint(x: 0, y: y))
                    grid.addLine(to: CGPoint(x: size.width, y: y))
                }
                context.stroke(grid, with: .color(.white.opacity(0.09)), lineWidth: 0.5)
            }
        }
        .accessibilityHidden(true)
    }
}
