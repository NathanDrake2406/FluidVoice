import AppKit
import ApplicationServices
import Foundation

@MainActor
final class RealtimeTextboxSession {
    enum ReplacementState: Equatable, CustomStringConvertible {
        case available
        case unavailable(String)

        var description: String {
            switch self {
            case .available:
                return "available"
            case let .unavailable(reason):
                return "unavailable(\(reason))"
            }
        }
    }

    let targetPID: pid_t?
    let bundleIdentifier: String?
    let focusedElement: AXUIElement?
    let initialSelectedRange: CFRange?
    let startedAt = Date()
    let isTerminalLike: Bool

    private(set) var typedText: String = ""
    private(set) var lastRawTranscript: String = ""
    private(set) var committedTranscript: String = ""
    private(set) var replacementState: ReplacementState

    init(
        targetPID: pid_t?,
        bundleIdentifier: String?,
        focusedElement: AXUIElement?,
        initialSelectedRange: CFRange?
    ) {
        self.targetPID = targetPID
        self.bundleIdentifier = bundleIdentifier
        self.focusedElement = focusedElement
        self.initialSelectedRange = initialSelectedRange
        self.isTerminalLike = Self.isTerminalLike(bundleIdentifier: bundleIdentifier)
        self.replacementState = focusedElement != nil ? .available : .unavailable("Missing focused AX element")
    }

    static func captureCurrent() -> RealtimeTextboxSession? {
        guard AXIsProcessTrusted() else { return nil }

        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        )
        guard result == .success, let focusedRef else { return nil }
        guard CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else { return nil }

        let element = unsafeBitCast(focusedRef, to: AXUIElement.self)
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)

        let bundleIdentifier = pid > 0 ? NSRunningApplication(processIdentifier: pid)?.bundleIdentifier : nil
        let rawValue = Self.elementStringValue(element)
        let placeholderValue = Self.elementPlaceholderValue(element)
        let selectedRange = Self.elementSelectedRange(element)
        let role = Self.elementAttributeString(element, attribute: kAXRoleAttribute as CFString)
        let subrole = Self.elementAttributeString(element, attribute: kAXSubroleAttribute as CFString)
        let normalizedValue = Self.normalizedInitialValue(
            rawValue: rawValue,
            placeholder: placeholderValue,
            bundleIdentifier: bundleIdentifier,
            selectedRange: selectedRange
        )

        let captureSummary =
            "Realtime textbox capture -> pid: \(pid > 0 ? String(pid) : "nil"), " +
            "bundle: \(bundleIdentifier ?? "unknown"), role: \(role ?? "nil"), " +
            "subrole: \(subrole ?? "nil"), rawValueChars: \(rawValue?.count ?? 0), " +
            "placeholderChars: \(placeholderValue?.count ?? 0), " +
            "selectedRange: \(Self.describe(range: selectedRange)), " +
            "normalizedEmpty: \(normalizedValue?.isEmpty ?? true), " +
            "terminalLike: \(Self.isTerminalLike(bundleIdentifier: bundleIdentifier)), " +
            "rawSnippet: '\(Self.snippet(rawValue))', " +
            "placeholderSnippet: '\(Self.snippet(placeholderValue))'"
        DebugLogger.shared.info(captureSummary, source: "RealtimeTextbox")

        return RealtimeTextboxSession(
            targetPID: pid > 0 ? pid : nil,
            bundleIdentifier: bundleIdentifier,
            focusedElement: element,
            initialSelectedRange: selectedRange
        )
    }

    var canAttemptReplacement: Bool {
        if case .available = self.replacementState {
            return self.focusedElement != nil
        }
        return false
    }

    var expectedCaretLocation: Int? {
        guard let initialSelectedRange else { return nil }
        return initialSelectedRange.location + self.typedText.count
    }

    func recordRawTranscript(_ text: String) {
        self.lastRawTranscript = text
    }

    func seedTranscriptBaseline(_ text: String) {
        self.lastRawTranscript = text
        self.committedTranscript = ""
    }

    func appendCommittedDelta(_ delta: String, sourceTranscript: String) {
        guard !delta.isEmpty else {
            self.lastRawTranscript = sourceTranscript
            return
        }
        self.typedText += delta
        self.committedTranscript += delta
        self.lastRawTranscript = sourceTranscript
    }

    func replaceTypedText(with finalText: String) {
        self.typedText = finalText
        self.committedTranscript = finalText
        self.lastRawTranscript = finalText
    }

    func markReplacementUnavailable(_ reason: String) {
        self.replacementState = .unavailable(reason)
    }

    static func elementStringValue(_ element: AXUIElement?) -> String? {
        guard let element else { return nil }
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value)
        guard result == .success else { return nil }
        return value as? String
    }

    static func elementAttributeString(_ element: AXUIElement?, attribute: CFString) -> String? {
        guard let element else { return nil }
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success else { return nil }
        return value as? String
    }

    static func elementPlaceholderValue(_ element: AXUIElement?) -> String? {
        guard let element else { return nil }
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, "AXPlaceholderValue" as CFString, &value)
        guard result == .success else { return nil }
        return value as? String
    }

    static func elementSelectedRange(_ element: AXUIElement?) -> CFRange? {
        guard let element else { return nil }
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value)
        guard result == .success, let value else { return nil }
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }

        var range = CFRange()
        let ok = AXValueGetValue(unsafeBitCast(value, to: AXValue.self), .cfRange, &range)
        return ok ? range : nil
    }

    static func normalizedInitialValue(
        rawValue: String?,
        placeholder: String?,
        bundleIdentifier: String?,
        selectedRange: CFRange?
    ) -> String? {
        if self.shouldTreatAsPlaceholder(rawValue: rawValue, placeholder: placeholder) ||
            self.shouldTreatAsEffectivelyEmptyAXValue(rawValue: rawValue, selectedRange: selectedRange) ||
            self.shouldTreatAsGhostPrompt(rawValue: rawValue, bundleIdentifier: bundleIdentifier, selectedRange: selectedRange) ||
            self.shouldTreatAsDiscordEmptyComposer(rawValue: rawValue, bundleIdentifier: bundleIdentifier, selectedRange: selectedRange)
        {
            return ""
        }

        return rawValue
    }

    static func shouldTreatAsPlaceholder(rawValue: String?, placeholder: String?) -> Bool {
        guard let rawValue else { return false }

        let trimmedRaw = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRaw.isEmpty else { return false }

        guard let placeholder else { return false }
        let trimmedPlaceholder = placeholder.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPlaceholder.isEmpty else { return false }

        return trimmedRaw == trimmedPlaceholder
    }

    static func shouldTreatAsEffectivelyEmptyAXValue(
        rawValue: String?,
        selectedRange: CFRange?
    ) -> Bool {
        guard let rawValue else { return false }
        guard let selectedRange else { return false }

        let visibleText = Self.removingInvisibleComposerCharacters(from: rawValue)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard visibleText.isEmpty else { return false }

        return selectedRange.length == 0 && selectedRange.location <= rawValue.count
    }

    static func shouldTreatAsGhostPrompt(
        rawValue: String?,
        bundleIdentifier: String?,
        selectedRange: CFRange?
    ) -> Bool {
        guard bundleIdentifier == "com.openai.codex" else { return false }
        guard let rawValue else { return false }
        guard let selectedRange else { return false }

        let trimmedRaw = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard selectedRange.location == 0, selectedRange.length == 0 else { return false }

        return trimmedRaw == "Ask for follow-up changes"
    }

    static func shouldTreatAsDiscordEmptyComposer(
        rawValue: String?,
        bundleIdentifier: String?,
        selectedRange: CFRange?
    ) -> Bool {
        guard bundleIdentifier == "com.hnc.Discord" else { return false }
        guard let rawValue else { return false }
        guard let selectedRange else { return false }

        return rawValue == "\u{FEFF}\n" && selectedRange.location == 1 && selectedRange.length == 0
    }

    static func removingInvisibleComposerCharacters(from text: String) -> String {
        let invisibleScalars = CharacterSet(charactersIn: "\u{FEFF}\u{200B}\u{200C}\u{200D}\u{2060}")
        let filteredScalars = text.unicodeScalars.filter { scalar in
            !invisibleScalars.contains(scalar)
        }
        return String(String.UnicodeScalarView(filteredScalars))
    }

    static func isTerminalLike(bundleIdentifier: String?) -> Bool {
        let terminalBundleIDs: Set<String> = [
            "com.googlecode.iterm2",
            "com.apple.Terminal",
            "com.github.wez.wezterm",
            "dev.warp.Warp-Stable",
            "co.zeit.hyper",
        ]
        guard let bundleIdentifier else { return false }
        return terminalBundleIDs.contains(bundleIdentifier)
    }

    static func describe(range: CFRange?) -> String {
        guard let range else { return "nil" }
        return "{loc:\(range.location), len:\(range.length)}"
    }

    static func snippet(_ text: String?, limit: Int = 80) -> String {
        guard let text, !text.isEmpty else { return "" }
        let clipped = text.prefix(limit)
        return String(clipped).replacingOccurrences(of: "\n", with: "\\n")
    }
}
