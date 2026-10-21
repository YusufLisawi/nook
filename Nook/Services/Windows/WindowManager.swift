import AppKit
import SwiftUI

final class WindowManager {
    static let shared = WindowManager()
    var closeNotches: () -> Void = {}
    private var targets = WindowTargets<ManagedWindow>()
    private var running = false
    private var lastError = ""
    private let spaces = WindowSpaces()
    private struct SavedFrame {
        let element: AXUIElement
        let original: CGRect
        var lastApplied: CGRect
    }
    private var saved: [SavedFrame] = []

    private init() {}

    func start() {
        UserDefaults.standard.register(defaults: [WindowShortcuts.almostScaleKey: 0.9])
        SettingsRegistry.register(id: "windows", title: "Window Management", symbol: "macwindow", tint: .teal, order: 35) {
            WindowManagementPane()
        }
        BridgeRegistry.register("windows", functions: ["state", "apply", "openPrivacy", "openSettings"]) { [weak self] fn, args, _, reply in
            guard let self else { reply(nil, "Window management is unavailable."); return }
            switch fn {
            case "state": reply(self.state(context: args.first as? String), nil)
            case "apply":
                guard let id = args.first as? String, let action = WindowAction(rawValue: id) else {
                    reply(nil, "Unknown window action.")
                    return
                }
                Task { @MainActor in
                    do {
                        let context = args.dropFirst().first as? String
                        try await self.apply(action, fromNotch: true, context: context)
                        reply(self.state(context: context), nil)
                    } catch {
                        self.showFailure(error.localizedDescription)
                        reply(nil, error.localizedDescription)
                    }
                }
            case "openPrivacy": self.openPrivacy(); reply(NSNull(), nil)
            case "openSettings":
                (NSApp.delegate as? AppDelegate)?.showSettings(pane: "windows")
                reply(NSNull(), nil)
            default: reply(nil, "Unknown windows call: \(fn)")
            }
        }
    }

    /// Called synchronously before a closed notch changes tabs or takes keyboard focus.
    /// Never retarget an existing capture just because a plugin asks for state.
    func captureBeforeNotchOpen(_ notch: NotchViewModel) {
        guard !running else { return }
        let context = Self.context(for: notch)
        do {
            let window = try ManagedWindow.focused()
            _ = try window.frame()
            targets.capture(window, for: context)
        } catch {
            targets.capture(nil, error: error.localizedDescription, for: context)
        }
    }

    private static func context(for notch: NotchViewModel) -> String {
        String(describing: ObjectIdentifier(notch))
    }

    /// Bind the registered API to its host notch, including a lazily created web view's first state call.
    /// A pinned notch on another display must keep its own pre-open target.
    func bridgeContext(for notch: NotchViewModel?) -> String {
        guard let notch else { return "" }
        let context = Self.context(for: notch)
        return """
        (() => {
          const api = window.nook.windows, state = api.state, apply = api.apply;
          api.state = () => state("\(context)");
          api.apply = action => apply(action, "\(context)");
        })();
        """
    }

    func handleShortcut(key: Int64, modifiers: CGEventFlags, from notch: NotchViewModel? = nil) -> Bool {
        guard let action = WindowShortcuts.shared.action(key: key, modifiers: modifiers) else { return false }
        let context = notch.map(Self.context)
        Task { @MainActor in
            do { try await self.apply(action, fromNotch: context != nil, context: context) }
            catch { self.showFailure(error.localizedDescription) }
        }
        return true
    }

    func state(context: String? = nil) -> [String: Any] {
        let capture = targets.get(context)
        let captured = capture?.window
        let trusted = AXIsProcessTrusted()
        let available = trusted && captured.flatMap { try? $0.frame() } != nil
        let target: Any = available ? (captured?.application.localizedName ?? "Window") : NSNull()
        return [
            "trusted": trusted, "target": target, "busy": running, "lastError": lastError,
            "message": available ? "" : (trusted ? (capture?.error.isEmpty == true ? "The window closed. Focus a window and reopen the notch." : capture?.error ?? "Focus a window, then open the notch.") : "Allow Nook in Accessibility to move windows."),
            "actions": WindowAction.allCases.map { action -> [String: Any] in
                let hotkey = WindowShortcuts.shared.get(action)
                let conflicts = hotkey.map { WindowShortcuts.shared.conflicts($0, for: action) } ?? []
                return ["id": action.rawValue, "title": action.title, "group": action.group,
                        "shortcut": hotkey?.display ?? "", "conflict": conflicts.joined(separator: ", ")]
            }
        ]
    }

    @MainActor
    private func apply(_ action: WindowAction, fromNotch: Bool, context: String? = nil) async throws {
        guard !running else { throw WindowManagementError("A window move is in progress. Try again in a moment.") }
        guard AXIsProcessTrusted() else {
            throw WindowManagementError("Allow Nook in System Settings → Privacy & Security → Accessibility.")
        }
        let window: ManagedWindow
        if fromNotch {
            let capture = targets.get(context)
            guard let captured = capture?.window else {
                throw WindowManagementError(capture?.error ?? "Focus a window, then reopen the notch.")
            }
            window = captured
        } else {
            window = try ManagedWindow.focused()
        }
        let before = try window.frame()
        let screens = NSScreen.screens.sorted {
            if $0.frame.minX != $1.frame.minX { return $0.frame.minX < $1.frame.minX }
            if $0.frame.minY != $1.frame.minY { return $0.frame.minY > $1.frame.minY }
            let key = NSDeviceDescriptionKey("NSScreenNumber")
            return (($0.deviceDescription[key] as? NSNumber)?.uint32Value ?? 0) < (($1.deviceDescription[key] as? NSNumber)?.uint32Value ?? 0)
        }
        let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
        let bounds = screens.map { WindowGeometry.quartzFrame($0.frame, primaryHeight: primaryHeight) }
        let areas = screens.map { WindowGeometry.quartzFrame($0.visibleFrame, primaryHeight: primaryHeight) }
        guard let sourceIndex = WindowGeometry.screenIndex(for: before, screens: bounds), !areas[sourceIndex].isEmpty else {
            throw WindowManagementError("No usable display is available.")
        }
        running = true
        PluginEvents.emit("windows", NSNull())
        defer {
            running = false
            PluginEvents.emit("windows", NSNull())
        }
        if action.isDesktop {
            closeNotches()
            try await Task.sleep(nanoseconds: 200_000_000)
            try await spaces.move(window, screen: screens[sourceIndex], area: areas[sourceIndex], step: action == .previousDesktop ? -1 : 1)
            lastError = ""
            return
        }

        let destination: CGRect
        let destinationArea: CGRect
        if action.isDisplay {
            guard screens.count > 1 else { throw WindowManagementError("Connect another display to move this window.") }
            let step = action == .previousDisplay ? -1 : 1
            let next = (sourceIndex + step + screens.count) % screens.count
            destinationArea = areas[next]
            destination = WindowGeometry.transferred(before, from: areas[sourceIndex], to: destinationArea)
        } else if action == .restore {
            guard let entry = saved.first(where: { CFEqual($0.element, window.element) }) else {
                throw WindowManagementError("No saved frame for this window yet. Apply a Nook layout first.")
            }
            let originalScreen = WindowGeometry.screenIndex(for: entry.original, screens: bounds) ?? sourceIndex
            destinationArea = areas[originalScreen]
            destination = WindowGeometry.fitted(entry.original, in: destinationArea)
        } else {
            destinationArea = areas[sourceIndex]
            destination = WindowGeometry.layout(action, frame: before, area: destinationArea,
                                                almostScale: UserDefaults.standard.double(forKey: WindowShortcuts.almostScaleKey))
        }

        if action != .restore { remember(window, frame: before) }
        do {
            try window.setFrame(destination, area: destinationArea)
        } catch {
            // A resize can partially succeed before an app reports its minimum size. Keep Restore usable.
            updateLastFrame(window)
            throw error
        }
        if action == .restore { saved.removeAll { CFEqual($0.element, window.element) } }
        else { updateLastFrame(window) }
        lastError = ""
    }

    private func remember(_ window: ManagedWindow, frame: CGRect) {
        if let index = saved.firstIndex(where: { CFEqual($0.element, window.element) }) {
            let last = saved[index].lastApplied
            // A manual move starts a fresh sequence. Small app rounding differences do not.
            if abs(last.minX - frame.minX) < 8, abs(last.minY - frame.minY) < 8,
               abs(last.width - frame.width) < 8, abs(last.height - frame.height) < 8 { return }
            saved.remove(at: index)
        }
        saved.append(SavedFrame(element: window.element, original: frame, lastApplied: frame))
        if saved.count > 64 { saved.removeFirst(saved.count - 64) }
    }

    private func updateLastFrame(_ window: ManagedWindow) {
        if let index = saved.firstIndex(where: { CFEqual($0.element, window.element) }), let frame = try? window.frame() {
            saved[index].lastApplied = frame
        }
    }

    func openPrivacy() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func showFailure(_ message: String) {
        // Hotkeys do not open a focus-stealing panel. Show a short status and retain the reason for the plugin.
        lastError = message
        PluginEvents.emit("windowsError", message)
        Services.shared.pluginActivity = PluginActivity(pluginID: "windows", text: "Move failed", symbol: "exclamationmark.triangle", color: "#ff453a")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            if Services.shared.pluginActivity?.pluginID == "windows" { Services.shared.pluginActivity = nil }
        }
    }
}
