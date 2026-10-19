import AppKit

/// Timer, Pomodoro and Stopwatch. Pomodoro runs focus → short break → … → long break every N sessions, automatically.
final class TimerService: ObservableObject {
    enum Mode: String, CaseIterable { case countdown = "Timer", pomodoro = "Pomodoro", stopwatch = "Stopwatch" }
    enum Phase: String { case focus = "Focus", shortBreak = "Short break", longBreak = "Long break" }

    @Published var mode: Mode = .countdown { didSet { if oldValue != mode { reset() } } }
    @Published private(set) var duration: TimeInterval = 25 * 60
    @Published private(set) var isRunning = false
    @Published private(set) var now = Date()

    // Pomodoro
    @Published private(set) var phase: Phase = .focus
    @Published private(set) var session = 1
    @Published var focusMinutes: Int = UserDefaults.standard.object(forKey: Keys.focus) as? Int ?? 25 { didSet { save(Keys.focus, focusMinutes) } }
    @Published var shortBreak: Int = UserDefaults.standard.object(forKey: Keys.short) as? Int ?? 5 { didSet { save(Keys.short, shortBreak) } }
    @Published var longBreak: Int = UserDefaults.standard.object(forKey: Keys.long) as? Int ?? 15 { didSet { save(Keys.long, longBreak) } }
    @Published var sessionsBeforeLong: Int = UserDefaults.standard.object(forKey: Keys.every) as? Int ?? 4 { didSet { save(Keys.every, sessionsBeforeLong) } }
    @Published var totalSessions: Int = UserDefaults.standard.object(forKey: Keys.total) as? Int ?? 4 { didSet { save(Keys.total, totalSessions) } }

    var onFinish: (() -> Void)?

    private enum Keys {
        static let focus = "pomodoroFocus", short = "pomodoroShort", long = "pomodoroLong", every = "pomodoroEvery", total = "pomodoroTotal"
    }

    private var endDate: Date?
    private var pausedRemaining: TimeInterval?
    private var startDate: Date?
    private var accumulated: TimeInterval = 0
    private var ticker: Timer?

    /// Length of the current countdown (timer, or the current pomodoro phase).
    var phaseLength: TimeInterval {
        switch mode {
        case .countdown: duration
        case .pomodoro:
            switch phase {
            case .focus: TimeInterval(focusMinutes * 60)
            case .shortBreak: TimeInterval(shortBreak * 60)
            case .longBreak: TimeInterval(longBreak * 60)
            }
        case .stopwatch: 0
        }
    }

    var value: TimeInterval {
        switch mode {
        case .countdown, .pomodoro:
            if let endDate { return max(0, endDate.timeIntervalSince(now)) }
            return pausedRemaining ?? phaseLength
        case .stopwatch:
            return accumulated + (startDate.map { now.timeIntervalSince($0) } ?? 0)
        }
    }

    var displayText: String {
        let total = Int(value.rounded(mode == .stopwatch ? .down : .up))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    /// Something has started and not been reset (running or paused mid-way).
    var isActive: Bool { isRunning || pausedRemaining != nil || accumulated > 0 }

    /// Minutes the ruler shows: the remaining time while active, otherwise the chosen length.
    var rulerMinutes: Int {
        if isActive, mode != .stopwatch { return max(0, Int((value / 60).rounded(.up))) }
        return mode == .pomodoro ? currentSetMinutes : Int(duration / 60)
    }

    private var currentSetMinutes: Int {
        switch phase {
        case .focus: focusMinutes
        case .shortBreak: shortBreak
        case .longBreak: longBreak
        }
    }

    /// Ruler / presets: set the length (timer duration, or the pomodoro phase being edited) without starting.
    func setLength(minutes: Int) {
        let m = max(1, min(180, minutes))
        switch mode {
        case .countdown: duration = TimeInterval(m * 60)
        case .pomodoro:
            switch phase {
            case .focus: focusMinutes = m
            case .shortBreak: shortBreak = m
            case .longBreak: longBreak = m
            }
        case .stopwatch: break
        }
        now = Date()
    }

    func toggle() { isRunning ? pause() : start() }

    func start() {
        guard !isRunning else { return }
        now = Date()
        switch mode {
        case .countdown, .pomodoro:
            endDate = now.addingTimeInterval(pausedRemaining ?? phaseLength)
            pausedRemaining = nil
        case .stopwatch:
            startDate = now
        }
        isRunning = true
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    func pause() {
        guard isRunning else { return }
        now = Date()
        switch mode {
        case .countdown, .pomodoro: pausedRemaining = value; endDate = nil
        case .stopwatch: accumulated = value; startDate = nil
        }
        stopTicker()
    }

    func reset() {
        stopTicker()
        endDate = nil
        pausedRemaining = nil
        startDate = nil
        accumulated = 0
        phase = .focus
        session = 1
        now = Date()
    }

    /// Skip to the next pomodoro phase.
    func skipPhase() {
        guard mode == .pomodoro else { return }
        let wasRunning = isRunning
        advancePhase()
        if wasRunning { start() }
    }

    /// Used by the Home plugin's quick buttons and `nook.timer.start`.
    func set(minutes: Int) {
        mode = .countdown
        reset()
        duration = TimeInterval(minutes * 60)
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
        isRunning = false
    }

    private func save(_ key: String, _ value: Int) { UserDefaults.standard.set(value, forKey: key) }

    private func tick() {
        now = Date()
        guard mode != .stopwatch, let endDate, now >= endDate else { return }
        NSSound(named: mode == .pomodoro && phase == .focus ? "Hero" : "Glass")?.play()
        if mode == .pomodoro {
            let finishedAll = phase == .focus && session >= totalSessions
            if finishedAll {
                reset()
                onFinish?()
            } else {
                advancePhase()
                start() // pomodoro flows on by itself
            }
        } else {
            reset()
            onFinish?()
        }
    }

    private func advancePhase() {
        stopTicker()
        endDate = nil
        pausedRemaining = nil
        if phase == .focus {
            phase = session % max(1, sessionsBeforeLong) == 0 ? .longBreak : .shortBreak
        } else {
            session = min(totalSessions, session + 1)
            phase = .focus
        }
        now = Date()
    }
}
