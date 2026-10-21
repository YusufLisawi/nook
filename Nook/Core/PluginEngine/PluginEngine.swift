import AppKit
import Combine

/// The app hosts presentation and capabilities; feature code belongs in separately supervised helpers.
final class PluginEngine {
    static let shared = PluginEngine()
    private(set) var manifests: [String: PluginManifestV2] = [:]
    private var helpers: [String: PluginHelperProcess] = [:]
    private var visible: [String: String] = [:] // web host id → visible plugin (multiple displays)
    private var bag = Set<AnyCancellable>()
    private var revisions: [String: Date] = [:]
    private var started = false
    private var demanded = Set<String>()
    private var busy = Set<String>()
    private var warmed = Set<String>()
    private var idleStops: [String: DispatchWorkItem] = [:]
    private var registryRevision = -1

    @MainActor static func start() {
        let engine = shared
        guard !engine.started else { return }; engine.started = true
        BridgeRegistry.register("native", functions: ["call"]) { fn, args, id, reply in
            engine.webCall(id: id, method: "native." + fn, args: args, vm: nil, reply: reply)
        }
        BridgeRegistry.register("host", functions: ["call"]) { _, args, id, reply in
            engine.webCall(id: id, method: "host.call", args: args, vm: nil, reply: reply)
        }
        Services.shared.plugins.$tabs.combineLatest(Services.shared.plugins.$revision)
            .receive(on: RunLoop.main).sink { _ in
                engine.reconcile()
                Task { @MainActor in PluginAutomaticUpdates.shared.reconcile() }
            }.store(in: &engine.bag)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .merge(with: NotificationCenter.default.publisher(for: .nookPluginPermissionsChanged), NotificationCenter.default.publisher(for: .nookFeaturesChanged))
            .receive(on: RunLoop.main).sink { _ in
                engine.reconcile()
                Task { @MainActor in PluginAutomaticUpdates.shared.reconcile() }
            }.store(in: &engine.bag)
        NotificationCenter.default.publisher(for: .nookPluginEvent).receive(on: RunLoop.main).sink { note in
            guard let event = note.userInfo?["event"] as? String, !event.hasPrefix("native:") else { return }
            let target = note.userInfo?["plugin"] as? String
            if let target, ["hotkey","action","actionAlternate","beforeAction"].contains(event), engine.manifests[target] != nil {
                engine.wake(target)
            }
            for (id, helper) in engine.helpers where target == nil || target == id {
                helper.notify("host.event", ["event": event, "data": note.userInfo?["payload"] ?? NSNull()])
            }
        }.store(in: &engine.bag)
        PluginAutomaticUpdates.start()
    }

    func reconcile() {
        guard started else { return }
        let revision = Services.shared.plugins.revision
        if revision != registryRevision {
            registryRevision = revision
            Array(manifests.keys).forEach(stop)
        }
        var current: [String: PluginManifestV2] = [:]
        for tab in Services.shared.plugins.tabs {
            guard let dir = tab.dir else { continue }
            do {
                let manifest = try PluginManifestV2(directory: dir)
                guard manifest.apiVersion == 2 else { continue }
                if !PluginPermissions.shared.approved(manifest) { _ = PluginDailyMigration.adopt(manifest) }
                current[tab.id] = manifest
                let stamp = (try? dir.appendingPathComponent("plugin.json").resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                if revisions[tab.id] != stamp { stop(tab.id); revisions[tab.id] = stamp }
            } catch { PluginLog.write(tab.id, level: "error", message: error.localizedDescription) }
        }
        Set(manifests.keys).subtracting(current.keys).forEach(stop)
        manifests = current
        PluginContributions.shared.reconcileConsumers()
        for id in Array(helpers.keys) where !shouldRun(id) { stop(id) }
        for (id, manifest) in manifests where Features.shared.tabEnabled(id) {
            guard PluginPermissions.shared.approved(manifest) else {
                if manifest.native?.background == true || visible.values.contains(id) {
                    Task { @MainActor in if await PluginPermissions.shared.review(manifest) { self.reconcile() } }
                }
                continue
            }
            PluginContributions.shared.install(manifest)
            if manifest.native?.warmup == true, warmed.insert(id).inserted { wake(id) }
            if shouldRun(id), helpers[id] == nil { launch(manifest) }
        }
        PluginContributions.shared.reconcile(active: Set(manifests.values.filter { Features.shared.tabEnabled($0.id) && PluginPermissions.shared.approved($0) }.map(\.id)))
    }

    private func shouldRun(_ id: String) -> Bool {
        guard let manifest = manifests[id], let native = manifest.native,
              Features.shared.tabEnabled(id), PluginPermissions.shared.approved(manifest) else { return false }
        return native.background || visible.values.contains(id) || demanded.contains(id) || busy.contains(id)
    }

    private func launch(_ manifest: PluginManifestV2) {
        let id = manifest.id
        let helper = PluginHelperProcess(manifest: manifest, dataDirectory: Self.dataDirectory(id), host: { method, params, reply in
            DispatchQueue.main.async { self.hostCall(id: id, method: method, params: params, vm: nil, reply: reply) }
        }, event: { event, payload in
            DispatchQueue.main.async {
                if event == "stopped" { PluginHostAPI.shared.stop(id); if Services.shared.pluginActivity?.pluginID == id { Services.shared.pluginActivity = nil } }
                PluginEvents.emit("native:" + event,payload,to:id)
            }
        }, log: { PluginLog.write(id, level: "helper", message: $0) })
        helpers[id] = helper; helper.start()
    }

    func stop(_ id: String) {
        idleStops.removeValue(forKey:id)?.cancel(); demanded.remove(id); busy.remove(id); warmed.remove(id)
        helpers.removeValue(forKey: id)?.stop()
        PluginContributions.shared.remove(id)
        PluginHostAPI.shared.stop(id)
        if Services.shared.pluginActivity?.pluginID == id { Services.shared.pluginActivity = nil }
    }
    func wake(_ id: String) {
        guard let manifest = manifests[id], manifest.native != nil, Features.shared.tabEnabled(id), PluginPermissions.shared.approved(manifest) else { return }
        demanded.insert(id)
        if helpers[id] == nil { launch(manifest) }
        keepAlive(id,enabled:busy.contains(id))
    }
    func keepAlive(_ id: String, enabled: Bool) {
        idleStops.removeValue(forKey:id)?.cancel()
        if enabled { busy.insert(id); return }
        busy.remove(id)
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.busy.contains(id), !self.visible.values.contains(id), self.manifests[id]?.native?.background != true else { return }
            self.demanded.remove(id)
            // Suspend the process, retaining host-owned declarative shortcuts/settings.
            self.helpers.removeValue(forKey:id)?.stop()
            PluginHostAPI.shared.stop(id)
        }
        idleStops[id] = work; DispatchQueue.main.asyncAfter(deadline:.now()+30,execute:work)
    }
    func shutdown() { Array(manifests.keys).forEach(stop) }
    static func dataDirectory(_ id: String) -> URL { Services.supportDir.appendingPathComponent("Data/\(id)", isDirectory: true) }

    func setVisible(owner: String, plugin: String?) {
        guard visible[owner] != plugin else { return }
        let previous = visible[owner]
        visible[owner] = plugin
        if let previous { keepAlive(previous,enabled:busy.contains(previous)) }
        reconcile()
    }
    func releasePage(_ id: String) {
        guard !busy.contains(id) else { return }
        if manifests[id]?.native?.background != true,
           !Features.shared.tabEnabled(id) || !visible.values.contains(id) {
            PluginHostAPI.shared.stop(id)
        }
    }
    func removeOwner(_ owner: String) { let previous = visible.removeValue(forKey: owner); if let previous { keepAlive(previous,enabled:busy.contains(previous)) }; reconcile() }

    /// The web host calls this BEFORE its legacy switch, so v2 cannot escape the capability gate.
    func intercept(id: String, directory: URL?, method: String, args: [Any], vm: NotchViewModel?, reply: @escaping PluginHelperProcess.Reply) -> Bool {
        guard let directory else { return false }
        do {
            let manifest = try PluginManifestV2(directory: directory)
            guard manifest.apiVersion == 2 else { return false }
            manifests[id] = manifest
            webCall(id: id, method: method, args: args, vm: vm, reply: reply)
        } catch { reply(nil, error.localizedDescription) }
        return true
    }

    func webCall(id: String, method: String, args: [Any], vm: NotchViewModel?, reply: @escaping PluginHelperProcess.Reply) {
        if method == "host.call" {
            hostCall(id: id, method: args.first as? String ?? "", params: args.dropFirst().first ?? [:], vm: vm, reply: reply)
        } else if method == "native.call" {
            guard let manifest = manifests[id], PluginPermissions.shared.approved(manifest), Features.shared.tabEnabled(id) else { return reply(nil, "Plugin access is not approved or the plugin is disabled.") }
            wake(id)
            reconcile()
            guard let helper = helpers[id] else { return reply(nil, "Helper unavailable. Open this plugin’s tab or enable background mode.") }
            var parameters = args.dropFirst().first as? [String: Any] ?? [:]
            if let vm { parameters["__context"] = String(describing: ObjectIdentifier(vm)) }
            helper.call(args.first as? String ?? "", params: parameters) { value, error in DispatchQueue.main.async { reply(value, error) } }
        } else {
            hostCall(id: id, method: method, params: PluginHostAPI.parameters(method, args), vm: vm, reply: reply)
        }
    }

    func hostCall(id: String, method: String, params: Any, vm: NotchViewModel?, reply: @escaping PluginHelperProcess.Reply) {
        let method = method.hasPrefix("host.") ? String(method.dropFirst(5)) : method
        do {
            guard let manifest = manifests[id], Features.shared.tabEnabled(id) else { throw PluginEngineError("Plugin disabled or missing.") }
            try PluginCapabilityPolicy.check(method, manifest: manifest, grant: PluginPermissions.shared.grants[id])
            PluginHostAPI.shared.call(id: id, method: method, params: params as? [String: Any] ?? [:], manifest: manifest, vm: vm, reply: reply)
        } catch { reply(nil, error.localizedDescription) }
    }

    static let javascript = """
    (() => {
      const n = window.nook;
      if (n.native) n.native.on = (event, cb) => n.on('native:' + event, cb);
      if (n.plugin.apiVersion !== 2) return;
      const methods = {
        notch: ['open'], clipboard: ['watch'], files: ['read','write','open','reveal','trash'],
        ai: ['complete'], selection: ['get','paste'], secrets: ['get','set','remove'],
        windows: ['frontmost'], hotkeys: ['register','unregister'], launcher: ['items','answers'],
        notifications: ['post'], jobs: ['register','unregister'], network: ['fetch','open']
      };
      for (const [ns, names] of Object.entries(methods)) {
        n[ns] = n[ns] || {};
        for (const name of names) n[ns][name] = (params = {}) => n.host.call(ns + '.' + name, params);
      }
    })();
    """
}
