import AppKit
import Combine

struct AICommandContext {
    static var captures = 0
    let application: NSRunningApplication? = nil
    static func capture() -> Self { captures += 1; return Self() }
}
extension AICommands {
    static var capturedRuns: [String] = []
    func run(_ id: String, fromNotch: Bool, context: AICommandContext?) { Self.capturedRuns.append(id) }
}
struct LauncherApplication: Identifiable {
    let path: String
    let name: String
    let bundleID: String
    var id: String { "app:" + path }
}
final class LauncherApplicationIndex: ObservableObject {
    static let shared = LauncherApplicationIndex()
    @Published var applications: [LauncherApplication] = []
    @Published var runningPaths = Set<String>()
    func start() {}
    static func disable() {}
}
final class NotchController {
    let viewModel = NotchViewModel(geometry: NotchGeometry())
    func openWithKeyboard() { viewModel.keyboard.engaged = true; viewModel.open() }
}
final class AgentService {
    struct Agent { var id: String }
    static let shared = AgentService()
    var agents: [Agent] = []
}
enum Shell {
    static var calls: [String] = []
    static var completions: [([String: Any]) -> Void] = []
    static func run(_ script: String, timeout: Double, completion: @escaping ([String: Any]) -> Void) {
        calls.append(script); completions.append(completion)
    }
}
enum Notifier { static func post(title: String, body: String) {} }
enum AIBrain {
    static func complete(provider: String, model: String, effort: String, prompt: String, onDelta: @escaping (String) -> Void) async throws -> String {
        onDelta("Reply: " + prompt)
        return "Reply: " + prompt
    }
}

// Inert File Search integration: launcher interaction tests never index or open user files.
final class FileNameIndex {
    static let changed = Notification.Name("nookFileIndexChanged")
}
enum LauncherFileSource {
    static var requests: [String] = []
    static var completion: ((Result<[LauncherEntry], Error>) -> Void)?
    static func search(_ text: String, client: String, reply: @escaping (Result<[LauncherEntry], Error>) -> Void) {
        requests.append(text); completion = reply; reply(.success([]))
    }
}
enum FileSearchService {
    static let shared = FileSearchServiceStub()
    final class FileSearchServiceStub {
        func cancel(_ key: String) {}
        func handle(_ action: String, args: [Any], reply: @escaping (Any?, String?) -> Void) { reply(nil, nil) }
    }
}
