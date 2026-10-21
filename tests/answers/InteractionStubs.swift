import AppKit

/// Exercise production key routing and state with inert output: no clipboard writes, app activation, URLs or events.
enum AnswerInteractionRecorder {
    static var calls: [(paste: Bool, action: LauncherAnswer.Action?)] = []
}
extension LauncherState {
    func runSmartAnswer(paste: Bool = false, action: LauncherAnswer.Action? = nil) {
        AnswerInteractionRecorder.calls.append((paste, action))
        dismiss()
    }
}
