import Foundation

/// Block the previous Dictation helper's destructive paste while Store updates are in flight.
enum PluginLegacyPasteSafety {
    static func error(pluginID: String, parameters: [String: Any]) -> String? {
        guard pluginID == "dictation", parameters["insertion"] as? Bool != true else { return nil }
        return "Update the Dictation plugin to insert text safely. Your transcript is saved in history."
    }
}
