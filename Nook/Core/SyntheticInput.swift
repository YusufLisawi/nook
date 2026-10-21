import CoreGraphics

/// Events emitted by the Mouse engine must reach the focused app without invoking Nook shortcuts.
enum NookSyntheticInput {
    static let mouseMarker: Int64 = 0x4E4F_4F4B

    static func isMouseEvent(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == mouseMarker
    }
}
