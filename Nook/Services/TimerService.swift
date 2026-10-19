import AppKit

final class TimerService: ObservableObject {
    enum Mode: String, CaseIterable { case countdown = "Timer", stopwatch = "Stopwatch" }

    @Published var mode: Mode = .countdown { didSet { if oldValue != mode { reset() } } }
    @Published private(set) var duration: TimeInterval = 25 * 60
    @Published private(set) var isRunning = false
    @Published private(set) var now = Date()

    var onFinish: (() -> Void)?

    private var endDate: Date?
    private var pausedRemaining: TimeInterval?
    private var startDate: Date?
    private var accumulated: TimeInterval = 0
    private var ticker: Timer?

    var value: TimeInterval {
        switch mode {
        case .countdown:
            if let endDate { return max(0, endDate.timeIntervalSince(now)) }
            return pausedRemaining ?? duration
        case .stopwatch:
            return accumulated + (startDate.map { now.timeIntervalSince($0) } ?? 0)
        }
    }

    var displayText: String {
        let total = Int(value.rounded(mode == .countdown ? .up : .down))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    func toggle() { isRunning ? pause() : start() }

    func start() {
        guard !isRunning else { return }
        now = Date()
        switch mode {
        case .countdown:
            endDate = now.addingTimeInterval(pausedRemaining ?? duration)
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
        case .countdown: pausedRemaining = value; endDate = nil
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
        now = Date()
    }

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

    private func tick() {
        now = Date()
        guard mode == .countdown, let endDate, now >= endDate else { return }
        reset()
        NSSound(named: "Glass")?.play()
        onFinish?()
    }
}
