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

    /// The same for a forward made by hand, from what `WeChatListObserver`
    /// saw of the conversation; see `WeChatVoiceMatch`. Counts only.
    static func mergeObservedVoiceTranscripts(_ evidence: WeChatListEvidence, directory: URL) -> [String: Any] {
        var report: [String: Any] = ["kind": "voice-transcripts", "source": "observed-list",
                                     "stretches": evidence.stretches.count, "rows": evidence.rowCount]
        do {
            switch try WeChatVoiceMatch.merge(evidence, intoReceiptAt: directory) {
            case .noVoiceLines: report["outcome"] = "no-voice"
            case .alreadyMerged: report["outcome"] = "already-merged"
            case .unreadable: report["outcome"] = "unreadable"
            case .notObserved(let voiceLines): report["outcome"] = "not-observed"; report["inExport"] = voiceLines
            case .inconsistent(let voiceLines): report["outcome"] = "inconsistent"; report["inExport"] = voiceLines
            case .matched(let summary):
                report["outcome"] = summary.attached > 0 ? "merged" : "unmatched"
                report["inExport"] = summary.voiceLines
                report["merged"] = summary.attached
                report["notConverted"] = summary.notConverted
                report["ambiguous"] = summary.ambiguous
                report["unseen"] = summary.unseen
            }
        } catch {
            report["outcome"] = "failed"
        }
        return report
    }

    /// Beside latest.json, which belongs to quick forward: the last forward
    /// made by hand that Dukou looked at. Same privacy — counts, never text.
    static func recordManualForward(_ steps: [[String: Any]], observer: [String: Any]) {
        let report: [String: Any] = ["schemaVersion": 1, "at": ISO8601DateFormatter().string(from: Date()),
                                     "steps": steps, "observer": observer]
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Dukou/WeChat")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: folder.appendingPathComponent("manual-forward.json"), options: .atomic)
        }
    }
}
