import DukouCore
import Foundation

/// Finds a forward made by hand among the rows of WeChat's own message
/// database, and says which voice message is which row.
///
/// The TXT is the selected messages in the conversation's order, and every
/// one of them is a row of that conversation's table. So a reading of it — an
/// embedding — puts every message, in order, on strictly increasing rows of
/// one table, each on a row it agrees with:
///
/// - a voice message on a voice row whose length rounds to the TXT's `N"`
///   (within 0.6 s; WeChat writes a voice shorter than a second as 1");
/// - a text on a text row that says the same after whitespace folding, with
///   or without a group chat's `<sender>:\n`, or on an app message whose
///   title says it (a quote reply's TXT line is its title);
/// - anything else the TXT cannot predict a row for on any row that could be
///   selected — every row but a system notice;
/// - and, when the TXT gives each message's time — to the minute, in the
///   layout with senders — only on a row sent in that minute, give or take
///   one. Checked against a real export: every message sat between 4 and 36
///   seconds past the minute it was written under.
///
/// Rows between the messages are ones the user did not select, and notices.
/// The reading taken is the tightest: of all embeddings in all the tables,
/// those whose first and last rows are closest. A voice message gets a
/// transcript only when every tightest embedding puts it on a row with that
/// same transcript; when they all put it on rows never converted it is
/// counted as such, and otherwise it is left as it is.
///
/// A TXT with no text in it and fewer than three voice messages says too
/// little for the tightest reading to be trusted — two 4" messages are
/// everywhere — so for it every embedding counts, not just the tightest.
///
/// Times matter most where there is no text: a few voice messages alone fit
/// somewhere in almost any long history. Measured on a real one, four whose
/// own rows were not in the database fitted, spread over 369 rows, into a
/// conversation a year and a half older; with their times they fit nowhere.
public enum WeChatDatabaseMatch {
    typealias Message = WeChatVoiceMatch.Message

    public struct Summary: Equatable, Sendable {
        public var voiceLines = 0
        public var attached = 0
        public var notConverted = 0
        public var ambiguous = 0

        public init(voiceLines: Int = 0, attached: Int = 0, notConverted: Int = 0, ambiguous: Int = 0) {
            self.voiceLines = voiceLines
            self.attached = attached
            self.notConverted = notConverted
            self.ambiguous = ambiguous
        }
    }

    enum Verdict: Equatable {
        case transcript(String)
        case notConverted
        case ambiguous
    }

    /// Past this much work for one file the export is taken as not pinned
    /// down at all: every voice message ambiguous. Only a selection of a
    /// couple of voice messages among many images in a long run of images
    /// comes near it.
    static let workLimit = 40_000_000

    /// Per voice message (by index into `messages`), its verdict. Nil when no
    /// table embeds the export. `tables` are rows oldest first; `minutes`,
    /// when the TXT has them, the start of each message's minute in seconds
    /// since 1970.
    static func verdicts(_ messages: [Message], minutes: [Int64]? = nil, in tables: [[WeChatDatabaseRow]]) -> [Int: Verdict]? {
        let voices = messages.indices.filter { messages[$0].seconds != nil }
        let weak = !messages.contains { if case .text = $0 { true } else { false } } && voices.count < 3
        let lookup = Lookup(messages, minutes: minutes)
        var candidates: [Int: [WeChatDatabaseRow]] = [:]
        var best = Int.max, embedded = false, work = 0
        for rows in tables {
            let fit = lookup.fit(rows)
            if weak {
                guard let held = everyEmbedding(fit, count: messages.count, rows: rows.count) else { continue }
                embedded = true
                for index in voices { candidates[index, default: []] += held[index].map { rows[$0] } }
                continue
            }
            guard let windows = tightest(fit, count: messages.count, rows: rows.count) else { continue }
            embedded = true
            guard windows.span <= best else { continue }
            if windows.span < best { best = windows.span; candidates = [:] }
            for end in windows.ends {
                work += messages.count * (windows.span + 1)
                guard work <= workLimit else { return Dictionary(uniqueKeysWithValues: voices.map { ($0, .ambiguous) }) }
                let start = end - windows.span
                let held = embeddings(fit, count: messages.count, from: start, through: end)
                for index in voices { candidates[index, default: []] += held[index].map { rows[$0] } }
            }
        }
        guard embedded else { return nil }
        return Dictionary(uniqueKeysWithValues: voices.map { index in
            let transcripts = Set((candidates[index] ?? []).map { row -> String in
                if case .voice(_, let transcript) = row.kind { transcript } else { "" }
            })
            guard transcripts.count == 1, let transcript = transcripts.first else { return (index, .ambiguous) }
            return (index, transcript.isEmpty ? .notConverted : .transcript(transcript))
        })
    }

    // MARK: - Agreement

    /// Sent in the minute that starts at `minute`, with a minute's slack
    /// either side.
    static func within(_ time: Int64?, minute: Int64) -> Bool {
        guard let time else { return false }
        return time >= minute - 60 && time < minute + 120
    }

    static func agrees(_ message: Message, _ row: WeChatDatabaseRow) -> Bool {
        switch (message, row.kind) {
        case (_, .system): return false
        case (.opaque, _): return true
        case (.voice(let seconds), .voice(let milliseconds, _)):
            return abs(max(Double(milliseconds) / 1000, 1) - Double(seconds)) <= 0.6
        case (.text(let text), .text(let whole, let afterSender)): return whole == text || afterSender == text
        case (.text(let text), .app(let title)): return title == text
        default: return false
        }
    }

    /// `agrees` for a whole table at once, with each of the export's texts
    /// looked up once per row rather than compared against every row.
    struct Lookup {
        let messages: [Message]
        let minutes: [Int64]?
        let texts: [String: [Int]]

        init(_ messages: [Message], minutes: [Int64]? = nil) {
            self.messages = messages
            self.minutes = minutes.flatMap { $0.count == messages.count ? $0 : nil }
            var texts: [String: [Int]] = [:]
            for (index, message) in messages.enumerated() {
                if case .text(let text) = message { texts[text, default: []].append(index) }
            }
            self.texts = texts
        }

        /// `fit[i][p]`: message i agrees with row p.
        func fit(_ rows: [WeChatDatabaseRow]) -> Fit {
            var fit = Fit(rows: rows, messages: messages.count)
            for (p, row) in rows.enumerated() {
                switch row.kind {
                case .system: continue
                case .text(let whole, let afterSender):
                    for index in Set((texts[whole] ?? []) + (afterSender.flatMap { texts[$0] } ?? [])) { fit[index, p] = true }
                case .app(let title):
                    for index in title.flatMap({ texts[$0] }) ?? [] { fit[index, p] = true }
                case .voice, .other: break
                }
                for (index, message) in messages.enumerated() {
                    switch message {
                    case .opaque: fit[index, p] = true
                    case .voice: if WeChatDatabaseMatch.agrees(message, row) { fit[index, p] = true }
                    case .text: break
                    }
                }
                if let minutes {
                    for index in messages.indices where fit[index, p] && !WeChatDatabaseMatch.within(row.time, minute: minutes[index]) {
                        fit[index, p] = false
                    }
                }
            }
            return fit
        }
    }

    struct Fit {
        let rows: [WeChatDatabaseRow]
        let messages: Int
        private var cells: [Bool]

        init(rows: [WeChatDatabaseRow], messages: Int) {
            self.rows = rows
            self.messages = messages
            cells = Array(repeating: false, count: rows.count * messages)
        }

        subscript(message: Int, row: Int) -> Bool {
            get { cells[message * rows.count + row] }
            set { cells[message * rows.count + row] = newValue }
        }
    }

    // MARK: - Embeddings

    /// The smallest span of any embedding in this table, and the last row of
    /// every embedding with that span. Nil when none fits.
    ///
    /// `latest[p]`, for message i on row p: the latest first row any
    /// embedding of messages 0...i ending there can have. One pass per
    /// message with a running maximum, so n × rows in all.
    static func tightest(_ fit: Fit, count n: Int, rows r: Int) -> (span: Int, ends: [Int])? {
        guard n > 0, r > 0 else { return nil }
        var latest = (0..<r).map { fit[0, $0] ? $0 : -1 }
        for i in 1..<n {
            var next = Array(repeating: -1, count: r), running = -1
            for p in 0..<r {
                if fit[i, p] { next[p] = running }
                running = max(running, latest[p])
            }
            latest = next
        }
        var span = Int.max, ends: [Int] = []
        for p in 0..<r where latest[p] >= 0 {
            let width = p - latest[p]
            if width < span { span = width; ends = [p] } else if width == span { ends.append(p) }
        }
        return ends.isEmpty ? nil : (span, ends)
    }

    /// For each message, the rows it sits on across every embedding that
    /// starts on row `start` and ends on row `end`: those it can be reached
    /// on from the front and from the back. A tightest window holds no
    /// embedding that does not start and end on its edges.
    static func embeddings(_ fit: Fit, count n: Int, from start: Int, through end: Int) -> [[Int]] {
        reachable(fit, count: n, rows: start...end, pinned: true)
    }

    /// The same over a whole table, for every embedding of any span. Nil when
    /// none fits.
    static func everyEmbedding(_ fit: Fit, count n: Int, rows r: Int) -> [[Int]]? {
        guard r > 0 else { return nil }
        let rows = reachable(fit, count: n, rows: 0...(r - 1), pinned: false)
        return rows.allSatisfy({ !$0.isEmpty }) ? rows : nil
    }

    /// `forward[i][p]`: messages 0...i fit rows `range.lowerBound...p` with i
    /// on p; `backward` the same from the end. `pinned` makes the first
    /// message start the range and the last end it.
    static func reachable(_ fit: Fit, count n: Int, rows range: ClosedRange<Int>, pinned: Bool) -> [[Int]] {
        let lower = range.lowerBound, width = range.count
        var forward = Array(repeating: Array(repeating: false, count: width), count: n)
        var backward = forward
        for i in 0..<n {
            var open = false
            for q in 0..<width {
                let p = lower + q
                if i == 0 {
                    forward[0][q] = fit[0, p] && (!pinned || q == 0)
                } else {
                    forward[i][q] = fit[i, p] && open
                    open = open || forward[i - 1][q]
                }
            }
        }
        for i in stride(from: n - 1, through: 0, by: -1) {
            var open = false
            for q in stride(from: width - 1, through: 0, by: -1) {
                let p = lower + q
                if i == n - 1 {
                    backward[i][q] = fit[i, p] && (!pinned || q == width - 1)
                } else {
                    backward[i][q] = fit[i, p] && open
                    open = open || backward[i + 1][q]
                }
            }
        }
        return (0..<n).map { i in (0..<width).filter { forward[i][$0] && backward[i][$0] }.map { lower + $0 } }
    }
}
