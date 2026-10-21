import Foundation

/// Deliberately referenced only by its string ID in tests: proves drop-in discovery survives optimized linking.
@objc(NookTestDropInProvider)
final class TestDropInProvider: LauncherAnswerModule, LauncherAnswerProvider {
    let id = "zz-discovery-test"
    func answer(for query: String, context: LauncherAnswerContext) -> LauncherAnswer? { nil }
}
