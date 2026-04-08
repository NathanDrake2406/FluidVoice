import AppKit
import ApplicationServices
import Foundation

@MainActor
final class RealtimeTextboxSink {
    private let deleteKeyPressDelayMicros: useconds_t = 500
    private let unicodeChunkDelayMicros: useconds_t = 500
    private let maxDeleteBatchSize = 256
    private let unicodeChunkSize = 400

    @discardableResult
    func typeDelta(_ delta: String, targetPID: pid_t?) -> Bool {
        guard !delta.isEmpty else { return true }

        DebugLogger.shared.debug(
            "Realtime textbox typeDelta -> chars: \(delta.count), snippet: '\(RealtimeTextboxSession.snippet(delta))'",
            source: "RealtimeTextbox"
        )
        self.sendUnicodeText(delta, targetPID: targetPID)
        return true
    }

    @discardableResult
    func deleteTypedText(count: Int, targetPID: pid_t?) -> Bool {
        guard count > 0 else { return true }

        DebugLogger.shared.debug(
            "Realtime textbox deleteTypedText -> count: \(count)",
            source: "RealtimeTextbox"
        )
        self.sendDeleteBackward(count: count, targetPID: targetPID)
        return true
    }

    @discardableResult
    func typeFinalReplacement(_ finalText: String, replacingCount: Int, targetPID: pid_t?) -> Bool {
        if replacingCount > 0 {
            self.sendDeleteBackward(count: replacingCount, targetPID: targetPID)
        }
        if !finalText.isEmpty {
            self.sendUnicodeText(finalText, targetPID: targetPID)
        }

        DebugLogger.shared.info(
            "Realtime textbox final replacement -> deletedChars: \(replacingCount), typedChars: \(finalText.count)",
            source: "RealtimeTextbox"
        )
        return true
    }

    private func sendDeleteBackward(count: Int, targetPID: pid_t?) {
        guard count > 0 else { return }

        var remaining = count
        while remaining > 0 {
            let batch = min(remaining, self.maxDeleteBatchSize)
            for _ in 0..<batch {
                guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: 51, keyDown: true),
                      let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: 51, keyDown: false)
                else {
                    return
                }

                if let targetPID, targetPID > 0 {
                    keyDown.postToPid(targetPID)
                    if self.deleteKeyPressDelayMicros > 0 {
                        usleep(self.deleteKeyPressDelayMicros)
                    }
                    keyUp.postToPid(targetPID)
                } else {
                    keyDown.post(tap: .cghidEventTap)
                    if self.deleteKeyPressDelayMicros > 0 {
                        usleep(self.deleteKeyPressDelayMicros)
                    }
                    keyUp.post(tap: .cghidEventTap)
                }
            }

            remaining -= batch
            if remaining > 0 {
                usleep(1000)
            }
        }
    }

    private func sendUnicodeText(_ text: String, targetPID: pid_t?) {
        let utf16 = Array(text.utf16)
        var offset = 0

        while offset < utf16.count {
            let end = min(offset + self.unicodeChunkSize, utf16.count)
            let chunk = Array(utf16[offset..<end])
            self.postUnicodeChunk(chunk, targetPID: targetPID)
            offset = end
        }
    }

    private func postUnicodeChunk(_ utf16Chunk: [UniChar], targetPID: pid_t?) {
        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
        else {
            return
        }

        keyDown.keyboardSetUnicodeString(stringLength: utf16Chunk.count, unicodeString: utf16Chunk)
        keyUp.keyboardSetUnicodeString(stringLength: utf16Chunk.count, unicodeString: utf16Chunk)

        if let targetPID, targetPID > 0 {
            keyDown.postToPid(targetPID)
            if self.unicodeChunkDelayMicros > 0 {
                usleep(self.unicodeChunkDelayMicros)
            }
            keyUp.postToPid(targetPID)
        } else {
            keyDown.post(tap: .cghidEventTap)
            if self.unicodeChunkDelayMicros > 0 {
                usleep(self.unicodeChunkDelayMicros)
            }
            keyUp.post(tap: .cghidEventTap)
        }
    }
}
