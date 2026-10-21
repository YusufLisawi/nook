import AppKit
import Darwin

/// Read-only opaque identity for a focused AX window. No geometry or Space operations live here.
enum PluginWindowIdentity {
    static func number(_ element: AXUIElement) -> CGWindowID? {
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, "AXWindowNumber" as CFString, &value) == .success,
           let number = value as? NSNumber { return number.uint32Value }
        guard let handle = dlopen(nil, RTLD_LAZY) else { return nil }
        defer { dlclose(handle) }
        guard let address = dlsym(handle, "_AXUIElementGetWindow") else { return nil }
        typealias Resolve = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
        let resolve = unsafeBitCast(address, to: Resolve.self)
        var number: CGWindowID = 0
        return resolve(element, &number) == .success && number != 0 ? number : nil
    }
}
