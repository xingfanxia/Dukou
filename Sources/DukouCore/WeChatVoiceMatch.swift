import Foundation

/// Puts transcripts into a forward the user made by hand, from what
/// `WeChatListMemory` saw of the conversation while they made it.
///
/// Dukou did not select these messages, so nothing says which rows they were.
/// Each voice line of the TXT gets a transcript only when what was seen pins
/// it to one row; anything less and the line stays exactly as WeChat wrote it.
/// Other lines are never touched, and the text goes in the way
/// `WeChatVoiceTranscripts` puts it: `[语音] 18" 转文字：…`.
///
/// What pins a line, for each stretch of rows seen without a gap:
///
/// - The TXT is the selected messages in the conversation's order, so its
///   messages that fall inside a stretch are a run of it, row for row in
///   order. A row can be read as a message only when they agree: the same
///   duration for a voice message, the same text for a text message (after
///   the sender's name in multi-select). Rows not yet filled in, and the
///   TXT's images, cards and other markers, agree with anything.
/// - In multi-select a ticked row is one of the messages and an unticked one
///   is not, where `WeChatListMemory` still knows which it is. Every message
///   between two ticked rows is then inside the stretch too, and must be read
///   off the rows between them.
/// - A text the TXT has once is that message on the one ticked row that says
///   it: an anchor. Where no ticked row says it, a rare text (`isRare`) said
///   by exactly one row of the stretch is taken as that message too, ticked
///   or not, in multi-select or out of it. An anchor is inside the stretch,
///   and so is every message between two anchors.
///
/// A voice line is pinned when every reading consistent with all of that puts
/// it on a row, and every such row has the same transcript. A message may lie
/// outside a stretch whenever nothing forces it in: the user may have ticked
/// messages far apart, identical short texts such as 好的 recur, and so do
/// stock replies such as 收到，谢谢老师 — so a short or plain text anchors
/// only where ticked, and a voice line before a stretch's first anchor or
/// ticked row, or after its last, stays as it is.
///
/// Ticks no reading fits are dropped for that stretch, which is then read off
/// its rare texts alone: a selection can change where Dukou cannot see it. A
/// stretch no reading fits even then is wrong somewhere and says nothing; the
/// others still count.
public enum WeChatVoiceMatch {
    /// Per voice line of the export, and the stretches that had to be read
    /// otherwise than as seen.
    public struct Summary: Equatable, Sendable {
        public var voiceLines = 0
        /// Given a transcript.
        public var attached = 0
        /// Pinned to a row that was never converted.
        public var notConverted = 0
        /// Seen on a row that might be it, but not pinned to one.
        public var ambiguous = 0
        /// No row seen could have been it.
        public var unseen = 0
        /// Stretches read without their ticks, which no reading fitted.
        public var ticksIgnored = 0
        /// Stretches no reading fitted even without ticks, and skipped.
        public var contradicting = 0

        public init(voiceLines: Int = 0, attached: Int = 0, notConverted: Int = 0, ambiguous: Int = 0, unseen: Int = 0,
                    ticksIgnored: Int = 0, contradicting: Int = 0) {
            self.voiceLines = voiceLines
            self.attached = attached
            self.notConverted = notConverted
            self.ambiguous = ambiguous
            self.unseen = unseen
            self.ticksIgnored = ticksIgnored
            self.contradicting = contradicting
        }
    }

    public enum Outcome: Equatable, Sendable {
        case noVoiceLines
        /// A transcript is already on one of its voice lines: a quick
        /// forward's, or this very batch again. Left alone.
        case alreadyMerged
        /// Its messages could not be told apart reliably.
        case unreadable
        /// Nothing of this conversation was seen.
        case notObserved(voiceLines: Int)
        /// Nothing was attached, and some stretch of what was seen
        /// contradicts the export even without its ticks.
        case inconsistent(voiceLines: Int)
        case matched(Summary)
    }

    /// `text` is the export's TXT as bytes; see `WeChatVoiceTranscripts.merge`.
    public static func merge(_ evidence: WeChatListEvidence, into text: Data) -> (text: Data, outcome: Outcome) {
        guard let body = normalized(text) else { return (text, .unreadable) }
        if body.split(separator: "\n", omittingEmptySubsequences: false).contains(where: WeChatVoiceTranscripts.isMergedVoiceLine) {
            return (text, .alreadyMerged)
        }
        let lines = WeChatVoiceTranscripts.voiceLines(in: text)
        guard !lines.isEmpty else { return (text, .noVoiceLines) }
        guard let messages = messages(in: body),
              messages.compactMap(\.seconds) == lines.map(\.seconds) else { return (text, .unreadable) }
        guard evidence.rowCount > 0 else { return (text, .notObserved(voiceLines: lines.count)) }

        var summary = Summary(voiceLines: lines.count)
        var verdicts = Array(repeating: [Verdict](), count: messages.count)
        for stretch in evidence.stretches where !stretch.rows.isEmpty {
            guard let reading = read(stretch, as: messages) else { summary.contradicting += 1; continue }
            if reading.withoutTicks { summary.ticksIgnored += 1 }
            for (index, verdict) in reading.verdicts { verdicts[index].append(verdict) }
        }

        var added: [Int: String] = [:]
        let voices = messages.indices.filter { messages[$0].seconds != nil }
        for (ordinal, index) in voices.enumerated() {
            switch combine(verdicts[index]) {
            case .pinned(let transcript) where !transcript.isEmpty:
                added[ordinal] = transcript
                summary.attached += 1
            case .pinned: summary.notConverted += 1
            case .open: summary.ambiguous += 1
            case .unseen: summary.unseen += 1
            }
        }
        guard !added.isEmpty else {
            return (text, summary.contradicting > 0 ? .inconsistent(voiceLines: lines.count) : .matched(summary))
        }
        return (WeChatVoiceTranscripts.insert(added, into: text, at: lines), .matched(summary))
    }

    /// The receipt at `directory` — from any entry — with its TXT rewritten
    /// in place when `merge` attached anything, exactly as
    /// `WeChatVoiceTranscripts.merge(_:intoReceiptAt:)` does for a quick
    /// forward; untouched in every other outcome and whenever this throws.
    /// `original` is handed the TXT as WeChat wrote it, before the merge.
    public static func merge(_ evidence: WeChatListEvidence, intoReceiptAt directory: URL,
                             checkCancellation: () throws -> Void = {}, original: (Data) -> Void = { _ in }) throws -> Outcome {
        try WeChatVoiceTranscripts.rewriteTranscript(
            ofReceiptAt: directory, accepting: Set(ShareAction.allCases), checkCancellation: checkCancellation,
            withoutTranscript: .noVoiceLines
        ) { transcript in
            original(transcript)
            let (text, outcome) = merge(evidence, into: transcript)
            return (text, outcome)
        }
    }

    // MARK: - The export

    /// The TXT as `messages(in:)` reads it, or nil when it is not UTF-8.
    package static func normalized(_ text: Data) -> String? {
        guard var body = String(data: text, encoding: .utf8) else { return nil }
        // A CRLF is one Character to Swift and would never split on "\n".
        body = body.replacingOccurrences(of: "\r\n", with: "\n")
        if body.hasPrefix("\u{feff}") { body.removeFirst() }
        return body
    }

    /// A message of the export, as far as matching needs it.
    package enum Message: Equatable {
        case voice(seconds: Int)
        /// One line of plain text, whitespace folded.
        case text(String)
        /// Anything whose row cannot be predicted from the TXT: images,
        /// files, cards, emoji, several lines.
        case opaque

        package var seconds: Int? { if case .voice(let seconds) = self { seconds } else { nil } }
    }

    /// Nil when the layout is not one WeChat writes. With senders and times
    /// each message is a record; without, each starts with `·` at the start
    /// of a line, first or after an empty one, and an indented line belongs
    /// to the card above it.
    /// `body` has LF line ends and no byte order mark.
    package static func messages(in body: String) -> [Message]? {
        if let records = try? WeChatTranscriptRecord.parse(body) { return records.map { message(from: $0.text) } }
        var bodies: [[Substring]] = []
        var afterBlank = true
        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            if afterBlank, line.first == "·" {
                bodies.append([line.dropFirst()])
            } else if !line.isEmpty {
                guard !bodies.isEmpty else { return nil }
                bodies[bodies.count - 1].append(line)
            }
            afterBlank = line.isEmpty
        }
        return bodies.isEmpty ? nil : bodies.map { message(from: $0.joined(separator: "\n")) }
    }

    static func message(from text: String) -> Message {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.contains("\n"), let seconds = WeChatVoiceTranscripts.seconds(inVoiceLine: trimmed) { return .voice(seconds: seconds) }
        if trimmed.isEmpty || trimmed.contains("\n") || trimmed.contains("[") { return .opaque }
        return .text(folded(trimmed))
    }

    // MARK: - Text

    /// Whitespace runs, line breaks included, as one space; trimmed.
    package static func folded(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    }

    /// Long and varied enough that two looks agreeing on it, among rows that
    /// moved with it, are unlikely to be two messages. Not enough to take it
    /// as said once in a conversation; see `isRare`.
    static func isDistinctive(_ text: String) -> Bool {
        text.count >= 6 && Set(text.filter { $0.isLetter || $0.isNumber }).count >= 4
    }

    /// Long enough to take as said once where it is seen once: a stock reply
    /// such as 收到，谢谢老师 is shorter. See `anchors`.
    static func isRare(_ text: String) -> Bool {
        text.count >= 8 && isDistinctive(text)
    }

    /// Whether `row` reads as `message` — never false for the row it is.
    static func agrees(_ message: Message, _ row: WeChatObservedRow, multiSelect: Bool) -> Bool {
        if row.title.isEmpty { return true }
        switch message {
        case .opaque: return true
        case .voice(let seconds): return row.voice?.seconds == seconds
        case .text(let text): return says(row, text, multiSelect: multiSelect)
        }
    }

    /// Outside multi-select a text row is the message's text exactly; in it,
    /// the sender's name and a space come first.
    static func says(_ row: WeChatObservedRow, _ text: String, multiSelect: Bool) -> Bool {
        row.title == text || (multiSelect && row.title.hasSuffix(" " + text))
    }

    // MARK: - Anchors

    /// The stretch's anchors: message → row. A ticked row is one of the
    /// exported messages, so when it says a text the export has exactly
    /// once, it is that message — however often the rest of the conversation
    /// says the same. Where no ticked row says it, a rare text said by
    /// exactly one row not known to be unticked is taken as that message on
    /// that row: no text can be shown to be said once in a whole
    /// conversation, but a long one seen once among rows seen without a gap
    /// seldom is twice. A row that
    /// says two such texts (a sender's name runs into the text in
    /// multi-select) anchors nothing, and nor does a text two of the rows it
    /// would be taken from say.
    static func anchors(_ messages: [Message], in stretch: WeChatObservedStretch) -> [Int: Int] {
        var counts: [String: Int] = [:]
        for case .text(let text) in messages { counts[text, default: 0] += 1 }
        var anchors: [Int: Int] = [:], taken = Set<Int>(), shared = Set<Int>()
        for (index, message) in messages.enumerated() {
            guard case .text(let text) = message, counts[text] == 1 else { continue }
            let saying = stretch.rows.indices.filter { stretch.rows[$0].ticked != false && says(stretch.rows[$0], text, multiSelect: stretch.multiSelect) }
            let ticked = saying.filter { stretch.rows[$0].ticked == true }
            let rows = ticked.isEmpty && isRare(text) ? saying : ticked
            guard rows.count == 1, let row = rows.first else { continue }
            if !taken.insert(row).inserted { shared.insert(row) }
            anchors[index] = row
        }
        return anchors.filter { !shared.contains($0.value) }
    }

    // MARK: - Readings

    enum Verdict: Equatable {
        /// On a row in every reading, each with this transcript.
        case pinned(String)
        /// On some row in some reading, or outside the stretch in another.
        case open
        case unseen
    }

    /// What `stretch` says of the voice messages: as seen, or, when no
    /// reading fits its ticks, without them — anchors found again, so rare
    /// texts alone. Nil when no reading fits even then. `anchors` are the
    /// ones the verdicts were read with.
    static func read(_ stretch: WeChatObservedStretch, as messages: [Message])
        -> (verdicts: [(Int, Verdict)], anchors: [Int: Int], withoutTicks: Bool)? {
        let seen = anchors(messages, in: stretch)
        if let verdicts = verdictsOfVoices(messages, in: stretch, anchors: seen) { return (verdicts, seen, false) }
        guard stretch.rows.contains(where: { $0.ticked != nil }) else { return nil }
        let unticked = WeChatObservedStretch(multiSelect: stretch.multiSelect,
                                             rows: stretch.rows.map { WeChatObservedRow(title: $0.title, voice: $0.voice) })
        let rare = anchors(messages, in: unticked)
        return verdictsOfVoices(messages, in: unticked, anchors: rare).map { ($0, rare, true) }
    }

    /// For each voice message, what the stretch says of it. Nil when no
    /// reading fits the stretch at all.
    ///
    /// A reading puts a run of the export, `lo...hi`, on rows in order, each
    /// on a row it agrees with; every anchor in the stretch on its row, ticked
    /// or not, so the run reaches from the first anchor to the last; every
    /// ticked row under a message and no unticked one. The messages before
    /// `lo` and after `hi` are outside the stretch. `reach` and `back` are the
    /// two halves: whether a reading's first part can end with message `i` on
    /// row `p`, and whether its last part can start there.
    static func verdictsOfVoices(_ messages: [Message], in stretch: WeChatObservedStretch,
                                 anchors anchorRow: [Int: Int]) -> [(Int, Verdict)]? {
        let rows = stretch.rows, n = messages.count, r = rows.count
        let anchorOfRow = Dictionary(uniqueKeysWithValues: anchorRow.map { ($0.value, $0.key) })
        let must = rows.indices.map { rows[$0].ticked == true || anchorOfRow[$0] != nil }
        let fit = messages.indices.map { i in
            rows.indices.map { p in
                rows[p].ticked != false && agrees(messages[i], rows[p], multiSelect: stretch.multiSelect)
                    && (anchorRow[i].map { $0 == p } ?? true) && (anchorOfRow[p].map { $0 == i } ?? true)
            }
        }
        func fits(_ i: Int, _ p: Int) -> Bool { fit[i][p] }
        // A row that has to be read before `p`, after `p`.
        var mustBefore = Array(repeating: false, count: r), mustAfter = Array(repeating: false, count: r)
        for p in 1..<max(1, r) { mustBefore[p] = mustBefore[p - 1] || must[p - 1] }
        for p in stride(from: r - 2, through: 0, by: -1) { mustAfter[p] = mustAfter[p + 1] || must[p + 1] }
        let firstAnchor = anchorRow.keys.min() ?? n, lastAnchor = anchorRow.keys.max() ?? -1
        func opens(_ i: Int, _ p: Int) -> Bool { !mustBefore[p] && i <= firstAnchor }
        func closes(_ i: Int, _ p: Int) -> Bool { !mustAfter[p] && i >= lastAnchor }

        var reach = Array(repeating: Array(repeating: false, count: r), count: n)
        var back = reach
        for i in 0..<n {
            // Some row before `p` held message i - 1, with nothing that had
            // to be read between them.
            var open = false
            for p in 0..<r {
                reach[i][p] = fits(i, p) && (opens(i, p) || open)
                if i > 0 { open = reach[i - 1][p] || (open && !must[p]) }
            }
        }
        for i in stride(from: n - 1, through: 0, by: -1) {
            var open = false
            for p in stride(from: r - 1, through: 0, by: -1) {
                back[i][p] = fits(i, p) && (closes(i, p) || open)
                if i + 1 < n { open = back[i + 1][p] || (open && !must[p]) }
            }
        }

        let empty = !must.contains(true)
        var fitsAtAll = empty
        // Whether a whole reading can end at message i, or start there.
        var ends = Array(repeating: false, count: n), starts = Array(repeating: false, count: n)
        for i in 0..<n {
            for p in 0..<r {
                if reach[i][p] && back[i][p] { fitsAtAll = true }
                if reach[i][p] && closes(i, p) { ends[i] = true }
                if back[i][p] && opens(i, p) { starts[i] = true }
            }
        }
        guard fitsAtAll else { return nil }
        var endsBefore = Array(repeating: false, count: n + 1), startsAfter = Array(repeating: false, count: n + 1)
        for i in 0..<n { endsBefore[i + 1] = endsBefore[i] || ends[i] }
        for i in stride(from: n - 1, through: 0, by: -1) { startsAfter[i] = startsAfter[i + 1] || starts[i] }

        return messages.indices.compactMap { i in
            guard messages[i].seconds != nil else { return nil }
            let candidates = rows.indices.filter { reach[i][$0] && back[i][$0] }
            if candidates.isEmpty { return (i, .unseen) }
            let outside = empty || endsBefore[i] || startsAfter[i + 1]
            let read = candidates.map { rows[$0] }
            guard !outside, read.allSatisfy({ $0.voice != nil }),
                  let transcript = read.first?.voice?.transcript,
                  read.allSatisfy({ $0.voice?.transcript == transcript }) else { return (i, .open) }
            return (i, .pinned(transcript))
        }
    }

    /// Stretches can overlap, so one row may have been read at different
    /// times, and a transcript that grew is the same row's. Any other
    /// disagreement leaves the line alone — one never converted against one
    /// that was included: they may be two messages.
    static func combine(_ verdicts: [Verdict]) -> Verdict {
        var pinned: String?
        for case .pinned(let transcript) in verdicts {
            guard let current = pinned else { pinned = transcript; continue }
            if current == transcript { continue }
            guard !current.isEmpty, !transcript.isEmpty else { return .open }
            if transcript.hasPrefix(current) { pinned = transcript }
            else if !current.hasPrefix(transcript) { return .open }
        }
        if let pinned { return .pinned(pinned) }
        return verdicts.contains(.open) ? .open : .unseen
    }
}
