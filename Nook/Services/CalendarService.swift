import EventKit

final class CalendarService: ObservableObject {
    @Published private(set) var events: [EKEvent] = []
    @Published private(set) var reminders: [EKReminder] = []
    @Published private(set) var eventsAccess = EKEventStore.authorizationStatus(for: .event) == .fullAccess
    @Published private(set) var remindersAccess = EKEventStore.authorizationStatus(for: .reminder) == .fullAccess

    private let store = EKEventStore()
    private var timer: Timer?

    func start() {
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in self?.reload() }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.reload() }
        requestAccess()
    }

    func requestAccess() {
        Task { [weak self] in
            guard let self else { return }
            let events = (try? await store.requestFullAccessToEvents()) ?? false
            let reminders = (try? await store.requestFullAccessToReminders()) ?? false
            await MainActor.run {
                self.eventsAccess = events
                self.remindersAccess = reminders
                self.reload()
            }
        }
    }

    func reload() {
        if eventsAccess {
            let now = Date()
            let start = Calendar.current.startOfDay(for: now)
            let end = Calendar.current.date(byAdding: .day, value: 7, to: start) ?? now
            events = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
                .filter { $0.endDate > now }
                .sorted { $0.startDate < $1.startDate }
        }
        if remindersAccess {
            let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
            store.fetchReminders(matching: predicate) { [weak self] found in
                let due = { (r: EKReminder) in r.dueDateComponents.flatMap { Calendar.current.date(from: $0) } ?? .distantFuture }
                let sorted = (found ?? []).sorted { due($0) < due($1) }
                DispatchQueue.main.async { self?.reminders = sorted }
            }
        }
    }

    var nextEvent: EKEvent? { events.first { !$0.isAllDay } }

    func complete(_ reminder: EKReminder) {
        reminder.isCompleted = true
        try? store.save(reminder, commit: true)
        reminders.removeAll { $0 == reminder }
    }

    /// Google Meet / Zoom / Teams link from the event's URL, location or notes.
    static func meetingURL(for event: EKEvent) -> URL? {
        let text = [event.url?.absoluteString, event.location, event.notes].compactMap { $0 }.joined(separator: " ")
        let pattern = #"https://(meet\.google\.com|[\w.-]*zoom\.us|teams\.microsoft\.com)/[^\s<>"]+"#
        guard let range = text.range(of: pattern, options: .regularExpression) else { return nil }
        return URL(string: String(text[range]))
    }
}
