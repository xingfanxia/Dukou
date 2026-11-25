import Foundation

/// TEMPORARY, while matching is being tuned on this fork: what `merge` made
/// of a forward, without anything anyone said.
///
/// A forward that attaches nothing gives no reason, and its rows cannot be
/// kept. This keeps what decides the matching instead — kinds, lengths,
/// durations, ticks, and which export message each row agrees with — so an
/// offline replay can build the same readings. Indices are exact: a message
/// is its place in `messages`, a row its place in its stretch's `rows`. No
/// title, text, name or transcript appears, only a transcript's length and
/// a short hash to tell two apart.
extension WeChatVoiceMatch {
    /// JSON-serializable. `text` is the export's TXT as WeChat wrote it.
    public static func explain(_ evidence: WeChatListEvidence, text: Data) -> [String: Any] {
        guard let body = normalized(text), let messages = messages(in: body) else { return ["unreadable": true] }
        var counts: [String: Int] = [:]
        for case .text(let text) in messages { counts[text, default: 0] += 1 }

        var verdicts = Array(repeating: [Verdict](), count: messages.count)
        var stretches: [[String: Any]] = []
        for stretch in evidence.stretches {
            var described: [String: Any] = [
                "multiSelect": stretch.multiSelect,
                "rows": stretch.rows.map { describe($0, against: messages, multiSelect: stretch.multiSelect) },
            ]
            // Anchors as read, or as seen when the stretch was skipped.
            var anchors: [Int: Int] = [:], soft = 0
            if stretch.rows.isEmpty {
                described["result"] = "no-rows"
            } else if let reading = read(stretch, as: messages) {
                described["result"] = reading.withoutTicks ? "read-without-ticks" : "read"
                anchors = reading.anchors
                soft = reading.withoutTicks ? anchors.count : anchors.values.filter { stretch.rows[$0].ticked != true }.count
                for (index, verdict) in reading.verdicts { verdicts[index].append(verdict) }
            } else {
                described["result"] = "contradicting"
                anchors = Self.anchors(messages, in: stretch)
                soft = anchors.values.filter { stretch.rows[$0].ticked != true }.count
            }
            described["anchors"] = ["count": anchors.count, "soft": soft]
            stretches.append(described)
        }

        let exported = messages.indices.map { index -> [String: Any] in
            switch messages[index] {
            case .voice(let seconds):
                let verdict = switch combine(verdicts[index]) {
                case .pinned(let transcript): transcript.isEmpty ? "not-converted" : "attached"
                case .open: "ambiguous"
                case .unseen: "unseen"
                }
                return ["kind": "voice", "seconds": seconds, "verdict": verdict]
            case .text(let text):
                return ["kind": "text", "length": text.count, "rare": isRare(text), "timesInExport": counts[text] ?? 0]
            case .opaque:
                return ["kind": "opaque"]
            }
        }
        return ["messages": exported, "stretches": stretches]
    }

    /// `says` and `agreesVoice` are what `agrees` decides for a row that is
    /// filled in; `contains` are texts the title holds without saying them,
    /// where a format WeChat changed would show.
    static func describe(_ row: WeChatObservedRow, against messages: [Message], multiSelect: Bool) -> [String: Any] {
        var said: [Int] = [], contained: [[String: Int]] = [], sameDuration: [Int] = []
        for (index, message) in messages.enumerated() {
            switch message {
            case .text(let text) where says(row, text, multiSelect: multiSelect):
                said.append(index)
            case .text(let text) where text.count >= 2:
                guard let range = row.title.range(of: text) else { continue }
                contained.append(["message": index, "offset": row.title.distance(from: row.title.startIndex, to: range.lowerBound),
                                  "titleLength": row.title.count])
            case .voice(let seconds) where row.voice?.seconds == seconds:
                sameDuration.append(index)
            default:
                continue
            }
        }
        let voice: Any = row.voice.map {
            ["seconds": $0.seconds, "transcriptLength": $0.transcript.count, "transcriptTag": tag($0.transcript)] as [String: Any]
        } ?? NSNull()
        return [
            "ticked": row.ticked.map { $0 as Any } ?? NSNull(),
            "empty": row.title.isEmpty,
            "length": row.title.count,
            "spaces": row.title.filter { $0 == " " }.count,
            "voice": voice,
            "hasVoiceWordUnparsed": row.voice == nil && row.title.contains("语音"),
            "says": said,
            "contains": contained,
            "agreesVoice": sameDuration,
        ]
    }

    /// The first six hex digits of the 32-bit FNV-1a hash of the UTF-8: two
    /// readings of one transcript match, and different ones almost never do.
    static func tag(_ transcript: String) -> String {
        var hash: UInt32 = 0x811C_9DC5
        for byte in transcript.utf8 { hash = (hash ^ UInt32(byte)) &* 0x0100_0193 }
        let hex = String(hash, radix: 16)
        return String((String(repeating: "0", count: 8 - hex.count) + hex).prefix(6))
    }
}
