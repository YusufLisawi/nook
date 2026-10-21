import AppKit
import SwiftUI

final class NotchViewModel: ObservableObject {
    @Published var isOpen = true
    let web = Web()
    final class Web { let keyboardID = "test-notch" }
}

final class FileSearchService {
    struct Search { let text: String; let options: [String: Any]; let reply: ([String: Any]) -> Void }
    static let shared = FileSearchService()
    var searches: [Search] = []
    var calls: [(String, [Any])] = []
    var previews: [(String, (Any?, String?) -> Void)] = []
    var canceled: [String] = []
    func search(_ text: String, options: [String: Any], pluginID: String, update: @escaping ([String: Any]) -> Void) {
        searches.append(Search(text: text, options: options, reply: update))
    }
    func cancel(_ key: String) { canceled.append(key) }
    func handle(_ fn: String, args: [Any], reply: @escaping (Any?, String?) -> Void) {
        if fn == "preview" { previews.append((args[0] as! String, reply)); return }
        calls.append((fn, args)); reply(nil, nil)
    }
}
