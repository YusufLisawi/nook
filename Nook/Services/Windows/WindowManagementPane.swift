import AppKit
import ApplicationServices
import SwiftUI

struct WindowManagementPane: View {
    @ObservedObject private var shortcuts = WindowShortcuts.shared
    @AppStorage(WindowShortcuts.almostScaleKey) private var almostScale = 0.9
    @StateObject private var recorder = WindowShortcutRecorder()
    @State private var accessibilityAllowed = AXIsProcessTrusted()

    var body: some View {
        Form {
            Section {
                LabeledContent("Accessibility", value: accessibilityAllowed ? "Allowed" : "Required")
                Button("Open Accessibility Settings…") { WindowManager.shared.openPrivacy() }
                HStack {
                    Text("Almost Maximize")
                    Slider(value: $almostScale, in: 0.5...0.98, step: 0.01)
                        .accessibilityLabel("Almost Maximize size")
                    Text(almostScale, format: .percent.precision(.fractionLength(0))).monospacedDigit().frame(width: 40)
                }
            } footer: {
                Text("Layouts respect the menu bar and Dock. Display moves preserve relative size and position. Restore returns to the frame before a series of Nook layout changes.")
            }
            Section {
                Text("Desktop moves follow the window. Enable Move left/right a space in macOS Keyboard Shortcuts → Mission Control. Normal windows with a draggable title bar are supported; full screen, Split View, All Desktops and custom title bars may prevent a move.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(WindowAction.groups, id: \.self) { group in
                Section(group) {
                    ForEach(WindowAction.allCases.filter { $0.group == group }) { action in
                        WindowShortcutRow(action: action, recorder: recorder)
                    }
                }
            }
            Section {
                Text("Shortcuts start unassigned. Click a recorder, then press a shortcut with ⌃, ⌥ or ⌘. Escape cancels; Delete clears. Conflicts with Nook and known macOS shortcuts are blocked. Shortcuts in other apps cannot be detected. Using ⌃⌥ plus a key cancels the default dictation hold.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            accessibilityAllowed = AXIsProcessTrusted()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            recorder.stop()
        }
        .onDisappear { recorder.stop() }
    }
}

private struct WindowShortcutRow: View {
    let action: WindowAction
    @ObservedObject var recorder: WindowShortcutRecorder
    @ObservedObject private var shortcuts = WindowShortcuts.shared

    private var recording: Bool { recorder.action == action }

    private var warning: String? {
        if recorder.errorAction == action, let rejected = recorder.rejected { return rejected }
        guard let hotkey = shortcuts.get(action) else { return nil }
        let conflicts = shortcuts.conflicts(hotkey, for: action)
        if !conflicts.isEmpty { return "Unavailable: also used by \(conflicts.joined(separator: ", "))." }
        return shortcuts.holdWarning(hotkey)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(action.title)
                Spacer()
                Button(recording ? "Press keys…" : (shortcuts.get(action)?.display ?? "Add shortcut")) {
                    if recording { recorder.stop() } else { recorder.start(action) }
                }
                .font(.system(size: 12, design: .rounded))
                .accessibilityLabel("\(action.title) shortcut")
                .help("Escape cancels. Delete clears. Include Control, Option or Command.")
            }
            if let warning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .onDisappear { if recording { recorder.stop() } }
    }
}

/// One recorder per pane: selecting another row first releases the previous recorder's event monitor.
private final class WindowShortcutRecorder: ObservableObject {
    @Published private(set) var action: WindowAction?
    @Published private(set) var errorAction: WindowAction?
    @Published private(set) var rejected: String?
    private var monitor: Any?
    private var wasPaused = false

    func start(_ action: WindowAction) {
        stop()
        rejected = nil
        errorAction = action
        wasPaused = Services.shared.dictation.hotkeys.paused
        Services.shared.dictation.hotkeys.paused = true
        self.action = action
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            switch event.keyCode {
            case 53: stop()
            case 51, 117:
                WindowShortcuts.shared.set(action, nil)
                stop()
            default:
                guard let hotkey = TabHotkeys.make(from: event) else {
                    rejected = "Include Control, Option or Command with the key."
                    return nil
                }
                let conflicts = WindowShortcuts.shared.conflicts(hotkey, for: action)
                if conflicts.isEmpty {
                    WindowShortcuts.shared.set(action, hotkey)
                    rejected = nil
                } else {
                    rejected = "\(hotkey.display) is used by \(conflicts.joined(separator: ", ")). Choose another shortcut."
                }
                stop()
            }
            return nil
        }
    }

    func stop() {
        guard action != nil else { return }
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        action = nil
        Services.shared.dictation.hotkeys.paused = wasPaused
    }

    deinit {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            Services.shared.dictation.hotkeys.paused = wasPaused
        }
    }
}
