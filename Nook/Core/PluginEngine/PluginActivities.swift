import Foundation

/// Value-only presentation arbitration; feature policy supplies priority and lifetime.
enum PluginActivities {
  private static var values: [String: (activity: PluginActivity, priority: Int, sequence: UInt64)] =
    [:]
  private static var sequence: UInt64 = 0
  static func set(_ activity: PluginActivity, priority: Int) {
    sequence &+= 1
    values[activity.pluginID] = (activity, max(0, min(100, priority)), sequence)
    publish()
  }
  static func level(_ id: String, _ value: Float) {
    guard var entry = values[id] else { return }
    entry.activity.level = value
    values[id] = entry
    if Services.shared.pluginActivity?.pluginID == id {
      Services.shared.pluginActivity = entry.activity
    }
  }
  static func remove(_ id: String) {
    values.removeValue(forKey: id)
    publish()
  }
  private static func publish() {
    Services.shared.pluginActivity =
      values.values.max {
        $0.priority == $1.priority ? $0.sequence < $1.sequence : $0.priority < $1.priority
      }?.activity
  }
}
