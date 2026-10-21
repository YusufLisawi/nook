import Foundation

/// Launcher asks only for the bounded top results; it never copies the name catalog.
enum LauncherFileSource {
    static func search(_ text: String, client: String, reply: @escaping (Result<[LauncherEntry], Error>) -> Void) {
        FileSearchService.shared.search(text, options: ["scope": "all", "limit": 12, "clientID": client], pluginID: "native.launcher") { payload in
            if let message = payload["error"] as? String { reply(.failure(FileSearchError.message(message))); return }
            let rows = (payload["results"] as? [[String: Any]] ?? []).compactMap(FileSearchResult.init(json:))
            reply(.success(rows.map { item in
                LauncherEntry(id: "file:" + item.path, title: item.name,
                              subtitle: (item.path as NSString).deletingLastPathComponent,
                              kind: item.kind, symbol: FileSearchTab.symbol(item.category), source: .files, target: .file(item.path))
            }))
        }
    }
}
