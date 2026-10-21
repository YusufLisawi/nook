import AppKit
import Quartz

/// Joins the originating panel's responder chain for the lifetime of Quick Look control.
final class FileSearchQuickLook: NSResponder, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    private var url: URL?
    private weak var origin: NSWindow?
    private var previousResponder: NSResponder?

    func close() {
        if url != nil, let panel = QLPreviewPanel.sharedPreviewPanelExists() ? QLPreviewPanel.shared() : nil { panel.orderOut(nil) }
        url = nil; restoreChain()
    }

    func show(_ url: URL) {
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible, self.url == url {
            let window = origin
            panel.orderOut(nil); restoreChain(); window?.makeKey(); return
        }
        self.url = url
        if origin == nil, let window = NSApp.keyWindow {
            origin = window
            previousResponder = window.nextResponder
            nextResponder = previousResponder
            window.nextResponder = self
        }
        panel.level = .floating
        panel.updateController()
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
    }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
        restoreChain()
    }
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { url == nil ? 0 : 1 }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! { url as NSURL? }
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown, event.keyCode == 49 || event.keyCode == 53 else { return false }
        let window = origin
        panel.orderOut(nil)
        restoreChain()
        window?.makeKey()
        return true
    }
    private func restoreChain() {
        if origin?.nextResponder === self { origin?.nextResponder = previousResponder }
        origin = nil; previousResponder = nil; nextResponder = nil
    }
}
