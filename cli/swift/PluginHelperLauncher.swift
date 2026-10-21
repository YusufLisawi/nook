import Darwin
import Foundation

/// Internal exec trampoline: Foundation.Process doesn't expose a process-group attribute.
/// exec preserves its pid/stdio/TCC responsibility while a separate group owns all helper descendants.
enum PluginHelperLauncher {
    static func run(_ arguments: [String]) -> Never {
        guard let executable = arguments.first, executable.hasPrefix("/"), setpgid(0, 0) == 0 else {
            FileHandle.standardError.write(Data("Couldn’t create the plugin helper process group.\n".utf8)); exit(127)
        }
        let argv = arguments.map { strdup($0) } + [nil]
        argv.withUnsafeBufferPointer { buffer in
            _ = execv(executable, UnsafeMutablePointer(mutating: buffer.baseAddress!))
        }
        FileHandle.standardError.write(Data("Couldn’t exec plugin helper: \(String(cString: strerror(errno)))\n".utf8))
        argv.forEach { free($0) }
        exit(127)
    }
}
