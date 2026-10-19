import Foundation
import Network

/// Whole-machine proxy: macOS system proxy → 127.0.0.1 forwarder → upstream (adds the login, which macOS can't).
final class ProxyService: ObservableObject {
    struct Proxy: Codable, Identifiable, Equatable {
        var id: String
        var name: String
        var scheme: String
        var host: String
        var port: Int
        var user: String
        var pass: String
    }

    private struct Stored: Codable {
        var proxies: [Proxy]
        var activeID: String?
    }

    static let localPort: UInt16 = 18080
    private static let bypass = ["localhost", "127.0.0.1", "*.local", "169.254/16", "10/8", "192.168/16"]

    @Published private(set) var proxies: [Proxy] = []
    @Published private(set) var activeID: String?

    private let forwarder = ProxyForwarder()
    private let queue = DispatchQueue(label: "nook.proxy.system")
    private var fileURL: URL { Services.supportDir.appendingPathComponent("proxies.json") }

    init() {
        if let data = try? Data(contentsOf: fileURL), let stored = try? JSONDecoder().decode(Stored.self, from: data) {
            proxies = stored.proxies
            activeID = stored.activeID
        }
    }

    var active: Proxy? { proxies.first { $0.id == activeID } }

    // MARK: Lifecycle

    /// Reconnect the last proxy, or clean up a system proxy left pointing at a dead forwarder.
    func restoreOnLaunch() {
        if let active {
            connect(active.id) { _ in }
        } else {
            queue.async { Self.setSystemProxy(nil, services: Self.allServiceNames()) }
        }
    }

    /// Must run before quitting, or the Mac is left pointing at a closed local port.
    func shutdown() {
        guard activeID != nil else { return }
        Self.setSystemProxy(nil, services: Self.allServiceNames())
        forwarder.stop()
    }

    // MARK: Actions

    func connect(_ id: String, completion: @escaping (String?) -> Void) {
        guard let proxy = proxies.first(where: { $0.id == id }) else { return completion("Unknown proxy") }
        let isSOCKS = proxy.scheme.hasPrefix("socks")
        // Already routing through our forwarder? Switching is just a new upstream — no system changes, instant.
        let viaForwarder = { (p: Proxy?) in p.map { !$0.scheme.hasPrefix("socks") } ?? false }
        let systemAlreadySet = viaForwarder(active) && !isSOCKS && forwarder.isRunning
        do {
            if isSOCKS {
                forwarder.stop()
            } else {
                forwarder.upstream = .init(host: proxy.host, port: proxy.port, user: proxy.user, pass: proxy.pass)
                try forwarder.start(port: Self.localPort)
                forwarder.dropConnections() // new session = new exit IP
            }
        } catch {
            return completion("Couldn't start the local proxy: \(error.localizedDescription)")
        }
        activeID = id
        save()
        if systemAlreadySet {
            broadcast()
            return completion(nil)
        }
        queue.async {
            Self.setSystemProxy(isSOCKS ? .socks(proxy.host, proxy.port) : .http("127.0.0.1", Int(Self.localPort)))
            DispatchQueue.main.async {
                self.broadcast()
                completion(nil)
            }
        }
    }

    func disconnect(completion: @escaping () -> Void = {}) {
        activeID = nil
        save()
        queue.async {
            Self.setSystemProxy(nil) // the services in use — fast
            DispatchQueue.main.async {
                self.forwarder.stop()
                self.broadcast()
                completion()
            }
            Self.setSystemProxy(nil, services: Self.allServiceNames()) // then sweep the rest
        }
    }

    func add(_ text: String) -> (added: Int, bad: Int) {
        let tokens = text.split(whereSeparator: { $0.isWhitespace || $0 == "," }).map(String.init).filter { !$0.hasPrefix("#") }
        let parsed = tokens.compactMap(Self.parse)
        proxies.append(contentsOf: parsed)
        save()
        broadcast()
        return (parsed.count, tokens.count - parsed.count)
    }

    func remove(_ id: String) {
        if id == activeID { disconnect() }
        proxies.removeAll { $0.id == id }
        save()
        broadcast()
    }

    func rename(_ id: String, to name: String) {
        guard let i = proxies.firstIndex(where: { $0.id == id }), !name.isEmpty else { return }
        proxies[i].name = name
        save()
        broadcast()
    }

    // MARK: Bridge

    func handle(_ fn: String, args: [Any], reply: @escaping (Any?, String?) -> Void) {
        let str = { (i: Int) in i < args.count ? args[i] as? String ?? "" : "" }
        switch fn {
        case "list": reply(listPayload(), nil)
        case "add":
            let r = add(str(0))
            reply(["added": r.added, "bad": r.bad], nil)
        case "remove": remove(str(0)); reply(listPayload(), nil)
        case "rename": rename(str(0), to: str(1)); reply(listPayload(), nil)
        case "connect": connect(str(0)) { error in reply(error == nil ? self.listPayload() : nil, error) }
        case "disconnect": disconnect { reply(self.listPayload(), nil) }
        case "ip": Self.publicIP { reply($0, $0 == nil ? "Couldn't check the IP" : nil) }
        default: reply(nil, "Unknown proxy call: \(fn)")
        }
    }

    func listPayload() -> [String: Any] {
        [
            "proxies": proxies.map { ["id": $0.id, "name": $0.name, "scheme": $0.scheme, "host": $0.host, "port": $0.port, "hasAuth": !$0.user.isEmpty] },
            "activeId": activeID ?? NSNull(),
        ]
    }

    private func broadcast() { PluginEvents.emit("proxy", listPayload()) }

    private func save() {
        if let data = try? JSONEncoder().encode(Stored(proxies: proxies, activeID: activeID)) {
            try? data.write(to: fileURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        }
    }

    static func publicIP(completion: @escaping ([String: Any]?) -> Void) {
        guard let url = URL(string: "https://ipwho.is/") else { return completion(nil) }
        URLSession(configuration: .ephemeral).dataTask(with: URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)) { data, _, _ in
            guard let data, let d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], d["ip"] != nil else { return completion(nil) }
            completion([
                "ip": d["ip"] ?? "", "city": d["city"] ?? "", "country": d["country"] ?? "",
                "countryCode": d["country_code"] ?? "", "flag": (d["flag"] as? [String: Any])?["emoji"] ?? "",
            ])
        }.resume()
    }

    // MARK: Parsing (same formats as the Hop extension)

    static func parse(_ raw: String) -> Proxy? {
        var line = raw.trimmingCharacters(in: .whitespaces)
        var scheme = "http"
        if let r = line.range(of: #"^(https?|socks4|socks5)://"#, options: [.regularExpression, .caseInsensitive]) {
            scheme = line[r].dropLast(3).lowercased()
            line.removeSubrange(r)
        }
        var user = "", pass = "", hostPort = line
        if let at = line.lastIndex(of: "@") {
            let cred = line[..<at]
            if let c = cred.firstIndex(of: ":") {
                user = String(cred[..<c])
                pass = String(cred[cred.index(after: c)...])
            } else {
                user = String(cred)
            }
            hostPort = String(line[line.index(after: at)...])
        }
        let parts = hostPort.trimmingCharacters(in: CharacterSet(charactersIn: "/")).split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        if !line.contains("@"), parts.count >= 4 {
            user = parts[2]
            pass = parts[3...].joined(separator: ":")
        }
        guard parts.count >= 2, !parts[0].isEmpty, let port = Int(parts[1]), (1...65535).contains(port) else { return nil }
        let cred = "\(user):\(pass)"
        let country = cred.range(of: #"(?<=country-)[a-zA-Z]{2}"#, options: .regularExpression).map { cred[$0].uppercased() }
        let session = cred.range(of: #"(?<=session-)[a-zA-Z0-9]+"#, options: .regularExpression).map { String(cred[$0]) }
        let nice = [country, session].compactMap { $0 }.joined(separator: " · ")
        return Proxy(id: UUID().uuidString, name: nice.isEmpty ? "\(parts[0]):\(port)" : nice, scheme: scheme, host: parts[0], port: port, user: user, pass: pass)
    }

    // MARK: System proxy (networksetup)

    private enum SystemProxy {
        case http(String, Int)
        case socks(String, Int)
    }

    /// `networksetup` commits one change at a time and fails if run in parallel, so keep it sequential —
    /// and only touch services that are actually up (usually just Wi-Fi), which makes it ~0.5 s instead of seconds.
    private static func setSystemProxy(_ target: SystemProxy?, services: [String]? = nil) {
        for service in services ?? activeServices() {
            switch target {
            case let .http(host, port):
                networksetup("-setwebproxy", service, host, String(port), "off")
                networksetup("-setsecurewebproxy", service, host, String(port), "off")
                networksetup(["-setproxybypassdomains", service] + bypass)
            case let .socks(host, port):
                networksetup("-setwebproxystate", service, "off")
                networksetup("-setsecurewebproxystate", service, "off")
                networksetup("-setsocksfirewallproxy", service, host, String(port), "off")
                networksetup(["-setproxybypassdomains", service] + bypass)
            case nil:
                networksetup("-setwebproxystate", service, "off")
                networksetup("-setsecurewebproxystate", service, "off")
                networksetup("-setsocksfirewallproxystate", service, "off")
            }
        }
    }

    /// Services whose interface is currently up (from `scutil --nwi`); falls back to all of them.
    private static func activeServices() -> [String] {
        let up = Set((run("/usr/sbin/scutil", ["--nwi"]).components(separatedBy: "\n")
            .first { $0.hasPrefix("Network interfaces:") }?
            .dropFirst("Network interfaces:".count)
            .split(separator: " ").map(String.init)) ?? [])
        let all = networkServices()
        let active = all.filter { up.contains($0.device) }.map(\.name)
        return active.isEmpty ? all.map(\.name) : active
    }

    /// Every service that has a proxy pointing at our forwarder or is on — used to clean up fully.
    private static func allServiceNames() -> [String] { networkServices().map(\.name) }

    /// Enabled hardware services (skips disabled "*" ones and VPN entries, which have no proxy settings).
    private static func networkServices() -> [(name: String, device: String)] {
        var services: [(String, String)] = []
        var name: String?
        for line in networksetup("-listnetworkserviceorder").components(separatedBy: "\n") {
            if let r = line.range(of: #"^\(\d+\) "#, options: .regularExpression) {
                name = String(line[r.upperBound...])
            } else if let n = name, let r = line.range(of: #"Device: ([^)]+)\)"#, options: .regularExpression) {
                let device = line[r].dropFirst("Device: ".count).dropLast()
                services.append((n, String(device)))
                name = nil
            }
        }
        return services
    }

    private static func run(_ path: String, _ args: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    @discardableResult
    private static func networksetup(_ args: String...) -> String { networksetup(args) }

    @discardableResult
    private static func networksetup(_ args: [String]) -> String { run("/usr/sbin/networksetup", args) }
}

/// Minimal HTTP proxy on 127.0.0.1 that forwards every connection to the upstream proxy with Proxy-Authorization added.
final class ProxyForwarder {
    struct Upstream {
        var host: String
        var port: Int
        var user: String
        var pass: String

        var authHeader: String? {
            user.isEmpty ? nil : "Proxy-Authorization: Basic " + Data("\(user):\(pass)".utf8).base64EncodedString()
        }
    }

    var upstream: Upstream?
    var isRunning: Bool { listener != nil }
    private var listener: NWListener?
    private var sessions: [ObjectIdentifier: Session] = [:]
    private let queue = DispatchQueue(label: "nook.proxy.forwarder")

    func start(port: UInt16) throws {
        guard listener == nil else { return }
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
        dropConnections()
    }

    func dropConnections() {
        queue.async {
            self.sessions.values.forEach { $0.close() }
            self.sessions.removeAll()
        }
    }

    private func accept(_ client: NWConnection) {
        guard let upstream else { return client.cancel() }
        let session = Session(client: client, upstream: upstream, queue: queue)
        let key = ObjectIdentifier(session)
        sessions[key] = session
        session.onClose = { [weak self] in self?.sessions.removeValue(forKey: key) }
        session.start()
    }

    private final class Session {
        let client: NWConnection
        let upstream: Upstream
        let queue: DispatchQueue
        var server: NWConnection?
        var onClose: (() -> Void)?
        private var buffer = Data()
        private var closed = false

        init(client: NWConnection, upstream: Upstream, queue: DispatchQueue) {
            self.client = client
            self.upstream = upstream
            self.queue = queue
        }

        func start() {
            client.start(queue: queue)
            readHeader()
        }

        private func readHeader() {
            client.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
                guard let self else { return }
                if let data { self.buffer.append(data) }
                if let end = self.buffer.range(of: Data("\r\n\r\n".utf8)) {
                    self.forward(header: self.buffer[..<end.lowerBound], rest: self.buffer[end.upperBound...])
                } else if done || error != nil || self.buffer.count > 65536 {
                    self.close()
                } else {
                    self.readHeader()
                }
            }
        }

        private func forward(header: Data, rest: Data) {
            var lines = String(decoding: header, as: UTF8.self).components(separatedBy: "\r\n")
            guard let requestLine = lines.first, !requestLine.isEmpty else { return close() }
            let isConnect = requestLine.uppercased().hasPrefix("CONNECT ")
            lines = Array(lines.dropFirst()).filter { line in
                let name = line.split(separator: ":").first?.lowercased() ?? ""
                if name == "proxy-authorization" { return false }
                // Plain HTTP: one request per connection, so every request carries our auth header.
                if !isConnect, name == "connection" || name == "proxy-connection" { return false }
                return true
            }
            if !isConnect { lines.append("Connection: close") }
            if let auth = upstream.authHeader { lines.append(auth) }
            let out = Data(([requestLine] + lines).joined(separator: "\r\n").utf8) + Data("\r\n\r\n".utf8) + rest

            guard let port = NWEndpoint.Port(rawValue: UInt16(upstream.port)) else { return close() }
            let server = NWConnection(host: NWEndpoint.Host(upstream.host), port: port, using: .tcp)
            self.server = server
            server.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    server.send(content: out, completion: .contentProcessed { _ in })
                    self.pump(from: self.client, to: server)
                    self.pump(from: server, to: self.client)
                case .failed, .cancelled:
                    self.close()
                default: break
                }
            }
            server.start(queue: queue)
        }

        private func pump(from source: NWConnection, to destination: NWConnection) {
            source.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
                guard let self, !self.closed else { return }
                let finished = done || error != nil
                if let data, !data.isEmpty {
                    // Close only after the last bytes are delivered.
                    destination.send(content: data, completion: .contentProcessed { [weak self] sendError in
                        if sendError != nil || finished { self?.close() } else { self?.pump(from: source, to: destination) }
                    })
                } else if finished {
                    self.close()
                } else {
                    self.pump(from: source, to: destination)
                }
            }
        }

        func close() {
            guard !closed else { return }
            closed = true
            client.cancel()
            server?.cancel()
            onClose?()
        }
    }
}
