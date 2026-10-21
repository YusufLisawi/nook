import Foundation
import CoreGraphics

enum WindowAction: String, CaseIterable, Identifiable {
    case previousDisplay, nextDisplay, previousDesktop, nextDesktop
    case leftHalf, rightHalf, topHalf, bottomHalf
    case topLeftQuarter, topRightQuarter, bottomLeftQuarter, bottomRightQuarter
    case firstThird, centerThird, lastThird, firstTwoThirds, lastTwoThirds
    case maximize, almostMaximize, maximizeHeight, maximizeWidth, center, restore

    var id: String { rawValue }

    var title: String {
        switch self {
        case .previousDisplay: "Previous Display"
        case .nextDisplay: "Next Display"
        case .previousDesktop: "Previous Desktop"
        case .nextDesktop: "Next Desktop"
        case .leftHalf: "Left Half"
        case .rightHalf: "Right Half"
        case .topHalf: "Top Half"
        case .bottomHalf: "Bottom Half"
        case .topLeftQuarter: "Top Left Quarter"
        case .topRightQuarter: "Top Right Quarter"
        case .bottomLeftQuarter: "Bottom Left Quarter"
        case .bottomRightQuarter: "Bottom Right Quarter"
        case .firstThird: "First Third"
        case .centerThird: "Center Third"
        case .lastThird: "Last Third"
        case .firstTwoThirds: "First Two Thirds"
        case .lastTwoThirds: "Last Two Thirds"
        case .maximize: "Maximize"
        case .almostMaximize: "Almost Maximize"
        case .maximizeHeight: "Maximize Height"
        case .maximizeWidth: "Maximize Width"
        case .center: "Center"
        case .restore: "Restore"
        }
    }

    var group: String {
        switch self {
        case .previousDisplay, .nextDisplay, .previousDesktop, .nextDesktop: "Displays & Desktops"
        case .leftHalf, .rightHalf, .topHalf, .bottomHalf: "Halves"
        case .topLeftQuarter, .topRightQuarter, .bottomLeftQuarter, .bottomRightQuarter: "Quarters"
        case .firstThird, .centerThird, .lastThird, .firstTwoThirds, .lastTwoThirds: "Thirds"
        default: "Size & Position"
        }
    }

    static let groups = ["Displays & Desktops", "Halves", "Quarters", "Thirds", "Size & Position"]
    var isDesktop: Bool { self == .previousDesktop || self == .nextDesktop }
    var isDisplay: Bool { self == .previousDisplay || self == .nextDisplay }
}

/// All geometry uses Accessibility/Quartz coordinates: points, origin at the main display's top left.
/// Kept independent of AX and NSScreen so arrangements above/left of the main display can be tested.
enum WindowGeometry {
    static func quartzFrame(_ appKitFrame: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: appKitFrame.minX, y: primaryHeight - appKitFrame.maxY,
               width: appKitFrame.width, height: appKitFrame.height)
    }

    static func fitted(_ frame: CGRect, in area: CGRect) -> CGRect {
        let size = CGSize(width: min(frame.width, area.width), height: min(frame.height, area.height))
        return CGRect(x: min(max(frame.minX, area.minX), area.maxX - size.width),
                      y: min(max(frame.minY, area.minY), area.maxY - size.height),
                      width: size.width, height: size.height)
    }

    static func layout(_ action: WindowAction, frame: CGRect, area: CGRect, almostScale: CGFloat = 0.9) -> CGRect {
        func zone(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
            // Round shared edges, rather than sizes, so thirds on odd-sized displays meet exactly.
            let left = (area.minX + area.width * x).rounded()
            let top = (area.minY + area.height * y).rounded()
            return CGRect(x: left, y: top,
                          width: (area.minX + area.width * (x + width)).rounded() - left,
                          height: (area.minY + area.height * (y + height)).rounded() - top)
        }
        let current = fitted(frame, in: area)
        switch action {
        case .leftHalf: return zone(0, 0, 0.5, 1)
        case .rightHalf: return zone(0.5, 0, 0.5, 1)
        case .topHalf: return zone(0, 0, 1, 0.5)
        case .bottomHalf: return zone(0, 0.5, 1, 0.5)
        case .topLeftQuarter: return zone(0, 0, 0.5, 0.5)
        case .topRightQuarter: return zone(0.5, 0, 0.5, 0.5)
        case .bottomLeftQuarter: return zone(0, 0.5, 0.5, 0.5)
        case .bottomRightQuarter: return zone(0.5, 0.5, 0.5, 0.5)
        case .firstThird: return zone(0, 0, 1 / 3, 1)
        case .centerThird: return zone(1 / 3, 0, 1 / 3, 1)
        case .lastThird: return zone(2 / 3, 0, 1 / 3, 1)
        case .firstTwoThirds: return zone(0, 0, 2 / 3, 1)
        case .lastTwoThirds: return zone(1 / 3, 0, 2 / 3, 1)
        case .maximize: return area
        case .almostMaximize:
            let scale = min(0.98, max(0.5, almostScale))
            return zone((1 - scale) / 2, (1 - scale) / 2, scale, scale)
        case .maximizeHeight: return CGRect(x: current.minX, y: area.minY, width: current.width, height: area.height)
        case .maximizeWidth: return CGRect(x: area.minX, y: current.minY, width: area.width, height: current.height)
        case .center:
            return CGRect(x: (area.midX - current.width / 2).rounded(), y: (area.midY - current.height / 2).rounded(),
                          width: current.width, height: current.height)
        default: return current
        }
    }

    static func transferred(_ frame: CGRect, from source: CGRect, to destination: CGRect) -> CGRect {
        guard source.width > 0, source.height > 0 else { return fitted(frame, in: destination) }
        let relative = CGRect(x: destination.minX + (frame.minX - source.minX) / source.width * destination.width,
                              y: destination.minY + (frame.minY - source.minY) / source.height * destination.height,
                              width: frame.width / source.width * destination.width,
                              height: frame.height / source.height * destination.height)
        return fitted(relative, in: destination)
    }

    static func screenIndex(for frame: CGRect, screens: [CGRect]) -> Int? {
        guard !screens.isEmpty else { return nil }
        func overlap(_ screen: CGRect) -> CGFloat {
            let rect = screen.intersection(frame)
            return rect.isNull ? 0 : rect.width * rect.height
        }
        if let best = screens.indices.max(by: { overlap(screens[$0]) < overlap(screens[$1]) }), overlap(screens[best]) > 0 {
            return best
        }
        return screens.indices.min {
            hypot(screens[$0].midX - frame.midX, screens[$0].midY - frame.midY) <
                hypot(screens[$1].midX - frame.midX, screens[$1].midY - frame.midY)
        }
    }
}
