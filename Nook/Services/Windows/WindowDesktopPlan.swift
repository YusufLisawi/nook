import Foundation

struct WindowManagementError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

struct WindowDesktopPlan {
    let source: UInt64
    let destination: UInt64

    static func make(currentID: UInt64, spaces: [[String: Any]], memberships: [UInt64], step: Int) throws -> WindowDesktopPlan {
        guard let current = spaces.firstIndex(where: { ($0["ManagedSpaceID"] as? NSNumber)?.uint64Value == currentID }),
              spaces[current]["type"] as? Int == 0, memberships == [currentID] else {
            throw WindowManagementError("The window must belong to the current desktop only. Leave full screen and turn off “All Desktops” for this app.")
        }
        let next = current + step
        guard spaces.indices.contains(next) else {
            throw WindowManagementError("There is no \(step < 0 ? "previous" : "next") desktop on this display. Add one in Mission Control.")
        }
        guard spaces[next]["type"] as? Int == 0, let id = (spaces[next]["ManagedSpaceID"] as? NSNumber)?.uint64Value else {
            throw WindowManagementError("The adjacent Space is full screen or Split View. Use a neighboring desktop in Mission Control.")
        }
        return WindowDesktopPlan(source: currentID, destination: id)
    }
}
