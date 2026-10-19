import AppKit

/// Files dropped on the notch. Stores paths only; nothing is copied.
final class FileShelf: ObservableObject {
    @Published private(set) var items: [URL] = []
    private let key = "shelfItems"

    init() {
        items = (UserDefaults.standard.stringArray(forKey: key) ?? [])
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    func add(_ providers: [NSItemProvider]) {
        for provider in providers where provider.canLoadObject(ofClass: URL.self) {
            _ = provider.loadObject(ofClass: URL.self) { [weak self] url, _ in
                guard let url, url.isFileURL else { return }
                DispatchQueue.main.async { self?.append(url) }
            }
        }
    }

    func remove(_ url: URL) {
        items.removeAll { $0 == url }
        save()
    }

    func clear() {
        items = []
        save()
    }

    private func append(_ url: URL) {
        guard !items.contains(url) else { return }
        items.append(url)
        save()
    }

    private func save() { UserDefaults.standard.set(items.map(\.path), forKey: key) }
}
