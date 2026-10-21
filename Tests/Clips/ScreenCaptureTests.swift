import AppKit

// The command-line harness never initializes Services or the application's pasteboard.
enum PluginEvents { static func emit(_ event: String, _ payload: Any, to pluginID: String?) {} }
enum ClipsError: Error { case missing }

@main
struct ScreenCaptureTests {
    static func wait(_ condition: () -> Bool, timeout: TimeInterval = 25) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        assert(condition(), "Timed out waiting for the background index")
    }

    static func main() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("nook-capture-tests-" + UUID().uuidString)
        let folder = root.appendingPathComponent("Captures"), cache = root.appendingPathComponent("Cache")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) } // test-owned /tmp only
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 900, pixelsHigh: 240, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 900, height: 240).fill()
        ("MAGENTA INVOICE 4821" as NSString).draw(at: NSPoint(x: 35, y: 80), withAttributes: [.font: NSFont.systemFont(ofSize: 48), .foregroundColor: NSColor.black])
        NSGraphicsContext.restoreGraphicsState()
        let png = bitmap.representation(using: .png, properties: [:])!
        let shot = folder.appendingPathComponent("Screenshot 2026-10-21 at 13.03.00.png")
        let unrelated = folder.appendingPathComponent("ordinary-photo.png")
        try png.write(to: shot); try png.write(to: unrelated)
        let denied = ScreenCaptureIndex(folderProvider: { folder }, ocrEnabled: { false })
        denied.start(directory: root.appendingPathComponent("DeniedCache", isDirectory: true))
        wait { denied.isReady }
        assert(denied.entries.isEmpty && denied.error != nil && !denied.scanning, "startup without access must not watch or scan the screenshot folder")
        var chosenFolder = folder
        let index = ScreenCaptureIndex(folderProvider: { chosenFolder }, ocrEnabled: { true })
        index.start(directory: cache, accessAllowed: { _ in true })
        wait { index.isReady && index.entries.first?.ocrText != nil }
        assert(index.entries.count == 1 && index.entries[0].urls.first?.resolvingSymlinksInPath() == shot.resolvingSymlinksInPath())
        assert(index.entries[0].ocrText!.localizedCaseInsensitiveContains("MAGENTA"))
        assert(ClipFilter("text:invoice").matches(index.entries[0]))
        let id = index.entries[0].id
        try index.setPinned(id, true)
        wait { FileManager.default.fileExists(atPath: cache.appendingPathComponent("screenshots.json").path) }

        let second = folder.appendingPathComponent("Screen Shot watched.png")
        try png.write(to: second)
        wait { index.entries.count == 2 }
        assert(index.entries.first(where: { $0.id == id })?.pinned == true)
        assert(ScreenCaptureIndex.isCapture(folder.appendingPathComponent("Screen Recording sample.mov")))

        let restored = ScreenCaptureIndex(folderProvider: { folder }, ocrEnabled: { false })
        restored.start(directory: cache, accessAllowed: { _ in true })
        wait { restored.isReady }
        assert(restored.entries.first(where: { $0.id == id })?.ocrText?.contains("MAGENTA") == true)
        assert(restored.entries.first(where: { $0.id == id })?.pinned == true)

        // Simulate an external deletion without moving a test fixture into the user's Trash.
        try FileManager.default.removeItem(at: shot)
        wait { index.entries.count == 1 }
        assert(!index.entries.contains(where: { $0.id == id }))

        chosenFolder = root.appendingPathComponent("Missing folder")
        index.refresh()
        wait { index.error != nil }
        assert(index.entries.isEmpty, "A folder override cannot expose stale captures from the old folder")
        chosenFolder = folder
        index.refresh()
        wait { index.error == nil && index.entries.count == 1 }
        print("PASS: initial scan, folder watcher, filename detection, Vision OCR, text search, pin/cache restore, external deletion, folder changes and error recovery")
    }
}
