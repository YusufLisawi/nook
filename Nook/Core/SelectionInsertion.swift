import CoreFoundation
import Foundation

/// Keep the real cursor separate from AI Commands' optional select-all fallback.
struct SelectionCapturePlan {
    let selection: String?
    let commandRange: CFRange?
    let originalRange: CFRange?
}

enum SelectionInsertion {
    static func capture(selected: String?, fullText: String?, range: CFRange?) -> SelectionCapturePlan {
        if let selected, !selected.isEmpty {
            return SelectionCapturePlan(selection: selected, commandRange: range, originalRange: range)
        }
        if let fullText, !fullText.isEmpty {
            return SelectionCapturePlan(selection: fullText,
                                        commandRange: CFRange(location: 0, length: (fullText as NSString).length),
                                        originalRange: range)
        }
        return SelectionCapturePlan(selection: nil, commandRange: range, originalRange: range)
    }

    /// A selection is collapsed to its end; a caret remains exactly where it was.
    static func insertionPoint(_ range: CFRange?) -> CFRange? {
        guard let range, range.location >= 0, range.length >= 0 else { return nil }
        let end = range.location.addingReportingOverflow(range.length)
        guard !end.overflow else { return nil }
        return CFRange(location: end.partialValue, length: 0)
    }

    static func matches(_ current: CFRange?, point: CFRange) -> Bool {
        current?.location == point.location && current?.length == point.length
    }

    static func pasteboardText(_ text: String, after: Bool, prefix: String) -> String {
        (after ? "\n\n" : "") + prefix + text
    }
}
