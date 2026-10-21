import AppKit
import Foundation

@main
struct TabStateTests {
    static func key(_ code: UInt16, _ characters: String = "", _ flags: NSEvent.ModifierFlags = [], owner: String = "one") -> Bool {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                                    characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
        return FileSearchTabState.handle(event, owner: owner)
    }
    static func payload(_ names: [String]) -> [String: Any] {
        ["results": names.map { ["path": "/tmp/" + $0, "name": $0, "category": "pdf", "kind": "PDF", "added": 1_800_000_000.0,
                                  "modified": 1_800_000_000.0, "size": 42] as [String: Any] }, "gathering": false]
    }
    static func spin(until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(2)
        while !condition() && Date() < deadline { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.025)) }
        precondition(condition(), "scheduled preview did not run")
    }
    static func main() {
        let service = FileSearchService.shared, state = FileSearchTabState()
        state.start(owner: "one")
        service.searches.last!.reply(payload(["a.pdf", "b.pdf"]))
        precondition(state.current?.name == "a.pdf")
        precondition(key(125) && state.current?.name == "b.pdf")
        precondition(key(126) && state.current?.name == "a.pdf")
        precondition(!key(125, owner: "other"), "per-notch isolation")
        _ = key(36)
        precondition(service.calls.last!.0 == "open")
        _ = key(36, "\r", .command)
        precondition(service.calls.last!.0 == "reveal")
        _ = key(49, " ")
        precondition(service.calls.last!.0 == "quickLook")
        precondition(!key(49, " ", .shift), "Shift Space reaches native text editing")
        _ = key(8, "c", .command)
        precondition(service.calls.last!.0 == "copyPath")
        _ = key(8, "c", [.command, .option])
        precondition(service.calls.last!.0 == "copyName")
        _ = key(40, "k", .command)
        precondition(state.actions)
        _ = key(125)
        precondition(state.actionIndex == 1)
        _ = key(36)
        precondition(service.calls.last!.0 == "reveal" && !state.actions)
        let beforeTrash = service.calls.count
        _ = key(51, "\u{7f}", .command)
        precondition(state.confirmingPath == "/tmp/a.pdf" && service.calls.count == beforeTrash, "Trash needs explicit confirmation")
        _ = key(53)
        precondition(state.confirmingPath == nil && service.calls.count == beforeTrash)
        _ = key(51, "\u{7f}", .command); _ = key(125)
        precondition(state.confirmingPath == nil, "selection changes cancel confirmation")
        _ = key(51, "\u{7f}", .command); _ = key(36)
        precondition(service.calls.last!.0 == "trash" && (service.calls.last!.1[1] as? [String: Bool])?["confirm"] == true)
        service.searches.last!.reply(payload(["a.pdf", "b.pdf"]))
        state.query = "a"
        let pending = service.searches.last!
        let count = service.calls.count
        _ = key(36)
        precondition(service.calls.count == count, "don't open old rows while a replacement query is pending")
        state.query = "b"
        service.searches.last!.reply(payload(["b.pdf"]))
        pending.reply(payload(["a.pdf"]))
        precondition(state.current?.name == "b.pdf", "stale search response cannot replace newer rows")
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        precondition(service.previews.isEmpty, "no inline previews (removed: they re-rendered on every selection)")
        state.query = "a"; service.searches.last!.reply(payload(["a.pdf"]))
        let rows = state.results.map(\.path)
        service.searches.last!.reply(payload(["a.pdf"]))
        precondition(state.results.map(\.path) == rows, "an identical streamed update leaves the list untouched")
        let originalKind = state.kind
        _ = key(48)
        precondition(state.kind != originalKind)
        _ = key(48, "\t", .shift)
        precondition(state.kind == originalKind)
        service.searches.last!.reply(payload([]).merging(["error": "No permission"]) { _, new in new })
        precondition(state.results.isEmpty && state.error == "No permission")
        state.query = ""; service.searches.last!.reply(payload([]))
        precondition(!key(53), "empty-query Escape returns to the notch's close route")
        state.stop()
        precondition(!service.canceled.isEmpty && !key(125))
        print("PASS: native per-notch keyboard routing, arrows, open/reveal, Quick Look, copy path/name, local actions, kind cycling, Trash confirmation/cancel, pending/stale search safety, no inline previews, no redundant list refreshes, loading/error/empty state and cancellation; no app or GUI launched")
    }
}
