import EventKit
import SwiftUI

// MARK: Home

struct HomeTab: View {
    @ObservedObject var media: MediaController
    @ObservedObject var calendar: CalendarService

    var body: some View {
        HStack(spacing: 10) {
            NowPlayingCard(media: media).card()
            UpNextCard(calendar: calendar).card().frame(width: 230)
        }
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
                        IconButton("backward.fill") { media.previous() }
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

struct UpNextCard: View {
    @ObservedObject var calendar: CalendarService

    var body: some View {
        if !calendar.eventsAccess {
            EmptyState(symbol: "calendar", title: "Calendar is off", detail: "Allow Nook in System Settings → Privacy → Calendars")
        } else if let event = calendar.nextEvent {
            VStack(alignment: .leading, spacing: 6) {
                Text("UP NEXT").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                Text(event.title ?? "Untitled").font(.system(size: 14, weight: .semibold)).lineLimit(2)
                Text(event.startDate.formatted(date: .omitted, time: .shortened) + " – " + event.endDate.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(relative(event, now: context.date)).font(.system(size: 12, weight: .medium)).foregroundStyle(.orange)
                }
                Spacer(minLength: 0)
                if let url = CalendarService.meetingURL(for: event) {
                    Button { NSWorkspace.shared.open(url) } label: {
                        Label("Join", systemImage: "video.fill").font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Capsule().fill(Color.white.opacity(0.14)))
                    }
                    .buttonStyle(.plain)
                }
            }
        } else {
            EmptyState(symbol: "checkmark.circle", title: "All clear", detail: "No more meetings this week")
        }
    }

    private func relative(_ event: EKEvent, now: Date) -> String {
        if event.startDate <= now { return "Happening now" }
        let minutes = Int(event.startDate.timeIntervalSince(now) / 60)
        if minutes < 60 { return "In \(max(minutes, 1)) min" }
        return event.startDate.formatted(.relative(presentation: .named))
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
    private let presets = [1, 5, 10, 15, 25, 45, 60]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("", selection: $timers.mode) {
                ForEach(TimerService.Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 200)

            HStack(alignment: .center) {
                Text(timers.displayText)
                    .font(.system(size: 46, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(timers.isRunning ? .orange : .white)
                Spacer()
                IconButton("arrow.counterclockwise", size: 15) { timers.reset() }
                IconButton(timers.isRunning ? "pause.fill" : "play.fill", size: 20) { timers.toggle() }
            }

            if timers.mode == .countdown {
                HStack(spacing: 6) {
                    ForEach(presets, id: \.self) { minutes in
                        Button("\(minutes)m") { timers.set(minutes: minutes) }
                            .buttonStyle(.plain).font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Capsule().fill(Color.white.opacity(0.1)))
                    }
                }
            }
        }
        .card()
    }
}

// MARK: Calendar

struct CalendarTab: View {
    @ObservedObject var calendar: CalendarService

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            agenda.card()
            reminders.card().frame(width: 230)
        }
    }

    @ViewBuilder private var agenda: some View {
        if !calendar.eventsAccess {
            EmptyState(symbol: "calendar", title: "Calendar is off", detail: "Allow Nook in System Settings → Privacy → Calendars")
        } else if calendar.events.isEmpty {
            EmptyState(symbol: "calendar", title: "Nothing this week", detail: "Enjoy the quiet")
        } else {
            let days = Dictionary(grouping: calendar.events) { Calendar.current.startOfDay(for: $0.startDate) }
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(days.keys.sorted(), id: \.self) { day in
                        Text(dayTitle(day)).font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary).padding(.top, 2)
                        ForEach(days[day] ?? [], id: \.self) { EventRow(event: $0) }
                    }
                }
            }
        }
    }

    @ViewBuilder private var reminders: some View {
        if !calendar.remindersAccess {
            EmptyState(symbol: "checklist", title: "Reminders are off", detail: "Allow Nook in System Settings → Privacy → Reminders")
        } else if calendar.reminders.isEmpty {
            EmptyState(symbol: "checkmark.circle", title: "All done", detail: "No open reminders")
        } else {
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(calendar.reminders, id: \.self) { reminder in
                        HStack(alignment: .top, spacing: 8) {
                            Button { withAnimation { calendar.complete(reminder) } } label: {
                                Image(systemName: "circle").font(.system(size: 13))
                            }
                            .buttonStyle(.plain)
                            Text(reminder.title ?? "").font(.system(size: 12)).lineLimit(2)
                        }
                    }
                }
            }
        }
    }

    private func dayTitle(_ day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return "TODAY" }
        if Calendar.current.isDateInTomorrow(day) { return "TOMORROW" }
        return day.formatted(.dateTime.weekday(.wide).day().month()).uppercased()
    }
}

struct EventRow: View {
    let event: EKEvent

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(Color(cgColor: event.calendar.cgColor)).frame(width: 7, height: 7)
            Text(event.title ?? "Untitled").font(.system(size: 12)).lineLimit(1)
            Spacer()
            Text(event.isAllDay ? "All day" : event.startDate.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
            if let url = CalendarService.meetingURL(for: event) {
                IconButton("video.fill", size: 10) { NSWorkspace.shared.open(url) }
            }
        }
    }
}
