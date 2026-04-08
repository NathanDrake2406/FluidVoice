import ApplicationServices
import Foundation

struct RealtimeTextboxDriftSnapshot {
    let focusedElement: AXUIElement?
    let selectedRange: CFRange?
    let focusedPID: pid_t?
}

enum RealtimeTextboxDriftDetector {
    static func captureSnapshot() -> RealtimeTextboxDriftSnapshot {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        )

        guard result == .success,
              let focusedRef,
              CFGetTypeID(focusedRef) == AXUIElementGetTypeID()
        else {
            return RealtimeTextboxDriftSnapshot(focusedElement: nil, selectedRange: nil, focusedPID: nil)
        }

        let element = unsafeBitCast(focusedRef, to: AXUIElement.self)
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)

        return RealtimeTextboxDriftSnapshot(
            focusedElement: element,
            selectedRange: RealtimeTextboxSession.elementSelectedRange(element),
            focusedPID: pid > 0 ? pid : nil
        )
    }

    static func driftReason(session: RealtimeTextboxSession) -> String? {
        guard session.canAttemptReplacement else {
            return "replacement already unavailable"
        }

        let snapshot = self.captureSnapshot()
        guard let focusedElement = snapshot.focusedElement else {
            return "missing focused element"
        }

        if let targetPID = session.targetPID,
           let focusedPID = snapshot.focusedPID,
           targetPID != focusedPID
        {
            return "focused app changed"
        }

        if let originalElement = session.focusedElement,
           !CFEqual(originalElement, focusedElement)
        {
            return "focused text element changed"
        }

        guard let expectedCaretLocation = session.expectedCaretLocation else {
            return "missing expected caret location"
        }
        guard let selectedRange = snapshot.selectedRange else {
            return "missing current selection range"
        }
        guard selectedRange.length == 0 else {
            return "selection is no longer collapsed"
        }
        guard selectedRange.location == expectedCaretLocation else {
            return "caret moved from session-owned position"
        }

        return nil
    }

    static func isSafeForFinalReplacement(session: RealtimeTextboxSession) -> Bool {
        self.driftReason(session: session) == nil
    }
}
