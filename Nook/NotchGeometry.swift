import AppKit

/// Where the notch is on a screen, in global (bottom-left origin) coordinates.
struct NotchGeometry {
    let screen: NSScreen
    let notch: CGRect

    /// Screens that get a notch: "" = the notched screen, "*" = every screen, otherwise a screen name.
    static func targetScreens(setting: String?) -> [NSScreen] {
        let screens = NSScreen.screens
        switch setting ?? "" {
        case "*": return screens
        case "": return [screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main ?? screens[0]]
        case let name: return [screens.first(where: { $0.localizedName == name }) ?? screens[0]]
        }
    }

    static func forScreen(_ screen: NSScreen) -> NotchGeometry {
        let frame = screen.frame
        if screen.safeAreaInsets.top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            let width = frame.width - left.width - right.width
            let height = screen.safeAreaInsets.top
            return .init(screen: screen, notch: CGRect(x: frame.minX + left.width, y: frame.maxY - height, width: width, height: height))
        }
        // No notch: a small fake one, centred on the menu bar.
        let size = CGSize(width: 190, height: 32)
        return .init(screen: screen, notch: CGRect(x: frame.midX - size.width / 2, y: frame.maxY - size.height, width: size.width, height: size.height))
    }
}
