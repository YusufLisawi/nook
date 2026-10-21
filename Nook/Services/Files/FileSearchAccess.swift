import AppKit
import SwiftUI

/// Published state is memory-only. All checks and user-authorized folder reads run
/// on a dedicated queue, never the main queue or the filename query queue.
final class FileSearchAccess: ObservableObject {
    static let shared = FileSearchAccess()
    static let changed = Notification.Name("nookFileSearchAccessChanged")
    @Published private(set) var policy = FileSearchAccessPolicy()
    @Published private(set) var requesting = false
    @Published private(set) var requested = false
    private let worker = DispatchQueue(label: "com.yusuf.nook.files.permissions", qos: .utility)
    private let defaults: UserDefaults
    private let home: String
    private var checking = false
    private var observer: NSObjectProtocol?

    init(defaults: UserDefaults = .standard, home: String = NSHomeDirectory()) {
        self.defaults = defaults; self.home = home
        policy = FileSearchAccessPolicy(home: home)
    }
    func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.refresh() }
        refresh()
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    func refresh() {
        guard !checking && !requesting else { return }
        checking = true
        worker.async { [weak self] in
            guard let self else { return }
            let next = FileSearchAccessPolicy.current(defaults: self.defaults, home: self.home)
            DispatchQueue.main.async { self.checking = false; self.publish(next) }
        }
    }
    /// Called only by native Allow Access buttons, never at launch or from a bridge.
    func allow() {
        guard !requesting else { return }
        requesting = true
        defaults.set(true, forKey: FileSearchAccessPolicy.requestedKey)
        worker.async { [weak self] in
            guard let self else { return }
            let before = FileSearchAccessPolicy.current(defaults: self.defaults, home: self.home)
            var granted = before.granted
            if !before.fullDiskAccess {
                for folder in before.requestable where !granted.contains(folder) {
                    // Opening the directory is the deliberate TCC request. A denied
                    // folder is never remembered as granted or retried at startup.
                    let fd = Darwin.open(folder, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
                    if fd >= 0 { Darwin.close(fd); granted.append(folder) }
                }
            }
            self.defaults.set(granted, forKey: FileSearchAccessPolicy.grantedKey)
            let next = FileSearchAccessPolicy(home: self.home, fullDiskAccess: before.fullDiskAccess, granted: granted, volumes: before.volumes)
            DispatchQueue.main.async { self.requesting = false; self.publish(next) }
        }
    }
    func revoke() {
        defaults.removeObject(forKey: FileSearchAccessPolicy.grantedKey)
        defaults.set(false, forKey: FileSearchAccessPolicy.requestedKey)
        publish(FileSearchAccessPolicy(home: home, fullDiskAccess: policy.fullDiskAccess, volumes: policy.volumes))
    }
    func openFullDiskAccess() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") else { return }
        NSWorkspace.shared.open(url)
    }
    private func publish(_ next: FileSearchAccessPolicy) {
        requested = defaults.bool(forKey: FileSearchAccessPolicy.requestedKey)
        guard next != policy else { return }
        policy = next
        NotificationCenter.default.post(name: Self.changed, object: self)
    }
}

struct FileSearchAccessRow: View {
    @ObservedObject private var access = FileSearchAccess.shared
    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "folder.badge.plus").foregroundStyle(.secondary)
            Text("Search Desktop, Documents and Downloads instantly").font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if access.requesting { ProgressView().controlSize(.mini) }
            Button("Allow access") { access.allow() }.buttonStyle(.plain).font(.system(size: 11, weight: .medium)).disabled(access.requesting)
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .help("Allow folder access (⇧⌘A)")
        }.padding(10).background(RoundedRectangle(cornerRadius: 9).fill(.white.opacity(0.065)))
            .padding(.vertical, 4)
            .contextMenu { Button("Open Full Disk Access…") { access.openFullDiskAccess() } }
    }
}
