import AppKit
import ApplicationServices

extension LauncherState {
    func runSmartAnswer(paste: Bool = false, action: LauncherAnswer.Action? = nil) {
        guard let answer = smartAnswer, !performing, !thinking else { return }
        let value = action?.value ?? (answer.isAvailable ? .copy(answer.copyValue) : nil)
        guard let value else { return }
        actionsPresented = false
        switch value {
        case .open(let url): NSWorkspace.shared.open(url)
        case .copy(let text):
            if paste {
                guard AXIsProcessTrusted() else { error = "Allow Nook in Accessibility to paste. Return still copies."; resize(); return }
                guard let app = answerTargetApplication, !app.isTerminated else { error = "The original app is unavailable. Return still copies."; resize(); return }
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
                dismiss(restoreFocus: true)
                // Focus may settle asynchronously after the key panel closes. Refuse a different destination.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    guard !app.isTerminated, AXIsProcessTrusted(),
                          NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else {
                        Notifier.post(title: "Answer copied", body: "The original app lost focus; the answer wasn't pasted."); return
                    }
                    let source = CGEventSource(stateID: .combinedSessionState)
                    for down in [true, false] {
                        let event = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: down)
                        event?.flags = .maskCommand
                        event?.setIntegerValueField(.eventSourceUserData, value: NookSyntheticInput.mouseMarker)
                        event?.post(tap: .cghidEventTap)
                    }
                }
            } else {
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
                dismiss(restoreFocus: true)
            }
        }
    }
}
