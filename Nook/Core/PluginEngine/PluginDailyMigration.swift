import Foundation

/// One-time adoption of the exact first-party packages that replace previously built-in daily tools.
/// A matching ID, receipt, or permission list alone never establishes trust.
enum PluginDailyMigration {
  static let ids: Set<String> = ["commands", "agents", "dictation", "mixer"]
  static let digests: [String: String] = [
    "commands": "bd6e9b479509d4166a0b7324b598bd6bc787555c8f9b389b6308c3025882bec3",
    "agents": "11733976069ce821274b12dbd24d456a7b483edd84f702d68933f0f7b2bda96f",
    "dictation": "ced7ac3e72f2dcec15b8e8df3b28dcd1272f0b1e7e5b56c967ebfa1ce004ba48",
    "mixer": "20574a925baf7c49cb02c1e5ecfcfc74833d6443e56cfbeaebdddea6d3f349fc",
  ]
  static func captureLegacyInstall() {
    let defaults = UserDefaults.standard
    guard defaults.object(forKey: "dailyPlugins.legacyInstall") == nil else { return }
    let previous =
      defaults.bool(forKey: FeatureLifecycle.migrationKey)
      || defaults.object(forKey: "aiCommandsSeed") != nil
      || ["ai-commands.json", "agents.json", "Dictation"].contains {
        FileManager.default.fileExists(atPath: Services.supportDir.appendingPathComponent($0).path)
      }
    defaults.set(previous, forKey: "dailyPlugins.legacyInstall")
  }
  static func needsInstall(_ id: String) -> Bool {
    ids.contains(id) && !UserDefaults.standard.bool(forKey: "dailyPlugins.installed." + id)
  }
  static func installed(_ id: String) {
    if ids.contains(id) { UserDefaults.standard.set(true, forKey: "dailyPlugins.installed." + id) }
  }
  static func adopt(_ manifest: PluginManifestV2) -> Bool {
    guard ids.contains(manifest.id),
      let expected = digests[manifest.id],
      (try? PluginStorePackage.packageSHA256(manifest.directory)) == expected,
      let data = try? Data(
        contentsOf: manifest.directory.appendingPathComponent(PluginStoreClient.receiptName)),
      let receipt = try? JSONDecoder().decode(PluginStoreReceipt.self, from: data),
      receipt.repository == PluginStoreClient.repository,
      receipt.sha256 == expected
    else { return false }
    UserDefaults.standard.set(true, forKey: "dailyPlugins.trusted." + manifest.id)
    guard UserDefaults.standard.bool(forKey: "dailyPlugins.legacyInstall"),
      !UserDefaults.standard.bool(forKey: "dailyPlugins.adopted." + manifest.id)
    else { return false }
    PluginPermissions.shared.adoptLegacy(manifest)
    UserDefaults.standard.set(true, forKey: "dailyPlugins.adopted." + manifest.id)
    return true
  }
  static func sharedAccount(_ id: String, key: String) -> Bool {
    guard ["commands", "dictation"].contains(id),
      UserDefaults.standard.bool(forKey: "dailyPlugins.trusted." + id),
      ["groq_api_key", "openai_api_key"].contains(key),
      let manifest = PluginEngine.shared.manifests[id],
      let data = try? Data(
        contentsOf: manifest.directory.appendingPathComponent(PluginStoreClient.receiptName)),
      let receipt = try? JSONDecoder().decode(PluginStoreReceipt.self, from: data),
      receipt.id == id, receipt.repository == PluginStoreClient.repository,
      let digest = receipt.sha256,
      (try? PluginStorePackage.packageSHA256(manifest.directory)) == digest
    else { return false }
    return true
  }
}
