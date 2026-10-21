import Foundation
import CoreGraphics

@main
enum GeometryTests {
    static func main() throws {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message)
            checks += 1
        }
        func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 0.001 }
        let main = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let aboveLeft = CGRect(x: -1920, y: 982, width: 1920, height: 1080)
        check(WindowGeometry.quartzFrame(aboveLeft, primaryHeight: 982) == CGRect(x: -1920, y: -1080, width: 1920, height: 1080), "Negative Quartz coordinates on display above main")
        check(WindowGeometry.quartzFrame(main, primaryHeight: 982) == main, "Main display coordinate conversion")
        let usable = WindowGeometry.quartzFrame(CGRect(x: 0, y: 70, width: 1512, height: 874), primaryHeight: 982)
        check(usable == CGRect(x: 0, y: 38, width: 1512, height: 874), "Menu bar and Dock excluded")
        let frame = CGRect(x: 150, y: 120, width: 700, height: 500)
        check(WindowGeometry.layout(.maximize, frame: frame, area: usable) == usable, "Maximize stays within usable frame")
        let odd = CGRect(x: -101, y: 37, width: 1001, height: 777)
        let thirds = [WindowAction.firstThird, .centerThird, .lastThird].map { WindowGeometry.layout($0, frame: frame, area: odd) }
        check(thirds[0].minX == odd.minX && thirds[2].maxX == odd.maxX, "Thirds reach both edges")
        check(thirds[0].maxX == thirds[1].minX && thirds[1].maxX == thirds[2].minX, "Odd-width thirds have no gaps or overlaps")
        for action in WindowAction.allCases where !action.isDesktop && !action.isDisplay && action != .restore {
            let layout = WindowGeometry.layout(action, frame: frame, area: odd)
            check(odd.contains(layout), "\(action) stays within bounds")
        }
        let centered = WindowGeometry.layout(.center, frame: frame, area: usable)
        check(centered.size == frame.size && near(centered.midX, usable.midX) && near(centered.midY, usable.midY), "Center retains size")
        let height = WindowGeometry.layout(.maximizeHeight, frame: frame, area: usable)
        check(height.width == frame.width && height.minX == frame.minX && height.minY == usable.minY && height.height == usable.height, "Maximize Height keeps horizontal frame")
        let width = WindowGeometry.layout(.maximizeWidth, frame: frame, area: usable)
        check(width.height == frame.height && width.minY == frame.minY && width.minX == usable.minX && width.width == usable.width, "Maximize Width keeps vertical frame")
        let almost = WindowGeometry.layout(.almostMaximize, frame: frame, area: main, almostScale: 0.9)
        check(abs(almost.width / main.width - 0.9) < 0.002 && near(almost.midX, main.midX), "Almost Maximize is centered at selected percentage")
        let source = CGRect(x: -1920, y: 25, width: 1920, height: 1055)
        let destination = CGRect(x: 0, y: -1440, width: 2560, height: 1400)
        let relative = CGRect(x: source.minX + source.width / 4, y: source.minY + source.height / 4, width: source.width / 2, height: source.height / 2)
        let transferred = WindowGeometry.transferred(relative, from: source, to: destination)
        check(near(transferred.minX, 640) && near(transferred.minY, -1090) && near(transferred.width, 1280) && near(transferred.height, 700), "Display transfer retains all relative fractions")
        let roundTrip = WindowGeometry.transferred(transferred, from: destination, to: source)
        check(roundTrip == relative, "Display transfer round trip")
        let tooLarge = CGRect(x: -4000, y: -4000, width: 6000, height: 4000)
        check(WindowGeometry.transferred(tooLarge, from: source, to: destination) == destination, "Oversized display transfer fits destination")
        check(WindowGeometry.fitted(tooLarge, in: usable) == usable, "Restore fits a disconnected display's frame")
        let screens = [main, WindowGeometry.quartzFrame(aboveLeft, primaryHeight: 982)]
        check(WindowGeometry.screenIndex(for: CGRect(x: -1800, y: -500, width: 500, height: 400), screens: screens) == 1, "Screen selected by overlap on above-left arrangement")
        check(WindowGeometry.screenIndex(for: CGRect(x: -100, y: 10, width: 800, height: 500), screens: screens) == 0, "Spanning window uses largest overlap")
        check(WindowGeometry.screenIndex(for: CGRect(x: 3000, y: 0, width: 200, height: 200), screens: screens) == 0, "Disconnected screen falls back to nearest display")
        check(WindowGeometry.screenIndex(for: frame, screens: []) == nil, "No-display case")
        let spaces: [[String: Any]] = [
            ["ManagedSpaceID": NSNumber(value: 10), "type": 0],
            ["ManagedSpaceID": NSNumber(value: 20), "type": 0],
            ["ManagedSpaceID": NSNumber(value: 30), "type": 4]
        ]
        let next = try WindowDesktopPlan.make(currentID: 10, spaces: spaces, memberships: [10], step: 1)
        check(next.source == 10 && next.destination == 20, "Next desktop")
        let previous = try WindowDesktopPlan.make(currentID: 20, spaces: spaces, memberships: [20], step: -1)
        check(previous.destination == 10, "Previous desktop")
        func refuses(_ current: UInt64, _ membership: [UInt64], _ step: Int, _ message: String) {
            do {
                _ = try WindowDesktopPlan.make(currentID: current, spaces: spaces, memberships: membership, step: step)
                preconditionFailure(message)
            } catch { checks += 1 }
        }
        refuses(10, [10], -1, "First desktop must not wrap")
        refuses(20, [20], 1, "Do not drag into full screen")
        refuses(30, [30], -1, "Do not move a full-screen window")
        refuses(10, [10, 20], 1, "Do not move sticky windows")
        refuses(10, [20], 1, "Do not move a window from a different desktop")
        refuses(999, [999], 1, "Unknown desktop")
        var targets = WindowTargets<String>()
        targets.capture("Editor", for: "left")
        targets.capture("Browser", for: "right")
        check(targets.get("left")?.window == "Editor", "Opening another notch keeps the pinned notch's target")
        check(targets.get("right")?.window == "Browser", "Each notch has its own captured target")
        check(targets.get()?.window == "Browser", "Unscoped calls use the most recent capture")
        targets.capture(nil, error: "No focused window", for: "right")
        check(targets.get("right")?.window == nil && targets.get("right")?.error == "No focused window", "Failed capture cannot reuse an old window")
        check(targets.get("missing") == nil, "Unknown context never falls back to another notch")
        for i in 0..<17 { targets.capture("Window \(i)", for: "notch \(i)") }
        check(targets.get("left") == nil && targets.get("notch 0") == nil && targets.get("notch 1")?.window == "Window 1", "Closed/rebuilt notch capture history is bounded")
        print("Passed \(checks) geometry and desktop-planning checks")
    }
}
