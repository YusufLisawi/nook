import AppKit

/// Run as a command-line test binary. Uses only a private pasteboard and /tmp fixtures.
@main
struct ClipModelTests {
    static func main() throws {
        let board = NSPasteboard(name: .init("nook-clips-tests-" + UUID().uuidString))
        defer { board.releaseGlobally() }
        func put(_ text: String, type: NSPasteboard.PasteboardType = .string) {
            board.clearContents(); board.setString(text, forType: type)
        }
        func capture() -> ClipCapture.Snapshot? { ClipCapture.read(board, source: "Fixture App") }

        put("Hello, clipboard")
        let original = capture()!.entry
        assert(original.kind == .text && original.text == "Hello, clipboard")
        assert(capture()!.entry.fingerprint == original.fingerprint)
        put("https://example.com/docs")
        assert(capture()!.entry.kind == .link)
        put("https://example.com/docs", type: .URL)
        assert(capture()!.entry.kind == .link)
        put("#F09")
        assert(capture()!.entry.kind == .color)
        put("#12345678")
        assert(capture()!.entry.kind == .color)
        put(" \n ")
        assert(capture() == nil)
        put(String(repeating: "a", count: 1_048_577))
        assert(capture() == nil)

        for marker in ClipCapture.privateTypes {
            put("a secret")
            board.addTypes([.init(marker)], owner: nil)
            board.setString("", forType: .init(marker))
            assert(capture() == nil, marker)
        }
        let regular = NSPasteboardItem(), secret = NSPasteboardItem()
        regular.setString("public", forType: .string)
        secret.setString("secret", forType: .string)
        secret.setString("", forType: .init("org.nspasteboard.ConcealedType"))
        board.clearContents(); board.writeObjects([regular, secret])
        assert(capture() == nil, "A marker on any item protects the entire pasteboard")

        board.clearContents()
        let rich = NSAttributedString(string: "Rich becomes plain", attributes: [.font: NSFont.boldSystemFont(ofSize: 14)])
        let rtf = try rich.data(from: NSRange(location: 0, length: rich.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        board.setData(rtf, forType: .rtf)
        assert(capture()!.entry.text == "Rich becomes plain")
        board.clearContents(); board.writeObjects([NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 0.5)])
        assert(capture()!.entry.text == "#FF000080")

        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("clip-model-" + UUID().uuidString)
        try Data("fixture".utf8).write(to: fixture)
        defer { try? FileManager.default.removeItem(at: fixture) } // test-owned /tmp file only
        board.clearContents(); board.writeObjects([fixture as NSURL])
        assert(capture()!.entry.kind == .files && capture()!.entry.paths == [fixture.path])
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            board.clearContents()
            board.setData(type == .png ? bitmap.representation(using: .png, properties: [:])! : bitmap.tiffRepresentation!, forType: type)
            assert(capture()!.entry.kind == .image && capture()!.image != nil)
        }
        assert(ClipPreferences.ignores(name: "1PASSWORD", bundleID: "", list: ClipPreferences.defaultIgnoredApps))
        assert(ClipPreferences.ignores(name: "Localized", bundleID: "com.bitwarden.desktop", list: ClipPreferences.defaultIgnoredApps))
        assert(!ClipPreferences.ignores(name: "Safari", bundleID: "com.apple.Safari", list: ClipPreferences.defaultIgnoredApps))

        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 3600)!
        let now = ISO8601DateFormatter().date(from: "2026-10-21T12:03:00Z")!
        var screenshot = ClipEntry(kind: .screenshot, paths: ["/tmp/Screen Shot invoice.png"], date: now, source: "Preview")
        screenshot.ocrText = "Invoice total 42 euros"
        assert(ClipFilter("name:\"Screen Shot\" text:invoice date:today").matches(screenshot, now: now, calendar: calendar))
        assert(ClipFilter("date:2026-10-21 42").matches(screenshot, now: now, calendar: calendar))
        assert(!ClipFilter("date:yesterday").matches(screenshot, now: now, calendar: calendar))
        assert(!ClipFilter("date:2026-02-31").matches(screenshot, now: now, calendar: calendar))
        assert(!ClipFilter("date:garbage").matches(screenshot, now: now, calendar: calendar))
        assert(!ClipFilter("text:missing").matches(screenshot))
        assert(!ClipFilter("name:invoice text:missing").matches(screenshot))
        screenshot.date = now.addingTimeInterval(-86_400)
        assert(ClipFilter("date:yesterday").matches(screenshot, now: now, calendar: calendar))

        var old = original; old.date = now.addingTimeInterval(-40 * 86_400); old.pinned = true
        var fresh = original; fresh.id = "fresh"; fresh.date = now
        var another = fresh; another.id = "another"; another.date = now.addingTimeInterval(-1)
        let kept = ClipEntry.retained([fresh, another, old], days: 30, maxItems: 1, now: now)
        assert(kept.map(\.id) == [old.id, fresh.id], "Pins are exempt from age and capacity")
        var recopy = original; recopy.date = now; recopy.source = "New app"
        let merged = ClipEntry.inserting(recopy, into: [old])
        assert(merged.count == 1 && merged[0].id == old.id && merged[0].pinned && merged[0].date == now && merged[0].source == "New app")
        let roundTrip = try JSONDecoder().decode([ClipEntry].self, from: JSONEncoder().encode(merged))
        assert(roundTrip[0].text == merged[0].text)
        print("PASS: private pasteboard capture, privacy markers, rich text, links, colors, files, PNG/TIFF, ignored apps, filters, retention, dedupe, persistence")
    }
}
