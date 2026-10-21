import Foundation

/// Launcher asks only for the bounded top results; it never copies the name catalog.
enum LauncherFileSource {
    static func search(_ text: String, client: String, reply: @escaping (Result<[LauncherEntry], Error>) -> Void) {
        FileNameIndex.shared.search(text, scope: "all", limit: 12, client: client) { result in
            reply(result.map { rows, _, _ in
                rows.map { item in
                    LauncherEntry(id: "file:" + item.path, title: item.name,
                                  subtitle: (item.path as NSString).deletingLastPathComponent,
                                  kind: item.kind, symbol: FileSearchTab.symbol(item.category), source: .files, target: .file(item.path))
                }
            })
        }
    }
}
