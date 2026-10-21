import AppKit
import Combine

// Actual engine/supervisor, isolated host services. This executable is not Nook and has no audio/AX calls.
struct PluginActivity { var pluginID: String; var text: String; var level: Float? = nil }
struct TabItem { let id: String; let dir: URL? }
final class TestPlugins {
    @Published var tabs: [TabItem] = []
    @Published var revision = 0
}
final class Services {
    static let shared = Services()
    static var supportDir: URL { URL(fileURLWithPath:CommandLine.arguments[1]) }
    let plugins = TestPlugins()
    var pluginActivity: PluginActivity?
    struct Activity { let pluginID: String }
}
final class Features {
    static let shared = Features()
    var on = true
    func tabEnabled(_ id: String) -> Bool { on }
}
enum BridgeRegistry {
    static func register(_ namespace: String, functions: [String], handler: @escaping (String,[Any],String,@escaping PluginHelperProcess.Reply)->Void) {}
}
final class PluginPermissions {
    static let shared = PluginPermissions()
    var grants: [String:PluginPermissionGrant] = ["demand":.init(permissions:[],native:true,fileScopes:[])]
    func approved(_ manifest: PluginManifestV2) -> Bool { true }
    @MainActor func review(_ manifest: PluginManifestV2) async -> Bool { true }
}
enum PluginDailyMigration { static func adopt(_ manifest: PluginManifestV2) -> Bool { false } }
final class PluginAutomaticUpdates {
    static let shared = PluginAutomaticUpdates()
    static func start() {}
    func reconcile() {}
}
final class PluginContributions {
    static let shared = PluginContributions()
    var installed = Set<String>()
    func install(_ manifest: PluginManifestV2) { installed.insert(manifest.id) }
    func remove(_ id: String) { installed.remove(id) }
    func reconcileConsumers() {}
    func reconcile(active: Set<String>) { installed.formIntersection(active) }
}
final class PluginHostAPI {
    static let shared = PluginHostAPI()
    var stopped = 0
    func stop(_ id: String) { stopped += 1 }
    func call(id:String,method:String,params:[String:Any],manifest:PluginManifestV2,vm:NotchViewModel?,reply:@escaping PluginHelperProcess.Reply) { reply(NSNull(),nil) }
    static func parameters(_ method:String,_ args:[Any])->[String:Any] { [:] }
}
final class NotchViewModel {}
enum PluginLog { static func write(_ id:String,level:String,message:String) {} }
extension Notification.Name {
    static let nookFeaturesChanged = Notification.Name("test.features")
    static let nookPluginPermissionsChanged = Notification.Name("test.permissions")
    static let nookPluginEvent = Notification.Name("test.event")
}
enum PluginEvents {
    static var events: [(String,Any)] = []
    static func emit(_ event:String,_ payload:Any,to pluginID:String?=nil) {
        events.append((event,payload))
        var info:[String:Any] = ["event":event,"payload":payload]
        if let pluginID { info["plugin"] = pluginID }
        NotificationCenter.default.post(name:.nookPluginEvent,object:nil,userInfo:info)
    }
}
@main enum DemandTests {
    @MainActor static func wait(_ condition:()->Bool,seconds:Double=5) async {
        let end = Date().addingTimeInterval(seconds)
        while !condition() { precondition(Date()<end,"Demand test timed out"); try? await Task.sleep(nanoseconds:20_000_000) }
    }
    @MainActor static func main() async throws {
        let root = Services.supportDir, package = root.appendingPathComponent("demand")
        try FileManager.default.createDirectory(at:package,withIntermediateDirectories:true)
        try Data(#"{"id":"demand","name":"Demand","apiVersion":2,"native":{"run":["python3","helper.py"],"warmup":true}}"#.utf8).write(to:package.appendingPathComponent("plugin.json"))
        try Data("""
        import sys,json
        for line in sys.stdin:
            message=json.loads(line)
            if message.get('method')=='host.event':
                print(json.dumps({'jsonrpc':'2.0','method':'observed','params':message['params']}),flush=True)
        """.utf8).write(to:package.appendingPathComponent("helper.py"))
        PluginEngine.start()
        Services.shared.plugins.tabs = [.init(id:"demand",dir:package)]
        let engine = PluginEngine.shared
        engine.reconcile()
        await wait { PluginEvents.events.contains { $0.0 == "native:ready" } }
        let pid = (PluginEvents.events.first { $0.0 == "native:ready" }!.1 as! [String:Any])["pid"] as! Int32
        precondition(kill(pid,0)==0)
        engine.keepAlive("demand",enabled:true)
        engine.setVisible(owner:"page",plugin:"demand")
        engine.removeOwner("page")
        let stopped = PluginHostAPI.shared.stopped
        engine.releasePage("demand")
        precondition(PluginHostAPI.shared.stopped == stopped,"Evicting a page must not stop leased capture")
        engine.keepAlive("demand",enabled:false)
        await wait({ kill(pid,0) != 0 },seconds:34)
        precondition(PluginContributions.shared.installed.contains("demand"),"Idle process exit must retain host contributions")
        let count = PluginEvents.events.filter { $0.0 == "native:ready" }.count
        PluginEvents.emit("hotkey",["id":"hold","phase":"pressed"],to:"demand")
        await wait { PluginEvents.events.filter { $0.0 == "native:ready" }.count > count }
        await wait { PluginEvents.events.contains { $0.0 == "native:observed" } }
        Features.shared.on = false; engine.reconcile()
        precondition(!PluginContributions.shared.installed.contains("demand"))
        let before = PluginEvents.events.filter { $0.0 == "native:ready" }.count
        PluginEvents.emit("hotkey",["id":"hold"],to:"demand")
        try? await Task.sleep(nanoseconds:100_000_000)
        precondition(PluginEvents.events.filter { $0.0 == "native:ready" }.count == before)
        PluginActivities.set(.init(pluginID:"agents",text:"Working"),priority:0)
        PluginActivities.set(.init(pluginID:"dictation",text:"Recording"),priority:100)
        PluginActivities.level("dictation",0.4)
        PluginActivities.set(.init(pluginID:"commands",text:"Thinking"),priority:0)
        precondition(Services.shared.pluginActivity?.pluginID == "dictation" && Services.shared.pluginActivity?.level == 0.4,"Recording priority and meter must survive other activities")
        PluginActivities.remove("dictation")
        precondition(Services.shared.pluginActivity?.pluginID == "commands","Clearing a high priority activity must restore remaining work")
        PluginActivities.remove("commands"); PluginActivities.remove("agents")
        engine.shutdown()
        print("PASS actual Engine + supervisor: one warmup, leased-page eviction, 30-second process exit (PID absent), retained hotkeys, cold wake/event delivery, disable; no Nook/capture/input")
    }
}
