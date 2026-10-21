import AppKit

/// Now playing for Music and Spotify via AppleScript polling (MediaRemote is closed to third-party apps).
final class MediaController: ObservableObject {
    struct Track: Equatable {
        var bundleID: String
        var title: String
        var artist: String
        var album: String
        var duration: Double
        var position: Double
        var isPlaying: Bool
        var polledAt: Date

        /// Position interpolated between polls.
        func position(at date: Date) -> Double {
            min(duration, position + (isPlaying ? date.timeIntervalSince(polledAt) : 0))
        }
    }

    @Published private(set) var track: Track?
    @Published private(set) var artwork: NSImage?

    private static let players = ["com.apple.Music", "com.spotify.client"]
    private let queue = DispatchQueue(label: "nook.media", qos: .userInitiated)
    private var timer: Timer?
    private var artworkKey = ""
    private var artworkTask: URLSessionDataTask?
    private var pollWork: DispatchWorkItem?

    private var active = false
    private var polling = false
    private var observers: [NSObjectProtocol] = []
    func start() {
        guard !active else { return }; active = true
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.poll() })
        }
        poll()
    }

    func stop() {
        active = false
        pollWork?.cancel(); pollWork = nil
        artworkTask?.cancel(); artworkTask = nil
        timer?.invalidate(); timer = nil
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }; observers = []
        track = nil; artwork = nil; artworkKey = ""
    }

    func playPause() { send("playpause") }
    func next() { send("next track") }
    func previous() { send("previous track") }

    private func poll() {
        guard active, !polling else { return }
        let running = Self.players.filter { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty }
        guard !running.isEmpty else {
            timer?.invalidate(); timer = nil
            if track != nil { track = nil; artwork = nil; artworkKey = "" }
            return
        }
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.poll() }
            timer?.tolerance = 1
        }
        polling = true
        let work = DispatchWorkItem { [weak self] in
            let tracks = running.compactMap(Self.query)
            let best = tracks.first(where: \.isPlaying) ?? tracks.first
            DispatchQueue.main.async { self?.polling = false; if self?.active == true { self?.apply(best) } }
        }
        pollWork = work; queue.async(execute: work)
    }

    private func apply(_ new: Track?) {
        if var previous = track, let new, !new.isPlaying {
            previous.polledAt = new.polledAt
            if previous == new { return }
        }
        track = new
        guard let new else { artwork = nil; artworkKey = ""; return }
        let key = "\(new.bundleID)|\(new.title)|\(new.album)"
        guard key != artworkKey else { return }
        artworkKey = key
        artworkTask?.cancel(); artworkTask = nil
        loadArtwork(for: new, key: key)
    }

    private func send(_ command: String) {
        guard let id = track?.bundleID else { return }
        queue.async { [weak self] in
            _ = Self.run("tell application id \"\(id)\" to \(command)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self?.poll() }
        }
    }

    private static func query(_ bundleID: String) -> Track? {
        // The `is running` guard stops AppleScript from relaunching a player that just quit.
        let source = """
        if application id "\(bundleID)" is running then
          tell application id "\(bundleID)"
            if player state is stopped then return ""
            set t to current track
            return (player state as text) & linefeed & (name of t) & linefeed & (artist of t) & linefeed & (album of t) & linefeed & ((duration of t) as text) & linefeed & ((player position) as text)
          end tell
        end if
        return ""
        """
        guard let text = run(source)?.stringValue, !text.isEmpty else { return nil }
        let parts = text.components(separatedBy: "\n")
        guard parts.count >= 6 else { return nil }
        let number = { (s: String) in Double(s.replacingOccurrences(of: ",", with: ".")) ?? 0 }
        var duration = number(parts[4])
        if bundleID == "com.spotify.client" { duration /= 1000 } // Spotify reports milliseconds
        return Track(bundleID: bundleID, title: parts[1], artist: parts[2], album: parts[3],
                     duration: duration, position: number(parts[5]), isPlaying: parts[0] == "playing", polledAt: Date())
    }

    private func loadArtwork(for track: Track, key: String) {
        queue.async { [weak self] in
            guard self != nil else { return }
            if track.bundleID == "com.spotify.client" {
                let raw = Self.run("tell application id \"com.spotify.client\" to get artwork url of current track")?.stringValue
                guard let raw, let url = URL(string: raw) else { return }
                DispatchQueue.main.async {
                    guard let self, self.active, self.artworkKey == key else { return }
                    self.artworkTask = URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
                        let image = data.flatMap(NSImage.init(data:))
                        DispatchQueue.main.async {
                            guard let self, self.active, self.artworkKey == key else { return }
                            self.artwork = image; self.artworkTask = nil
                        }
                    }
                    self.artworkTask?.resume()
                }
            } else {
                let image = (Self.run("tell application id \"com.apple.Music\" to get raw data of artwork 1 of current track")?.data).flatMap(NSImage.init(data:))
                DispatchQueue.main.async {
                    guard let self, self.active, self.artworkKey == key else { return }
                    self.artwork = image
                }
            }
        }
    }

    @discardableResult
    private static func run(_ source: String) -> NSAppleEventDescriptor? {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        return error == nil ? result : nil
    }
}
