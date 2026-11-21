// PortTextInput.swift — the seam between a ported text control and the platform's text editor.
//
// A SwiftUI text control is more than a drawing: it needs a caret, a selection and the system IME
// (the soft keyboard), which only the platform can provide. Apple's engine gets those from UIKit;
// this port has to get them from whatever the running platform offers, and that platform lives
// *above* this module (SwiftUIAndroid depends on SwiftUI, never the other way round). So the
// direction is declared here, and the platform installs the implementation later:
//
//   PortTextInput.beginEditing(...)   ->  host.begin(slot, text, frame)   show the editor
//   PortTextInput.endEditing()        ->  host.end()                     hide the editor
//   the editor reports typing         ->  PortTextInput.hostTextChanged(_:)
//   the editor reports it closed      ->  PortTextInput.hostEnded()
//
// Nothing here knows about Android, and nothing here assumes the host can be *called back into*
// synchronously: a platform whose editor is a real widget (Android's EditText) reports through
// the runtime that installed the host, and may pull the request instead of being pushed to.
//
// Threading: every member is called on the platform's UI thread, which is also the thread the
// engine renders on. The host and the session callbacks are deliberately not Sendable and there
// is no locking: an editor that could be driven from a second thread would be a bug anyway.
#if canImport(CoreGraphics)
import CoreGraphics
#else
import Foundation
#endif

/// The platform side of text editing, installed once by the runtime that owns the window (on
/// Android: `SwiftUIAndroid`) and read by `PortTextInput`. All three closures run on the UI thread.
public struct PortTextInputHost {
    /// Show the platform editor over `frame` and bring up the IME. `frame` is in dp in the host
    /// view's coordinate space — the same space and units as `DisplayList` frames, so a control
    /// hands over `LayoutNode.frame` unchanged. `text` seeds the editor (the caret starts at the
    /// end); the same value is also what the control is already drawing.
    public var begin: (_ slot: Int, _ text: String, _ frame: CGRect) -> Void
    /// The control moved or resized while its editor was open; the editor follows.
    public var updateFrame: (_ frame: CGRect) -> Void
    /// Tear the editor down and dismiss the IME. Expected to be idempotent.
    public var end: () -> Void

    public init(begin: @escaping (_ slot: Int, _ text: String, _ frame: CGRect) -> Void,
                updateFrame: @escaping (_ frame: CGRect) -> Void,
                end: @escaping () -> Void) {
        self.begin = begin
        self.updateFrame = updateFrame
        self.end = end
    }
}

public enum PortTextInput {
    /// Installed by the platform runtime when it starts. nil on a backend that has no text
    /// editor (the engine-only tests): a control can still take focus there, it just cannot
    /// receive typed text, which is what makes the port buildable without Android.
    nonisolated(unsafe) public static var host: PortTextInputHost?

    /// True between `beginEditing` and the matching end, whichever side reported it first.
    nonisolated(unsafe) public private(set) static var isEditing = false

    /// The `slot` of the control that owns the platform editor, or nil when no editor is open.
    /// A control compares this with its own identity to decide whether it draws a caret.
    nonisolated(unsafe) public private(set) static var focusedSlot: Int?

    /// The two closures handed in by `beginEditing`, kept only while a session is live.
    nonisolated(unsafe) private static var textHandler: ((String) -> Void)?
    nonisolated(unsafe) private static var endHandler: (() -> Void)?

    /// Hand the control identified by `slot` to the platform editor and start a session.
    ///
    /// `slot` is an opaque identity picked by the control: it only has to be stable while that
    /// control is on screen and distinct from every other control's.
    ///
    /// Calling this again for the slot that is already editing is not a restart: a control's
    /// body is re-evaluated on every state change (including the one `onText` causes), so the
    /// adapter reaches here on each render. Restarting the platform editor would drop the caret
    /// and re-seed the IME with text that is one edit behind the editor, so the session stays and
    /// only the frame is refreshed. The newest callbacks are adopted, because they capture the
    /// newest binding.
    public static func beginEditing(slot: Int, text: String, frame: CGRect,
                                    onText: @escaping (String) -> Void,
                                    onEnd: @escaping () -> Void) {
        if isEditing, focusedSlot == slot {
            textHandler = onText
            endHandler = onEnd
            host?.updateFrame(frame)
            return
        }
        // Focus moved: close the previous session first so its control learns that editing
        // stopped before the new control's session begins.
        if isEditing {
            endEditing()
        }
        isEditing = true
        focusedSlot = slot
        textHandler = onText
        endHandler = onEnd
        host?.begin(slot, text, frame)
    }

    /// End the session from the SwiftUI side (the control lost focus, left the screen, or the
    /// app is done with it). Safe to call when not editing.
    public static func endEditing() {
        guard isEditing else { return }
        // State is cleared *before* anything is called out: an `onEnd` that clears the app's
        // focus state re-evaluates the body, which calls endEditing() again, and that second
        // call must be a no-op instead of recursing.
        let end = endHandler
        isEditing = false
        focusedSlot = nil
        textHandler = nil
        endHandler = nil
        host?.end()
        end?()
    }

    /// The platform editor reports the full new text of the session (Android pushes this after
    /// every text change). Ignored when no session is live, which is what makes it safe for the
    /// platform to report a change that races a teardown.
    public static func hostTextChanged(_ text: String) {
        guard isEditing, let textHandler else { return }
        textHandler(text)
    }

    /// The platform editor closed on its own — IME "done", BACK, or the editor lost focus.
    /// Deliberately does not call `host.end()`: the host is the one reporting, it has already
    /// closed its editor.
    public static func hostEnded() {
        guard isEditing else { return }
        let end = endHandler
        isEditing = false
        focusedSlot = nil
        textHandler = nil
        endHandler = nil
        end?()
    }
}
