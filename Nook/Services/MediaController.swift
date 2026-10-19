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

    func start() {
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.poll() }
    }

    func playPause() { send("playpause") }
    func next() { send("next track") }
    func previous() { send("previous track") }

    private func poll() {
        let running = Self.players.filter { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty }
        guard !running.isEmpty else {
            if track != nil { track = nil; artwork = nil; artworkKey = "" }
            return
        }
        queue.async { [weak self] in
            let tracks = running.compactMap(Self.query)
            let best = tracks.first(where: \.isPlaying) ?? tracks.first
            DispatchQueue.main.async { self?.apply(best) }
        }
    }

    private func apply(_ new: Track?) {
        track = new
        guard let new else { artwork = nil; artworkKey = ""; return }
        let key = "\(new.bundleID)|\(new.title)|\(new.album)"
        guard key != artworkKey else { return }
        artworkKey = key
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
            var image: NSImage?
            if track.bundleID == "com.spotify.client" {
                if let s = Self.run("tell application id \"com.spotify.client\" to get artwork url of current track")?.stringValue,
                   let url = URL(string: s), let data = try? Data(contentsOf: url) {
                    image = NSImage(data: data)
                }
            } else if let data = Self.run("tell application id \"com.apple.Music\" to get raw data of artwork 1 of current track")?.data {
                image = NSImage(data: data)
            }
            DispatchQueue.main.async {
                guard let self, self.artworkKey == key else { return }
                self.artwork = image
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
