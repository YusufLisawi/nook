import Foundation
typealias PluginDefaults = UserDefaults
enum PluginRuntime {
    static let data = FileManager.default.temporaryDirectory.appendingPathComponent("nook-unit-" + UUID().uuidString)
    static let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath + "/store/plugins/launcher")
}
