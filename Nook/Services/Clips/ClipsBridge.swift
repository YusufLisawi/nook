import AppKit
// Xcode 26 runs metadata extraction for app targets; linking this system framework
// lets that step produce an empty manifest without its missing-dependency warning.
import AppIntents
import Quartz
import SwiftUI

enum ClipsFeature {
    private static var registered = false
    static func reconcile() {
        guard !Features.shared.enabled("clipboard"), !Features.shared.enabled("screenshots") else { return }
        registered = false
        ClipsActions.shared.stop(); ClipsThumbnails.shared.clear(); ClipsPreview.shared.close()
        BridgeRegistry.unregister("clips"); SettingsRegistry.unregister("clipboard")
    }
    static func start() {
        guard !registered else { return }; registered = true
        ClipsActions.shared.start()
        SettingsRegistry.register(id: "clipboard", title: "Clipboard", symbol: "doc.on.clipboard.fill", tint: .orange, order: 44) { ClipboardSettingsPane() }
        BridgeRegistry.register("clips", functions: ["history", "screenshots", "status", "thumbnail", "copy", "paste", "open", "reveal", "delete", "pin", "unpin", "clear", "quickLook"]) { fn, args, _, reply in
            let historyEntries = Features.shared.enabled("clipboard") ? ClipboardHistory.shared.entries : []
            let captureEntries = Features.shared.enabled("screenshots") ? ScreenCaptureIndex.shared.entries : []
            let value = args.first as? String ?? ""
            let ok = { reply(NSNull(), nil) }
            do {
                switch fn {
                case "history":
                    let filter = ClipFilter(value)
                    reply(ClipEntry.sorted(historyEntries).filter { filter.matches($0) }.map(\.payload), nil)
                case "screenshots":
                    let filter = ClipFilter(value)
                    reply(ClipEntry.sorted(captureEntries).filter { filter.matches($0) }.map(\.payload), nil)
                case "status":
                    let clipboard = Features.shared.enabled("clipboard"), screenshots = Features.shared.enabled("screenshots")
                    reply(["enabled": clipboard, "ocr": screenshots && UserDefaults.standard.bool(forKey: ClipPreferences.ocr),
                           "indexing": screenshots && ScreenCaptureIndex.shared.scanning,
                           "folder": screenshots ? ScreenCaptureIndex.shared.folder.path : "",
                           "clipboardLoading": clipboard && !ClipboardHistory.shared.isReady,
                           "screenshotsLoading": screenshots && !ScreenCaptureIndex.shared.isReady,
                           "clipboardError": clipboard ? ClipboardHistory.shared.error ?? "" : "",
                           "screenshotsError": screenshots ? ScreenCaptureIndex.shared.error ?? "" : ""], nil)
                case "clear": if Features.shared.enabled("clipboard") { ClipboardHistory.shared.clear() }; ok()
                default:
                    guard let entry = (historyEntries + captureEntries).first(where: { $0.id == value }) else { throw ClipsError.missing }
                    switch fn {
                    case "thumbnail": ClipsThumbnails.shared.get(entry) { reply($0 ?? NSNull() as Any, $1) }
                    case "copy": ClipsActions.shared.copy(entry) { reply($0 == nil ? NSNull() : nil, $0?.localizedDescription) }
                    case "paste": ClipsActions.shared.paste(entry) { reply($0 == nil ? NSNull() : nil, $0?.localizedDescription) }
                    case "open":
                        if let url = entry.urls.first {
                            guard NSWorkspace.shared.open(url) else { throw ClipsError.noFile }
                        } else if entry.kind == .link, let url = URL(string: entry.text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                            guard NSWorkspace.shared.open(url) else { throw ClipsError.noFile }
                        } else { throw ClipsError.noFile }
                        ok()
                    case "reveal":
                        guard !entry.urls.isEmpty else { throw ClipsError.noFile }
                        NSWorkspace.shared.activateFileViewerSelecting(entry.urls); ok()
                    case "quickLook": try ClipsPreview.shared.show(entry); ok()
                    case "pin", "unpin":
                        if entry.kind == .screenshot || entry.kind == .recording { try ScreenCaptureIndex.shared.setPinned(value, fn == "pin") }
                        else { try ClipboardHistory.shared.setPinned(value, fn == "pin") }
                        ok()
                    case "delete":
                        let completion: (Error?) -> Void = { reply($0 == nil ? NSNull() : nil, $0?.localizedDescription) }
                        if entry.kind == .screenshot || entry.kind == .recording { ScreenCaptureIndex.shared.delete(value, completion: completion) }
                        else { ClipboardHistory.shared.delete(value, completion: completion) }
                    default: reply(nil, "Unknown clips action: \(fn)")
                    }
                }
            } catch { reply(nil, error.localizedDescription) }
        }
    }
}

/// Remembers the external app even after clicking the notch makes Nook frontmost.
final class ClipsActions {
    static let shared = ClipsActions()
    private var target: NSRunningApplication?
    private var observer: NSObjectProtocol?
    private var pasteInProgress = false
    private let io = DispatchQueue(label: "com.yusuf.nook.clips.actions", qos: .userInitiated)

    func start() {
        remember(NSWorkspace.shared.frontmostApplication)
        observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            self?.remember(note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
        }
    }

    func stop() {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observer = nil; target = nil
    }

    private func remember(_ app: NSRunningApplication?) {
        if let app, app.processIdentifier != ProcessInfo.processInfo.processIdentifier, app.activationPolicy == .regular { target = app }
    }

    func copy(_ entry: ClipEntry, completion: @escaping (Error?) -> Void) {
        io.async {
            var imageData: Data?
            if entry.kind == .image || entry.kind == .screenshot {
                if let url = entry.urls.first { imageData = NSImage(contentsOf: url)?.tiffRepresentation }
                guard imageData != nil else { return DispatchQueue.main.async { completion(ClipsError.clipboard) } }
            }
            let image = imageData
            DispatchQueue.main.async {
                let board = NSPasteboard.general
                if !entry.paths.isEmpty && !entry.urls.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) {
                    return completion(ClipsError.clipboard)
                }
                LinkCatcher.ignoreClipboardUntil = Date().addingTimeInterval(1.5)
                board.clearContents()
                let written: Bool
                if let image { written = board.setData(image, forType: .tiff) }
                else if !entry.paths.isEmpty { written = board.writeObjects(entry.urls as [NSURL]) }
                else { written = board.setString(entry.text, forType: .string) }
                completion(written ? nil : ClipsError.clipboard)
            }
        }
    }

    func paste(_ entry: ClipEntry, completion: @escaping (Error?) -> Void) {
        guard !pasteInProgress else { return completion(ClipsError.unavailable) }
        guard AXIsProcessTrusted() else { return completion(ClipsError.accessibility) }
        remember(NSWorkspace.shared.frontmostApplication)
        guard let app = target, !app.isTerminated else { return completion(ClipsError.noTarget) }
        pasteInProgress = true
        copy(entry) { error in
            if let error { self.pasteInProgress = false; return completion(error) }
            let count = NSPasteboard.general.changeCount
            Services.shared.closeNotches()
            app.activate(options: [])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                defer { self.pasteInProgress = false }
                guard !app.isTerminated, NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else {
                    return completion(ClipsError.noTarget)
                }
                guard NSPasteboard.general.changeCount == count else { return completion(ClipsError.clipboard) }
                guard let source = CGEventSource(stateID: .combinedSessionState),
                      let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
                      let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else { return completion(ClipsError.accessibility) }
                down.flags = .maskCommand
                up.flags = .maskCommand
                down.post(tap: .cghidEventTap)
                up.post(tap: .cghidEventTap)
                completion(nil)
            }
        }
    }
}

private final class ClipsPreview: NSObject, QLPreviewPanelDataSource {
    static let shared = ClipsPreview()
    private var urls: [URL] = []

    func close() {
        if QLPreviewPanel.sharedPreviewPanelExists() { QLPreviewPanel.shared()?.orderOut(nil) }
        urls = []
    }

    func show(_ entry: ClipEntry) throws {
        guard !entry.urls.isEmpty else { throw ClipsError.noFile }
        urls = entry.urls
        guard let panel = QLPreviewPanel.shared() else { throw ClipsError.noFile }
        panel.dataSource = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem { urls[index] as NSURL }
}
