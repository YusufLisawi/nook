import AppKit
import ApplicationServices
import SwiftUI

struct WindowManagementPane: View {
    @ObservedObject private var shortcuts = WindowShortcuts.shared
    @AppStorage(WindowShortcuts.almostScaleKey) private var almostScale = 0.9
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
                        LabeledContent(action.title) {
                            if let registration = ShortcutRegistry.shortcuts.first(where: { $0.id == "windows.\(action.rawValue)" }) {
                                SettingsShortcutRecorder(item: .registration(registration))
                            }
                        }
                        if let key = shortcuts.get(action), let warning = shortcuts.holdWarning(key) {
                            Text(warning).font(.caption).foregroundStyle(.secondary)
                        }
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
    }
}
