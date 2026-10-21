import Foundation

enum AgentDiff {
    /// Exec 0.163 reports paths/kinds, not patches. Show a bounded working-tree diff, explicitly labelled in the UI.
    static func preview(changes: [[String: Any]], directory: String, completion: @escaping (String) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            var result = ""
            for change in changes.prefix(8) {
                guard let path = change["path"] as? String else { continue }
                result += "\n--- \(path)\n"
                if change["kind"] as? String == "add" {
                    let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : URL(fileURLWithPath: directory).appendingPathComponent(path)
                    if let file = try? FileHandle(forReadingFrom: url) {
                        let data = (try? file.read(upToCount: 6000)) ?? Data()
                        try? file.close()
                        result += String(decoding: data, as: UTF8.self).components(separatedBy: "\n").map { "+" + $0 }.joined(separator: "\n")
                    }
                } else {
                    let process = Process(), pipe = Pipe()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                    process.arguments = ["diff", "--no-ext-diff", "--no-textconv", "--no-color", "HEAD", "--", path]
                    process.currentDirectoryURL = URL(fileURLWithPath: directory)
                    process.standardOutput = pipe
                    process.standardError = FileHandle.nullDevice
                    if (try? process.run()) != nil {
                        var preview = Data()
                        while true {
                            let chunk = pipe.fileHandleForReading.availableData
                            if chunk.isEmpty { break }
                            if preview.count < 6000 { preview.append(chunk.prefix(6000 - preview.count)) }
                        }
                        process.waitUntilExit()
                        result += String(decoding: preview, as: UTF8.self)
                    }
                }
                if result.utf8.count > 12_000 { break }
            }
            let preview = String(result.prefix(12_000)).trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async { completion(preview) }
        }
    }
}
