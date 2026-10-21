import Foundation

enum KeyboardWebSupport {
    static var script: String {
        Bundle.main.url(forResource: "nook-keyboard", withExtension: "js", subdirectory: "NookUI")
            .flatMap { try? String(contentsOf: $0) } ?? ""
    }
}
