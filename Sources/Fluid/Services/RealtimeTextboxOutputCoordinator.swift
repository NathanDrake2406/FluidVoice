import Combine
import Foundation

@MainActor
final class RealtimeTextboxOutputCoordinator: ObservableObject {
    let objectWillChange = ObservableObjectPublisher()
    private let sink = RealtimeTextboxSink()
    private(set) var activeSession: RealtimeTextboxSession?

    static func isEnabled(
        settings: SettingsStore,
        model: SettingsStore.SpeechModel? = nil
    ) -> Bool {
        let activeModel = model ?? settings.selectedSpeechModel
        return activeModel == .parakeetRealtime && settings.parakeetRealtimeTextboxEnabled
    }

    static func isEnabledForCurrentSettings() -> Bool {
        self.isEnabled(settings: SettingsStore.shared)
    }

    func startSessionIfPossible() -> Bool {
        guard Self.isEnabled(settings: SettingsStore.shared) else {
            DebugLogger.shared.debug(
                "Realtime textbox start skipped because beta mode is disabled for current settings",
                source: "RealtimeTextbox"
            )
            self.cancelSession()
            return false
        }

        self.activeSession = RealtimeTextboxSession.captureCurrent()
        DebugLogger.shared.info(
            "Realtime textbox session start -> success: \(self.activeSession != nil)",
            source: "RealtimeTextbox"
        )
        return self.activeSession != nil
    }

    func consumeStreamingText(_ text: String) {
        guard Self.isEnabled(settings: SettingsStore.shared) else { return }
        guard let session = self.ensureSessionForStreaming(baselineTranscript: text) else { return }

        let delta = self.stabilizedDelta(
            previousRawTranscript: session.lastRawTranscript,
            currentRawTranscript: text,
            committedTranscript: session.committedTranscript
        )
        session.recordRawTranscript(text)

        DebugLogger.shared.debug(
            "Realtime textbox consume -> chars: \(text.count), committedChars: \(session.committedTranscript.count), deltaChars: \(delta.count), terminalLike: \(session.isTerminalLike)",
            source: "RealtimeTextbox"
        )

        guard !delta.isEmpty else { return }
        if let driftReason = RealtimeTextboxDriftDetector.driftReason(session: session) {
            DebugLogger.shared.warning(
                "Realtime textbox consume -> rolling to new sub-session because \(driftReason)",
                source: "RealtimeTextbox"
            )
            self.rollSession(afterDriftReason: driftReason, baselineTranscript: text)
            return
        }

        _ = self.sink.typeDelta(delta, targetPID: session.targetPID)
        session.appendCommittedDelta(delta, sourceTranscript: text)
    }

    func finalizeSession(with finalText: String) {
        guard let session = self.activeSession else { return }

        let safeForReplacement = RealtimeTextboxDriftDetector.isSafeForFinalReplacement(session: session)
        DebugLogger.shared.info(
            "Realtime textbox finalize -> finalChars: \(finalText.count), typedChars: \(session.typedText.count), safeForReplacement: \(safeForReplacement), replacementState: \(session.replacementState.description)",
            source: "RealtimeTextbox"
        )

        if finalText != session.typedText {
            guard safeForReplacement else {
                session.markReplacementUnavailable("Final replacement skipped because target drifted")
                DebugLogger.shared.warning(
                    "Realtime textbox finalize -> skipped delete/retype because target is no longer safe",
                    source: "RealtimeTextbox"
                )
                self.activeSession = nil
                return
            }

            _ = self.sink.typeFinalReplacement(
                finalText,
                replacingCount: session.typedText.count,
                targetPID: session.targetPID
            )
            session.replaceTypedText(with: finalText)
        }

        self.activeSession = nil
    }

    func cancelAndRevertSession() {
        guard let session = self.activeSession else { return }

        let safeForReplacement = RealtimeTextboxDriftDetector.isSafeForFinalReplacement(session: session)
        DebugLogger.shared.info(
            "Realtime textbox cancel -> typedChars: \(session.typedText.count), safeForRevert: \(safeForReplacement), replacementState: \(session.replacementState.description)",
            source: "RealtimeTextbox"
        )

        if !session.typedText.isEmpty, safeForReplacement {
            _ = self.sink.deleteTypedText(count: session.typedText.count, targetPID: session.targetPID)
        } else if !session.typedText.isEmpty {
            DebugLogger.shared.warning(
                "Realtime textbox cancel -> skipped typed text cleanup because target is no longer safe",
                source: "RealtimeTextbox"
            )
        }

        self.activeSession = nil
    }

    func cancelSession() {
        if self.activeSession != nil {
            DebugLogger.shared.debug("Realtime textbox session cancelled", source: "RealtimeTextbox")
        }
        self.activeSession = nil
    }

    private func stabilizedDelta(
        previousRawTranscript: String,
        currentRawTranscript: String,
        committedTranscript: String
    ) -> String {
        let normalizedCurrent = currentRawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedCurrent.isEmpty else { return "" }
        guard !previousRawTranscript.isEmpty else { return "" }

        let stablePrefix = self.stableWordPrefix(previous: previousRawTranscript, current: currentRawTranscript)
        guard !stablePrefix.isEmpty else { return "" }
        guard stablePrefix.count > committedTranscript.count else { return "" }
        guard stablePrefix.hasPrefix(committedTranscript) else { return "" }

        return String(stablePrefix.dropFirst(committedTranscript.count))
    }

    private func stableWordPrefix(previous: String, current: String) -> String {
        let previousWords = self.wordRanges(in: previous)
        let currentWords = self.wordRanges(in: current)
        guard !previousWords.isEmpty, !currentWords.isEmpty else { return "" }

        var matchedWordCount = 0
        while matchedWordCount < previousWords.count, matchedWordCount < currentWords.count {
            let previousWord = String(previous[previousWords[matchedWordCount]])
            let currentWord = String(current[currentWords[matchedWordCount]])
            guard previousWord == currentWord else { break }
            matchedWordCount += 1
        }

        guard matchedWordCount > 0 else { return "" }
        let stableEndIndex = currentWords[matchedWordCount - 1].upperBound
        return String(current[..<stableEndIndex])
    }

    private func wordRanges(in text: String) -> [Range<String.Index>] {
        guard let regex = try? NSRegularExpression(pattern: #"\S+"#) else { return [] }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: nsRange).compactMap { match in
            Range(match.range, in: text)
        }
    }

    private func ensureSessionForStreaming(baselineTranscript: String) -> RealtimeTextboxSession? {
        if let session = self.activeSession, session.canAttemptReplacement {
            return session
        }

        guard let session = RealtimeTextboxSession.captureCurrent() else {
            self.activeSession = nil
            DebugLogger.shared.warning(
                "Realtime textbox consume -> unable to capture a fresh session for streaming",
                source: "RealtimeTextbox"
            )
            return nil
        }

        session.seedTranscriptBaseline(baselineTranscript)
        self.activeSession = session
        DebugLogger.shared.info(
            "Realtime textbox consume -> started fresh sub-session",
            source: "RealtimeTextbox"
        )
        return session
    }

    private func rollSession(afterDriftReason reason: String, baselineTranscript: String) {
        self.activeSession?.markReplacementUnavailable(reason)

        guard let nextSession = RealtimeTextboxSession.captureCurrent() else {
            self.activeSession = nil
            DebugLogger.shared.warning(
                "Realtime textbox consume -> drifted and could not capture replacement sub-session",
                source: "RealtimeTextbox"
            )
            return
        }

        nextSession.seedTranscriptBaseline(baselineTranscript)
        self.activeSession = nextSession
        DebugLogger.shared.info(
            "Realtime textbox consume -> replacement sub-session ready after drift",
            source: "RealtimeTextbox"
        )
    }
}
