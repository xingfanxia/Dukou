import DukouCore
import Foundation

enum WeChatArchive {
    /// The native ZIP is the payload. Text parsing only supplies a display
    /// count; it must not decide whether a message format can be delivered.
    static func messageCount(directory: URL, cancellation: WeChatCancellation) throws -> Int? {
        do {
            return try WeChatNativeArchive.messageCount(WeChatNativeArchive.receipt(at: directory).data, checkCancellation: cancellation.check)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw WeChatAutomationError.invalidArchive
        }
    }

    /// Adds the transcripts of the batch's converted voice messages, read off
    /// its rows (`rows`, oldest first; nil when the walk could not vouch for
    /// every selected row), to the batch's own TXT. Says what happened, for
    /// latest.json — counts only, never what anyone said.
    ///
    /// Throws only cancellation. A merge that cannot be made leaves the export
    /// as WeChat wrote it, and the forward goes on with that.
    static func mergeVoiceTranscripts(rows: [String]?, directory: URL, cancellation: WeChatCancellation) throws -> [String: Any] {
        var report: [String: Any] = ["kind": "voice-transcripts"]
        guard let rows else {
            report["outcome"] = "walk-incomplete"
            return report
        }
        let voices = rows.compactMap(WeChatVoiceMessage.parse(row:))
        report["onScreen"] = voices.count
        report["converted"] = voices.filter { !$0.transcript.isEmpty }.count
        do {
            switch try WeChatVoiceTranscripts.merge(voices, intoReceiptAt: directory, checkCancellation: cancellation.check) {
            case .noVoiceMessages: report["outcome"] = "no-voice"
            case .noTranscripts: report["outcome"] = "no-transcripts"
            case .merged(_, let transcripts): report["outcome"] = "merged"; report["merged"] = transcripts
            case .mismatch(let inExport, _, let firstDifference):
                report["outcome"] = "mismatch"; report["inExport"] = inExport
                if let firstDifference { report["firstDifference"] = firstDifference }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            report["outcome"] = "failed"
        }
        return report
    }
}
