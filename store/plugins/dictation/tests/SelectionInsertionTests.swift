import CoreFoundation
import Foundation

@main enum SelectionInsertionTests {
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        guard value() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }

    static func insert(_ text: String, at range: CFRange, transcript: String) -> String {
        let insertion = SelectionInsertion.insertionPoint(range)!
        let pasted = SelectionInsertion.pasteboardText(transcript, after: false, prefix: " ")
        return (text as NSString).replacingCharacters(in: NSRange(location: insertion.location, length: insertion.length), with: pasted)
    }

    static func main() {
        let text = "Hello world"
        let captured = SelectionInsertion.capture(selected: "", fullText: text, range: CFRange(location: 5, length: 0))
        check(captured.selection == text, "AI Commands still capture the whole field when nothing is selected")
        check(captured.commandRange?.location == 0 && captured.commandRange?.length == 11, "AI Commands retain the select-all range")
        check(captured.originalRange?.location == 5 && captured.originalRange?.length == 0, "The original caret is preserved independently")
        check(insert(text, at: captured.originalRange!, transcript: "dictation") == "Hello dictation world", "Insert at a middle caret without replacing text")
        check(insert("hello world", at: CFRange(location: 6, length: 5), transcript: "again") == "hello world again", "An existing selection is preserved and insertion follows it")
        check(insert("Hi 😀 there", at: CFRange(location: 5, length: 0), transcript: "friend") == "Hi 😀 friend there", "Caret offsets use UTF-16 for emoji")
        check(insert("", at: CFRange(location: 0, length: 0), transcript: "hello") == " hello", "A space precedes dictation in an empty field")
        let chosen = SelectionInsertion.capture(selected: "world", fullText: text, range: CFRange(location: 6, length: 5))
        check(chosen.selection == "world" && chosen.commandRange?.length == 5, "AI Commands keep explicit selections")
        check(SelectionInsertion.matches(CFRange(location: 5, length: 0), point: CFRange(location: 5, length: 0)), "An already correct caret needs no AX range write")
        check(!SelectionInsertion.matches(CFRange(location: 5, length: 1), point: CFRange(location: 5, length: 0)), "A selection must not be mistaken for a caret")
        check(!SelectionInsertion.matches(nil, point: CFRange(location: 5, length: 0)), "An unverifiable current range must not pass")
        check(SelectionInsertion.insertionPoint(nil) == nil, "Unknown cursor must fail closed")
        check(SelectionInsertion.insertionPoint(CFRange(location: -1, length: 0)) == nil, "Invalid cursor must fail closed")
        check(SelectionInsertion.insertionPoint(CFRange(location: Int.max, length: 1)) == nil, "Overflow must fail closed")
        check(SelectionInsertion.pasteboardText("answer", after: true, prefix: "") == "\n\nanswer", "AI Commands' existing paste-after formatting is unchanged")
        check(PluginLegacyPasteSafety.error(pluginID: "dictation", parameters: ["text": "old"]) != nil, "Older Dictation helpers must not invoke destructive paste")
        check(PluginLegacyPasteSafety.error(pluginID: "dictation", parameters: ["insertion": true]) == nil, "Updated Dictation may use safe insertion")
        check(PluginLegacyPasteSafety.error(pluginID: "commands", parameters: ["text": "replacement"]) == nil, "AI Commands keep their existing replacement behavior")
        print("PASS: Dictation preserves existing text and inserts at the original UTF-16 caret; AI Commands retain their selection behavior.")
    }
}
