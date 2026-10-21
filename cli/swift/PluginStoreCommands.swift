import Foundation

/// Keep the existing synchronous command dispatcher; Store work runs off its main thread.
func runStoreCommand(_ operation: @escaping () async throws -> Void) {
    let finished = DispatchSemaphore(value: 0)
    Task.detached {
        do { try await operation() }
        catch { die(error.localizedDescription) }
        finished.signal()
    }
    finished.wait()
}

enum PluginStoreCommands {
    static func run(_ command: String, arguments: [String]) async throws {
        let client = PluginStoreClient()
        let allowedFlags = command == "search" ? ["--json"] : []
        if let unknown = arguments.first(where: { $0.hasPrefix("--") && !allowedFlags.contains($0) }) {
            throw PluginStoreError("Unknown option: \(unknown)")
        }
        let operands = arguments.filter { !$0.hasPrefix("--") }
        switch command {
        case "search":
            let catalog = try await client.catalog()
            if let message = catalog.message {
                if arguments.contains("--json") { FileHandle.standardError.write(Data("\(message)\n".utf8)) }
                else { print(message) }
            }
            let query = operands.joined(separator: " ")
            let entries = catalog.plugins.filter { $0.matches(query) }
            if arguments.contains("--json") {
                let encoded = try JSONEncoder().encode(entries)
                printJSON(try JSONSerialization.jsonObject(with: encoded))
            } else {
                for entry in entries { print("\(pad(entry.id, 24))\(entry.name) · \(entry.version)\n  \(entry.description) — \(entry.author)") }
                if entries.isEmpty { print(query.isEmpty ? "No plugins are available yet." : "No matching plugins.") }
            }
        case "install":
            guard operands.count == 1 else { throw PluginStoreError("Usage: nook install <id>") }
            let entry = try await find(operands[0], client: client)
            print("Installing \(entry.name) \(entry.version)…")
            try await client.install(entry)
            print("✓ Installed \(entry.id). Nook hot-reloads the Plugins folder.")
        case "uninstall":
            guard operands.count == 1 else { throw PluginStoreError("Usage: nook uninstall <id>") }
            try await client.uninstall(operands[0])
            print("✓ Moved \(operands[0]) to Trash. Saved data and settings are kept.")
        case "update":
            guard operands.count <= 1 else { throw PluginStoreError("Usage: nook update [id]") }
            let catalog = try await client.catalog(force: true)
            if let message = catalog.message { print(message) }
            let installations = await client.installations()
            let targets: [PluginStoreEntry]
            if let id = operands.first {
                guard let entry = catalog.plugins.first(where: { $0.id == id }) else { throw PluginStoreError("No Store plugin named \(id).") }
                guard installations[id]?.receipt != nil else { throw PluginStoreError("\(id) isn't managed by the Store.") }
                targets = [entry]
            } else { targets = catalog.plugins.filter { installations[$0.id]?.receipt != nil } }
            var updated = 0
            var failures: [String] = []
            for entry in targets where installations[entry.id]?.receipt?.sha != entry.sha {
                do {
                    print("Updating \(entry.id) to \(entry.version)…")
                    try await client.install(entry, update: true)
                    updated += 1
                } catch { failures.append("\(entry.id): \(error.localizedDescription)") }
            }
            print(updated == 0 ? "No updates installed." : "✓ Updated \(updated) plugin(s). Previous copies are in Trash.")
            if !failures.isEmpty { throw PluginStoreError(failures.joined(separator: "\n")) }
        default: throw PluginStoreError("Unknown Store command.")
        }
    }

    private static func find(_ id: String, client: PluginStoreClient) async throws -> PluginStoreEntry {
        guard PluginStorePackage.validID(id) else { throw PluginStoreError("Invalid plugin ID.") }
        let catalog = try await client.catalog()
        guard let entry = catalog.plugins.first(where: { $0.id == id }) else {
            throw PluginStoreError(catalog.message ?? "No Store plugin named \(id). Try: nook search \(id)")
        }
        return entry
    }
}
