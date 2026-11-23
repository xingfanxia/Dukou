import Foundation

/// One row of WeChat's message list as Accessibility reads it (WeChat 4.2.0).
///
/// `title` is the row's AXTitle: a text message's body exactly as the TXT has
/// it without the `·`, `语音18"秒<transcript>` for a voice message, `图片`,
/// `动画表情`; empty while WeChat has not filled the row in. In multi-select
/// the row is a checkbox, `ticked` is its AXValue, and the title starts with
/// the sender's name and a space.
public struct WeChatListRow: Equatable, Sendable {
    public let title: String
    /// Nil outside multi-select.
    public let ticked: Bool?
    public let y: Double
    public let height: Double
    /// Read once, since a look is compared many times over: the title with
    /// whitespace folded, and as a voice message.
    let folded: String
    let voice: WeChatVoiceMessage?

    public init(title: String, ticked: Bool? = nil, y: Double, height: Double) {
        self.title = title
        self.ticked = ticked
        self.y = y
        self.height = height
        folded = WeChatVoiceMatch.folded(title)
        voice = folded.isEmpty ? nil : WeChatVoiceMessage.parse(row: title)
    }
}

/// A row as the memory last knew it, for `WeChatVoiceMatch`.
public struct WeChatObservedRow: Equatable, Sendable {
    /// Whitespace folded; empty when the row was never seen filled in.
    public let title: String
    /// Nil for a row that is not a voice message. A transcript only ever
    /// grows within a stretch: looks that read another one are not joined.
    public let voice: WeChatVoiceMessage?
    /// Whether it was ticked, where that is still known: nil outside
    /// multi-select, and for a row a later click may have changed off screen.
    public let ticked: Bool?

    public init(title: String, voice: WeChatVoiceMessage? = nil, ticked: Bool? = nil) {
        self.title = title
        self.voice = voice
        self.ticked = ticked
    }
}

/// Rows seen one after another with nothing missing between them, oldest
/// first: a contiguous stretch of the conversation.
public struct WeChatObservedStretch: Equatable, Sendable {
    public let multiSelect: Bool
    public let rows: [WeChatObservedRow]

    public init(multiSelect: Bool, rows: [WeChatObservedRow]) {
        self.multiSelect = multiSelect
        self.rows = rows
    }
}

/// What was seen of one conversation.
public struct WeChatListEvidence: Equatable, Sendable {
    public let stretches: [WeChatObservedStretch]

    public init(stretches: [WeChatObservedStretch]) { self.stretches = stretches }

    public var rowCount: Int { stretches.reduce(0) { $0 + $1.rows.count } }
}

/// What WeChat's message list has said, kept while the user works in it so a
/// forward made by hand can be given the transcripts its TXT leaves out.
///
/// In memory only, bounded by age and by size, and never written anywhere.
///
/// The list only ever shows a few rows, so every look is a window onto the
/// conversation. A look that overlaps the last one — the same rows, nothing
/// contradicting, and either two rows that moved together or one long row
/// that cannot have repeated by chance — is joined to it into a stretch.
/// Anything else starts a stretch of its own: a fast scroll or a jump leaves
/// a gap no row can vouch for, and two stretches are never assumed to meet.
/// Neither are the two modes: a row's title changes on entering multi-select.
///
/// Ticks change without the row being on screen: Shift-click and
/// 选择到这里 tick everything between two rows. So every click observed
/// costs what it may have changed off screen — the rows between it and the
/// last click seen in this stretch, or all of them when it may have been a
/// range or there is no such click — and a tick found changed on a row that
/// scrolls back into view costs all of them too. Only the latest
/// multi-select stretch keeps any ticks at all. See `join`.
public struct WeChatListMemory: Sendable {
    public static let defaultMaximumAge: TimeInterval = 600
    public static let defaultMaximumRows = 1500

    public let maximumAge: TimeInterval
    public let maximumRows: Int

    struct Slot: Sendable {
        var title: String
        var voice: WeChatVoiceMessage?
        /// What the row's checkbox last showed, and whether that still holds.
        var seenTicked: Bool?
        var ticked: Bool?
        var height: Double

        init(_ row: WeChatListRow) {
            title = row.folded
            voice = row.voice
            seenTicked = row.ticked
            ticked = row.ticked
            height = row.height
        }

        /// `agree` has already held between the two looks. A transcript
        /// hidden again (WeChat can fold it away) is still the one it showed.
        mutating func update(with row: WeChatListRow) {
            let incoming = row.folded
            if !incoming.isEmpty, (voice?.transcript.count ?? -1) <= (row.voice?.transcript.count ?? 0) {
                title = incoming
                voice = row.voice
            }
            seenTicked = row.ticked
            ticked = row.ticked
            height = row.height
        }
    }

    struct Stretch: Sendable {
        let chat: String
        let multiSelect: Bool
        let started: Date
        var updated: Date
        var slots: [Slot]
        /// The last look, and the slot its first row is.
        var window: [WeChatListRow]
        var windowStart: Int
        var lastTickChange: Date?
        /// The slot of the last single click, as far as one can tell.
        var lastClicked: Int?
    }

    private(set) var stretches: [Stretch] = []
    /// The stretch the last look joined; nil once observation has stopped,
    /// so whatever is seen next cannot be taken to follow it.
    private var current: Int?

    public init(maximumAge: TimeInterval = defaultMaximumAge, maximumRows: Int = defaultMaximumRows) {
        self.maximumAge = maximumAge
        self.maximumRows = maximumRows
    }

    public var rowCount: Int { stretches.reduce(0) { $0 + $1.slots.count } }
    public var stretchCount: Int { stretches.count }

    /// Whatever is seen next does not follow what was seen last.
    public mutating func interrupt() { current = nil }

    public mutating func forget() {
        stretches = []
        current = nil
    }

    public mutating func prune(now: Date) {
        let kept = stretches.indices.filter { now.timeIntervalSince(stretches[$0].updated) <= maximumAge }
        guard kept.count != stretches.count else { return }
        current = current.flatMap { kept.firstIndex(of: $0) }
        stretches = kept.map { stretches[$0] }
    }

    /// One look at the list: `rows` top to bottom, which is oldest first. A
    /// look that is not one clean window — rows out of order, or some in
    /// multi-select and some not, as while WeChat redraws — is not used, and
    /// the next one is not joined across it.
    public mutating func observe(chat: String, rows: [WeChatListRow], at date: Date) {
        let chat = WeChatForwardPreset.normalizedChat(chat)
        let rows = rows.filter { $0.height > 0 }
        guard !chat.isEmpty, let first = rows.first else { return }
        let multiSelect = first.ticked != nil
        guard zip(rows, rows.dropFirst()).allSatisfy({ $0.y < $1.y }),
              rows.allSatisfy({ ($0.ticked != nil) == multiSelect }) else { return interrupt() }
        prune(now: date)
        if let index = current, stretches[index].chat == chat, stretches[index].multiSelect == multiSelect,
           let offset = Self.offset(of: rows, after: stretches[index].window),
           Self.fits(rows, at: stretches[index].windowStart + offset, into: stretches[index].slots) {
            join(rows, at: stretches[index].windowStart + offset, into: index, at: date)
        } else {
            // No click has been seen yet: WeChat's Shift anchor may be any row.
            stretches.append(Stretch(chat: chat, multiSelect: multiSelect, started: date, updated: date,
                                     slots: rows.map(Slot.init), window: rows, windowStart: 0,
                                     lastTickChange: nil, lastClicked: nil))
            current = stretches.count - 1
        }
        trim()
    }

    /// Everything seen of `chat`. Ticks come only from the latest
    /// multi-select stretch begun before the export, and only if nothing was
    /// clicked after it: a selection WeChat moved on from is not this one.
    public func evidence(chat: String, exportedAt: Date) -> WeChatListEvidence {
        let chat = WeChatForwardPreset.normalizedChat(chat)
        let mine = stretches.indices.filter { stretches[$0].chat == chat }
        let selecting = mine.filter { stretches[$0].multiSelect && stretches[$0].started <= exportedAt }
            .max { stretches[$0].started < stretches[$1].started }
        let ticksHold = selecting.map { (stretches[$0].lastTickChange ?? stretches[$0].started) <= exportedAt } ?? false
        return WeChatListEvidence(stretches: mine.map { index in
            let stretch = stretches[index], keepsTicks = ticksHold && index == selecting
            return WeChatObservedStretch(multiSelect: stretch.multiSelect, rows: stretch.slots.map {
                WeChatObservedRow(title: $0.title, voice: $0.voice, ticked: keepsTicks ? $0.ticked : nil)
            })
        })
    }

    // MARK: - Joining looks

    private mutating func join(_ rows: [WeChatListRow], at position: Int, into index: Int, at date: Date) {
        var stretch = stretches[index]
        let above = max(0, -position)
        if above > 0 {
            stretch.slots.insert(contentsOf: rows.prefix(above).map(Slot.init), at: 0)
            stretch.lastClicked = stretch.lastClicked.map { $0 + above }
        }
        // Where the look's first row is now that any rows above have been
        // added, and where the last look was.
        let base = position + above
        let before = (stretch.windowStart + above)..<(stretch.windowStart + above + stretch.window.count)
        var clicked: [Int] = [], revealed = false
        for (offset, row) in rows.enumerated() where offset >= above {
            let slot = base + offset
            if slot < stretch.slots.count {
                if let seen = stretch.slots[slot].seenTicked, seen != row.ticked {
                    // On screen both times, it was clicked; scrolled back
                    // into view changed, something off screen changed it.
                    if before.contains(slot) { clicked.append(slot) } else { revealed = true }
                }
                stretch.slots[slot].update(with: row)
            } else {
                stretch.slots.append(Slot(row))
            }
        }
        let visible = base..<(base + rows.count)
        if !clicked.isEmpty || revealed {
            stretch.lastTickChange = date
            // One click on a row away from the top: as a Shift-click it may
            // have changed the rows between it and the last click. Anything
            // else — two rows at once, the first rows (where 选择到这里
            // starts), no click seen before it, or a change found off
            // screen — may have changed any row off screen.
            var unknown: Range<Int> = 0..<stretch.slots.count
            if !revealed, clicked.count == 1, let click = clicked.first, click - visible.lowerBound >= 2,
               let last = stretch.lastClicked {
                unknown = (min(last, click) + 1)..<max(min(last, click) + 1, max(last, click))
            }
            for slot in unknown where !visible.contains(slot) { stretch.slots[slot].ticked = nil }
            stretch.lastClicked = !revealed && clicked.count == 1 ? clicked.first : nil
        }
        stretch.window = rows
        stretch.windowStart = visible.lowerBound
        stretch.updated = date
        stretches[index] = stretch
    }

    /// Where `rows` sit against the last look: `rows[k]` is `previous[k + d]`.
    /// The same geometry means the list did not move. Otherwise exactly one
    /// overlap must agree row for row and place the look: two rows or more
    /// that read the same, are as tall as before and moved by the same
    /// distance, one of them distinctive; or a single such row long enough
    /// that it cannot be another message saying the same — a stock reply
    /// such as 收到，谢谢老师 can be, after a jump. Several, or none, and the
    /// look starts afresh.
    static func offset(of rows: [WeChatListRow], after previous: [WeChatListRow]) -> Int? {
        if rows.count == previous.count, zip(rows, previous).allSatisfy({
            abs($0.y - $1.y) <= 1 && abs($0.height - $1.height) <= 1 && agree($1, $0)
        }) { return 0 }
        var found: [Int] = []
        for shift in (1 - rows.count)..<previous.count {
            var consistent = true, moved: Double?, same = 0, distinctive = false, long = false
            for index in max(0, -shift)..<min(rows.count, previous.count - shift) {
                let old = previous[index + shift], new = rows[index]
                guard agree(old, new) else { consistent = false; break }
                guard !new.folded.isEmpty, old.folded == new.folded, abs(old.height - new.height) <= 2 else { continue }
                let distance = new.y - old.y
                if let moved, abs(moved - distance) > 2 { consistent = false; break }
                moved = moved ?? distance
                same += 1
                distinctive = distinctive || places(new)
                long = long || places(new, minimumLength: 20)
            }
            if consistent, (same >= 2 && distinctive) || long { found.append(shift) }
        }
        return found.count == 1 ? found[0] : nil
    }

    /// Two looks at one row. A row not yet filled in agrees with anything; a
    /// voice message may have gained its transcript since, or folded it away.
    static func agree(_ old: WeChatListRow, _ new: WeChatListRow) -> Bool {
        agree(old.folded, old.voice, new.folded, new.voice)
    }

    /// Titles already folded.
    static func agree(_ oldTitle: String, _ oldVoice: WeChatVoiceMessage?, _ newTitle: String, _ newVoice: WeChatVoiceMessage?) -> Bool {
        if oldTitle.isEmpty || newTitle.isEmpty { return true }
        switch (oldVoice, newVoice) {
        case let (old?, new?):
            return old.seconds == new.seconds && (old.transcript.isEmpty || new.transcript.isEmpty
                || old.transcript.hasPrefix(new.transcript) || new.transcript.hasPrefix(old.transcript))
        case (nil, nil):
            return oldTitle == newTitle
        default:
            return false
        }
    }

    /// The look also agrees with everything the stretch knows of its rows,
    /// not just with the last look: a transcript folded away and shown again
    /// must be the same one.
    static func fits(_ rows: [WeChatListRow], at position: Int, into slots: [Slot]) -> Bool {
        rows.indices.allSatisfy { offset in
            let slot = position + offset
            guard slots.indices.contains(slot) else { return true }
            return agree(slots[slot].title, slots[slot].voice, rows[offset].folded, rows[offset].voice)
        }
    }

    /// A row unlikely to appear twice: a varied text, or a transcript that
    /// is, of at least `minimumLength` characters. In multi-select only what
    /// follows the last space counts, because the sender's name in front
    /// would make "小林 好的" look rare.
    static func places(_ row: WeChatListRow, minimumLength: Int = 6) -> Bool {
        func rare(_ text: String) -> Bool { text.count >= minimumLength && WeChatVoiceMatch.isDistinctive(text) }
        if let voice = row.voice { return rare(voice.transcript) }
        let text = row.folded
        if row.ticked != nil, let space = text.lastIndex(of: " ") { return rare(String(text[text.index(after: space)...])) }
        return rare(text)
    }

    // MARK: - Size

    /// Oldest stretches go first; the one being watched is cut back from the
    /// end farther from where the list is now.
    private mutating func trim() {
        while rowCount > maximumRows {
            if stretches.count > 1 {
                let candidates = stretches.indices.filter { $0 != current }
                guard let oldest = candidates.min(by: { stretches[$0].updated < stretches[$1].updated }) else { break }
                stretches.remove(at: oldest)
                if let index = current, index > oldest { current = index - 1 }
                continue
            }
            var stretch = stretches[0]
            let excess = stretch.slots.count - maximumRows
            let window = stretch.windowStart..<(stretch.windowStart + stretch.window.count)
            if window.lowerBound >= stretch.slots.count - window.upperBound {
                let cut = min(excess, window.lowerBound)
                stretch.slots.removeFirst(cut)
                stretch.windowStart -= cut
                stretch.lastClicked = stretch.lastClicked.flatMap { $0 >= cut ? $0 - cut : nil }
                // Rows dropped from the top: what is left keeps its ticks.
            } else {
                let cut = min(excess, stretch.slots.count - window.upperBound)
                stretch.slots.removeLast(cut)
                if let clicked = stretch.lastClicked, clicked >= stretch.slots.count { stretch.lastClicked = nil }
            }
            stretches[0] = stretch
            if stretch.slots.count > maximumRows { break }
        }
    }
}
