import SwiftUI

struct IconButton: View {
    let symbol: String
    var size: CGFloat = 13
    let action: () -> Void
    @State private var hovering = false

    init(_ symbol: String, size: CGFloat = 13, action: @escaping () -> Void) {
        self.symbol = symbol
        self.size = size
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .frame(width: size + 16, height: size + 16)
                .background(Circle().fill(Color.white.opacity(hovering ? 0.14 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct Artwork: View {
    let image: NSImage?
    let size: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color.white.opacity(0.08)
                    Image(systemName: "music.note").font(.system(size: size * 0.4)).foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.2, style: .continuous))
    }
}

struct AudioBars: View {
    let playing: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20, paused: !playing)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2) {
                ForEach(0..<4, id: \.self) { i in
                    let level = playing ? 0.3 + 0.7 * abs(sin(t * (3.1 + Double(i) * 0.9) + Double(i))) : 0.25
                    Capsule().fill(Color.white).frame(width: 3).scaleEffect(y: level)
                }
            }
        }
    }
}

struct EmptyState: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 22)).foregroundStyle(.secondary)
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension View {
    func card() -> some View {
        padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.06)))
    }
}

extension TimeInterval {
    var clock: String {
        let total = Int(max(0, self))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
