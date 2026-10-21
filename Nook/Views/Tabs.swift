import SwiftUI

// MARK: Home

struct HomeTab: View {
    @ObservedObject var media: MediaController

    var body: some View {
        NowPlayingCard(media: media).card()
    }
}

struct NowPlayingCard: View {
    @ObservedObject var media: MediaController

    var body: some View {
        if let track = media.track {
            HStack(spacing: 12) {
                Artwork(image: media.artwork, size: 96)
                VStack(alignment: .leading, spacing: 3) {
                    Text(track.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Text(track.artist).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 4)
                    TimelineView(.periodic(from: .now, by: 0.5)) { context in
                        let position = track.position(at: context.date)
                        VStack(spacing: 3) {
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Color.white.opacity(0.15))
                                    Capsule().fill(Color.white).frame(width: geo.size.width * (track.duration > 0 ? position / track.duration : 0))
                                }
                            }
                            .frame(height: 4)
                            HStack {
                                Text(position.clock)
                                Spacer()
                                Text(track.duration.clock)
                            }
                            .font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                    HStack(spacing: 14) {
                        IconButton("backward.fill", initialTab: "media") { media.previous() }
                        IconButton(track.isPlaying ? "pause.fill" : "play.fill", size: 16) { media.playPause() }
                        IconButton("forward.fill") { media.next() }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        } else {
            EmptyState(symbol: "music.note", title: "Nothing playing", detail: "Play something in Music or Spotify")
        }
    }
}

// MARK: Shelf

struct ShelfTab: View {
    @ObservedObject var shelf: FileShelf
    let isTargeted: Bool

    var body: some View {
        Group {
            if shelf.items.isEmpty {
                EmptyState(symbol: "tray.and.arrow.down", title: "Drop files here", detail: "Drag them out again anywhere")
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("\(shelf.items.count) item\(shelf.items.count == 1 ? "" : "s")").font(.system(size: 11)).foregroundStyle(.secondary)
                        Spacer()
                        Button("Clear") { shelf.clear() }.buttonStyle(.plain).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                            .keyboardFocusRing(initialTab: "shelf")
                            .onKeyPress(.return) { shelf.clear(); return .handled }
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(shelf.items, id: \.self) { ShelfCell(url: $0, shelf: shelf) }
                        }
                    }
                }
            }
        }
        .card()
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(isTargeted ? 0.6 : 0), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
        )
    }
}

struct ShelfCell: View {
    let url: URL
    @ObservedObject var shelf: FileShelf

    var body: some View {
        VStack(spacing: 4) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 52, height: 52)
            Text(url.lastPathComponent).font(.system(size: 10)).lineLimit(2).multilineTextAlignment(.center)
        }
        .frame(width: 78)
        .contentShape(Rectangle())
        .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
        .onTapGesture(count: 2) { NSWorkspace.shared.open(url) }
        .keyboardFocusRing()
        .onKeyPress(.delete) { shelf.remove(url); return .handled }
        .accessibilityLabel(url.lastPathComponent)
        .accessibilityHint("Return opens; Delete removes from Shelf; Command Return reveals in Finder")
        .onKeyPress(.return, phases: .down) { press in
            if press.modifiers.contains(.command) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            else { NSWorkspace.shared.open(url) }
            return .handled
        }
        .contextMenu {
            Button("Open") { NSWorkspace.shared.open(url) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Divider()
            Button("Remove from Shelf") { shelf.remove(url) }
        }
    }
}

// MARK: Scratch

struct ScratchTab: View {
    @AppStorage(Prefs.scratch) private var text = ""

    var body: some View {
        TextEditor(text: $text)
            .keyboardInitialFocus(tab: "scratch")
            .font(.system(size: 13))
            .scrollContentBackground(.hidden)
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text("Jot something down…").font(.system(size: 13)).foregroundStyle(.tertiary).padding(.leading, 5).allowsHitTesting(false)
                }
            }
            .card()
    }
}

// MARK: Timers

struct TimersTab: View {
    @ObservedObject var timers: TimerService
    @Namespace private var tabs

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                modeTabs
                Spacer()
                if timers.mode == .pomodoro {
                    Text("\(timers.phase.rawValue) · \(timers.session) of \(timers.totalSessions)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(timers.phase == .focus ? Color.orange : Color.green)
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(Capsule().fill((timers.phase == .focus ? Color.orange : Color.green).opacity(0.14)))
                    IconButton("forward.end.fill", size: 11) { timers.skipPhase() }.help("Skip to the next phase")
                }
                if timers.isActive {
                    IconButton("arrow.counterclockwise", size: 12) { withAnimation(.snappy) { timers.reset() } }.help("Reset")
                }
                Button { timers.toggle() } label: {
                    Text(timers.isRunning ? "Pause" : (timers.isActive ? "Resume" : "Start"))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 20).padding(.vertical, 8)
                        .background(Capsule().fill(Color.orange.opacity(timers.isRunning ? 0.12 : 0.2)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .keyboardFocusRing(initialTab: "timers")
                .onKeyPress(.return) { timers.toggle(); return .handled }
            }

            if timers.mode == .stopwatch {
                Text(timers.displayText)
                    .font(.system(size: 58, weight: .medium, design: .rounded)).monospacedDigit()
                    .foregroundStyle(timers.isActive ? Color.orange : Color.white)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(alignment: .center, spacing: 18) {
                    TimeRuler(minutes: timers.rulerMinutes, editable: !timers.isActive) { timers.setLength(minutes: $0) }
                        .frame(height: 66)
                    Text(timers.displayText)
                        .font(.system(size: 44, weight: .medium, design: .rounded)).monospacedDigit()
                        .foregroundStyle(.orange)
                        .fixedSize()
                }
            }

            if timers.mode == .pomodoro {
                HStack(alignment: .top, spacing: 0) {
                    PomodoroOption(title: "Short break", value: $timers.shortBreak, options: [1, 2, 3, 5, 10, 15], unit: "m")
                    PomodoroOption(title: "Long break", value: $timers.longBreak, options: [10, 15, 20, 25, 30, 45], unit: "m")
                    PomodoroOption(title: "Long break every", value: $timers.sessionsBeforeLong, options: [2, 3, 4, 5, 6], unit: " sessions")
                    PomodoroOption(title: "Total sessions", value: $timers.totalSessions, options: Array(1...8), unit: "")
                }
                .disabled(timers.isRunning)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
        .padding(.top, 2)
    }

    private var modeTabs: some View {
        HStack(spacing: 18) {
            ForEach(TimerService.Mode.allCases, id: \.self) { mode in
                let selected = timers.mode == mode
                Button { withAnimation(.snappy(duration: 0.25)) { timers.mode = mode } } label: {
                    Text(mode.rawValue)
                        .font(.system(size: 13, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? Color.white : Color.secondary)
                        .padding(.bottom, 5)
                        .overlay(alignment: .bottom) {
                            if selected {
                                Capsule().fill(Color.orange).frame(height: 2)
                                    .matchedGeometryEffect(id: "underline", in: tabs)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardFocusRing()
                .onKeyPress(.return) { timers.mode = mode; return .handled }
            }
        }
    }
}

/// Orange tick ruler: one tick per minute, labels every 5, a marker under the value. Drag or click to set.
struct TimeRuler: View {
    let minutes: Int
    let editable: Bool
    let onChange: (Int) -> Void

    private let step: CGFloat = 13
    private let range = 1...120
    @State private var pinnedStart: Int? // window frozen while dragging so ticks don't slide under the finger

    var body: some View {
        GeometryReader { geo in
            let count = max(10, Int(geo.size.width / step))
            let start = pinnedStart ?? windowStart(count: count)
            ZStack(alignment: .topLeading) {
                ForEach(0..<count, id: \.self) { i in
                    let v = start + i
                    let lit = v <= minutes
                    VStack(spacing: 4) {
                        Text(v % 5 == 0 ? "\(v)" : " ")
                            .font(.system(size: 11, weight: .semibold)).monospacedDigit()
                            .foregroundStyle(Color.orange.opacity(lit ? 1 : 0.32))
                            .frame(width: 26, height: 12)
                        Capsule()
                            .fill(Color.orange.opacity(lit ? 1 : 0.22))
                            .frame(width: 5, height: v % 5 == 0 ? 36 : 30)
                            .frame(height: 36, alignment: .bottom)
                        Image(systemName: "triangle.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(.orange)
                            .opacity(v == minutes ? 1 : 0)
                    }
                    .frame(width: step)
                    .offset(x: CGFloat(i) * step)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        guard editable else { return }
                        if pinnedStart == nil { pinnedStart = start }
                        let v = (pinnedStart ?? start) + Int(drag.location.x / step)
                        let clamped = min(range.upperBound, max(range.lowerBound, v))
                        if clamped != minutes {
                            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                            onChange(clamped)
                        }
                    }
                    .onEnded { _ in withAnimation(.snappy(duration: 0.3)) { pinnedStart = nil } }
            )
            .opacity(editable ? 1 : 0.95)
            .keyboardFocusRing()
            .accessibilityLabel("Timer duration")
            .accessibilityValue("\(minutes) minutes")
            .onMoveCommand { direction in
                guard editable else { return }
                let delta = direction == .left || direction == .down ? -1 : 1
                onChange(min(range.upperBound, max(range.lowerBound, minutes + delta)))
            }
            .animation(.snappy(duration: 0.25), value: minutes)
        }
    }

    /// Keep the value ~60% across, like a dial.
    private func windowStart(count: Int) -> Int {
        let ideal = minutes - Int(Double(count) * 0.6)
        return max(range.lowerBound - 1, min(ideal, range.upperBound - count + 1))
    }
}

private struct PomodoroOption: View {
    let title: String
    @Binding var value: Int
    let options: [Int]
    let unit: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            Menu {
                ForEach(options, id: \.self) { option in
                    Button("\(option)\(unit)") { value = option }
                }
            } label: {
                // One Text (value + chevron) so the menu can't reorder them.
                (Text("\(value)\(unit == "m" ? "m" : "") ").font(.system(size: 14, weight: .semibold))
                    + Text(Image(systemName: "chevron.down")).font(.system(size: 8, weight: .bold)))
                    .foregroundStyle(.orange)
            }
            .menuStyle(.borderlessButton)
            .keyboardFocusRing()
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
