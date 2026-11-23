import Foundation
import XCTest
import zlib
@testable import DukouCore

final class WeChatVoiceMatchTests: XCTestCase {
    private var temporary: TemporaryInbox!
    override func setUp() { temporary = TemporaryInbox() }
    override func tearDown() { temporary.tearDown() }

    // Synthetic group chat, oldest first, as its rows read outside
    // multi-select. Two voice messages of 18", a short reply that recurs,
    // one voice message nobody converted, and three long texts to anchor on.
    private let chat = "项目群"
    private let conversation = [
        "大家早，今天下午三点开会",          // 0 anchor
        "语音18\"秒明天上午十点开会",         // 1
        "好的",                              // 2
        "语音18\"秒我晚点到，先开始吧",       // 3
        "图片",                              // 4
        "会议室改到三楼东侧",                // 5 anchor
        "语音7\"秒收到",                      // 6
        "好的",                              // 7
        "语音20\"秒",                         // 8 never converted
        "记得带上周的报表过来",              // 9 anchor
        "语音9\"秒报表我已经发群里了",        // 10
    ]
    /// Multi-select puts these in front, a space and 语音 in them included.
    private let senders = ["小林 Lin", "阿 语音"]
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private var later: Date { start.addingTimeInterval(60) }

    // MARK: - Fixtures

    /// The export WeChat writes for these rows, without senders and times.
    private func export(_ picks: [Int]) -> Data {
        Data(picks.map { "·\(line(conversation[$0]))\n\n" }.joined().utf8)
    }

    /// The same with senders and times.
    private func exportWithSenders(_ picks: [Int]) -> Data {
        Data(picks.map { "·\(senders[$0 % 2])\n2026年11月20日 09:\(10 + $0)\n\(line(conversation[$0]))\n\n" }.joined().utf8)
    }

    private func line(_ row: String) -> String {
        if let voice = WeChatVoiceMessage.parse(row: row) { return "[语音] \(voice.seconds)\"" }
        return row == "图片" ? "[图片]" : row
    }

    /// Rows `range` as the list lays them out from `top`, in multi-select
    /// when `ticked` is given.
    private func look(_ range: ClosedRange<Int>, top: Double = 100, ticked: Set<Int>? = nil) -> [WeChatListRow] {
        range.map { index in
            WeChatListRow(title: ticked == nil ? conversation[index] : "\(senders[index % 2]) \(conversation[index])",
                          ticked: ticked.map { $0.contains(index) }, y: top + Double(index - range.lowerBound) * 60, height: 60)
        }
    }

    private func remember(_ looks: [[WeChatListRow]], chat: String? = nil) -> WeChatListMemory {
        var memory = WeChatListMemory()
        for (index, rows) in looks.enumerated() {
            memory.observe(chat: chat ?? self.chat, rows: rows, at: start.addingTimeInterval(Double(index) * 0.2))
        }
        return memory
    }

    private func match(_ text: Data, _ looks: [[WeChatListRow]]) -> (text: String, outcome: WeChatVoiceMatch.Outcome) {
        let (merged, outcome) = WeChatVoiceMatch.merge(remember(looks).evidence(chat: chat, exportedAt: later), into: text)
        return (String(decoding: merged, as: UTF8.self), outcome)
    }

    private func summary(_ outcome: WeChatVoiceMatch.Outcome) -> WeChatVoiceMatch.Summary? {
        if case .matched(let summary) = outcome { return summary }
        XCTFail("\(outcome)")
        return nil
    }

    /// A multi-select stretch of rows `range` as the matcher is handed it:
    /// ticks as given, and `unknown` rows' ticks no longer known.
    private func selection(_ range: ClosedRange<Int>, ticked: Set<Int>, unknown: Set<Int> = [],
                           rows: [String]? = nil) -> WeChatObservedStretch {
        let titles = rows ?? conversation
        return WeChatObservedStretch(multiSelect: true, rows: range.map { index in
            let title = "\(senders[index % 2]) \(titles[index])"
            return WeChatObservedRow(title: title, voice: WeChatVoiceMessage.parse(row: title),
                                     ticked: unknown.contains(index) ? nil : ticked.contains(index))
        })
    }

    /// Rows seen outside multi-select.
    private func browsed(_ titles: [String]) -> WeChatObservedStretch {
        WeChatObservedStretch(multiSelect: false, rows: titles.map { WeChatObservedRow(title: $0, voice: WeChatVoiceMessage.parse(row: $0)) })
    }

    private func merge(_ text: Data, _ stretches: [WeChatObservedStretch]) -> (text: String, outcome: WeChatVoiceMatch.Outcome) {
        let (merged, outcome) = WeChatVoiceMatch.merge(WeChatListEvidence(stretches: stretches), into: text)
        return (String(decoding: merged, as: UTF8.self), outcome)
    }

    // MARK: - Outside multi-select

    func testRowsSeenOutsideMultiSelectPinNothing() {
        // Even between two long texts: either could be said again where the
        // user ticked, unseen. 收到，谢谢老师 is said again and again in a
        // parents' group, and so is an 18" voice message between replies.
        let stock = ["收到，谢谢老师", "语音18\"秒明天上午十点开会", "好的，辛苦了"]
        let text = Data("·收到，谢谢老师\n\n·[语音] 18\"\n\n·好的，辛苦了\n\n".utf8)
        let (merged, outcome) = merge(text, [browsed(stock)])
        XCTAssertEqual(summary(outcome), .init(voiceLines: 1, ambiguous: 1))
        XCTAssertEqual(merged, String(decoding: text, as: UTF8.self))
        for picks in [[5, 6, 7, 8, 9], [6, 7, 8, 9], [9, 10], [3, 4, 5]] {
            XCTAssertEqual(summary(match(export(picks), [look(0...10)]).outcome)?.attached, 0, "\(picks)")
        }
        // Nor do they get in the way of a selection.
        let both = merge(text, [browsed(stock), WeChatObservedStretch(multiSelect: true, rows: [
            "王妈妈 收到，谢谢老师", "李爸爸 语音18\"秒我不去了", "张妈妈 好的，辛苦了",
        ].map { WeChatObservedRow(title: $0, voice: WeChatVoiceMessage.parse(row: $0), ticked: true) })])
        XCTAssertEqual(summary(both.outcome)?.attached, 1)
        XCTAssertTrue(both.text.contains("[语音] 18\" 转文字：我不去了\n"), both.text)
    }

    // MARK: - Multi-select

    func testTickedRowsPinVoiceMessagesAtEitherEnd() {
        for picks in [[6, 7, 8, 9], [9, 10], [3, 4, 5], [5, 6, 7, 8, 9]] {
            let text = export(picks)
            let (merged, outcome) = match(text, [look(0...10, ticked: Set(picks))])
            let voices = picks.filter { conversation[$0].hasPrefix("语音") }
            let converted = voices.filter { WeChatVoiceMessage.parse(row: conversation[$0])?.transcript.isEmpty == false }
            XCTAssertEqual(summary(outcome), .init(voiceLines: voices.count, attached: converted.count,
                                                   notConverted: voices.count - converted.count), "\(picks)")
            for index in converted {
                let voice = WeChatVoiceMessage.parse(row: conversation[index])!
                XCTAssertTrue(merged.contains("[语音] \(voice.seconds)\" 转文字：\(voice.transcript)\n"), "\(picks)")
            }
            // Only voice lines change.
            XCTAssertEqual(merged.replacingOccurrences(of: #" 转文字：[^\n]*"#, with: "", options: .regularExpression),
                           String(decoding: text, as: UTF8.self))
        }
    }

    func testSendersAndTimesMatchTheSameWay() {
        let text = exportWithSenders([5, 6, 9])
        let (merged, outcome) = match(text, [look(3...10, ticked: [5, 6, 9])])
        XCTAssertEqual(summary(outcome)?.attached, 1)
        XCTAssertTrue(merged.contains("\n[语音] 7\" 转文字：收到\n"), merged)
        XCTAssertEqual(try WeChatTranscriptRecord.parse(merged).count, 3)
    }

    func testTicksSayWhichOfTwoEqualDurationsWasPicked() {
        // Ticked far apart: the first 18" message is skipped, the second taken.
        let text = export([0, 3, 5])
        let (merged, outcome) = match(text, [look(0...6, ticked: [0, 3, 5])])
        XCTAssertEqual(summary(outcome)?.attached, 1)
        XCTAssertTrue(merged.contains("[语音] 18\" 转文字：我晚点到，先开始吧\n"), merged)
        XCTAssertFalse(merged.contains("明天上午十点开会"))
    }

    func testBetweenTwoTickedRowsAMessageIsReadOffTheRowsBetween() {
        // Rows 1 to 4 were clicked over and their ticks are no longer known,
        // but whatever was exported between rows 0 and 5 lies on them.
        let text = export([0, 3, 5])
        let one = merge(text, [selection(0...6, ticked: [0, 5], unknown: [1, 2, 3, 4])])
        XCTAssertEqual(summary(one.outcome), .init(voiceLines: 1, ambiguous: 1), "Either 18\" message may be it")
        var same = conversation
        same[3] = same[1]
        let two = merge(text, [selection(0...6, ticked: [0, 5], unknown: [1, 2, 3, 4], rows: same)])
        XCTAssertEqual(summary(two.outcome)?.attached, 1, "Unless they say the same")
        // Between rows 5 and 9 only one row is a 7" message, so it is that one.
        let three = merge(export([5, 6, 9]), [selection(4...10, ticked: [5, 9], unknown: [6, 7, 8])])
        XCTAssertEqual(summary(three.outcome)?.attached, 1)
    }

    func testRepeatedShortTextsLineUpOnlyWhereTicked() {
        // 好的 is on rows 2 and 7: ticks say which one was taken.
        let text = export([2, 3, 4])
        let (merged, outcome) = match(text, [look(0...10, ticked: [2, 3, 4])])
        XCTAssertEqual(summary(outcome)?.attached, 1)
        XCTAssertTrue(merged.contains("[语音] 18\" 转文字：我晚点到，先开始吧\n"))
        // Without them, either 好的 could open the selection.
        XCTAssertEqual(summary(merge(text, [selection(0...10, ticked: [], unknown: Set(0...10))]).outcome)?.attached, 0)
        // A text the export has once anchors only on a row ticked.
        XCTAssertEqual(WeChatVoiceMatch.anchors(WeChatVoiceMatch.messages(in: "·好的\n\n·[语音] 18\"\n\n")!,
                                                in: selection(0...10, ticked: [7], unknown: [2])), [0: 7])
        XCTAssertEqual(WeChatVoiceMatch.anchors(WeChatVoiceMatch.messages(in: "·好的\n\n·[语音] 18\"\n\n")!,
                                                in: selection(0...10, ticked: [2, 7])), [:])
    }

    func testAStretchNoReadingFitsAttachesNothingAnywhere() {
        // A 9" message between two ticked rows whose rows have none: the ticks
        // or the export are not what they seem.
        let text = export([5, 6, 9]).replacingVoice(7, with: 9)
        let (merged, outcome) = match(text, [look(0...10, ticked: [5, 6, 9])])
        XCTAssertEqual(outcome, .inconsistent(voiceLines: 1))
        XCTAssertEqual(merged, String(decoding: text, as: UTF8.self))
    }

    func testRowsOutsideAndInsideMultiSelectAreNotMixed() {
        // The same rows in both modes make two stretches, and the
        // multi-select one still lines up under the senders' names.
        let text = export([5, 6, 7, 8, 9])
        let memory = remember([look(4...10), look(4...10, ticked: [5, 6, 7, 8, 9])])
        let evidence = memory.evidence(chat: chat, exportedAt: later)
        XCTAssertEqual(evidence.stretches.map(\.multiSelect), [false, true])
        XCTAssertEqual(evidence.stretches[1].rows[2].ticked, true)
        XCTAssertEqual(summary(WeChatVoiceMatch.merge(evidence, into: text).outcome), .init(voiceLines: 2, attached: 1, notConverted: 1))
    }

    // MARK: - Gaps

    func testOverlappingLooksJoinAndAGapDoesNot() {
        let text = export([5, 6, 9])
        // Scrolled: the second look shares rows 5 to 7 with the first.
        let scrolled = [look(3...7, top: 0, ticked: [5, 6]), look(5...10, top: 300, ticked: [5, 6, 9])]
        XCTAssertEqual(remember(scrolled).stretchCount, 1)
        XCTAssertEqual(summary(match(text, scrolled).outcome)?.attached, 1)
        // Jumped: row 7 was never seen and nothing ties the looks together,
        // so the 7" message might lie in what was missed.
        let jumped = match(text, [look(4...6, ticked: [5, 6]), look(8...10, top: 20, ticked: [9])])
        XCTAssertEqual(summary(jumped.outcome), .init(voiceLines: 1, ambiguous: 1))
        XCTAssertEqual(jumped.text, String(decoding: text, as: UTF8.self))
    }

    func testOnlyRowsThatMovedTogetherOrOneLongRowJoinTwoLooks() {
        // Rows 7 and 8 alone (好的, an unconverted voice) could be any 好的.
        XCTAssertEqual(remember([look(5...8), look(7...10, top: 20)]).stretchCount, 2)
        // One distinctive but short row could be a stock reply said again.
        let reply = WeChatListRow(title: "收到，谢谢老师", y: 400, height: 60)
        XCTAssertNil(WeChatListMemory.offset(of: [WeChatListRow(title: reply.title, y: 0, height: 60),
                                                  WeChatListRow(title: "好的", y: 60, height: 60)],
                                             after: [WeChatListRow(title: "图片", y: 340, height: 60), reply]))
        // A long one is placed on its own.
        let long = "语音36\"秒" + String(repeating: "周五下午的家长会改到礼堂", count: 2)
        XCTAssertEqual(WeChatListMemory.offset(of: [WeChatListRow(title: long, y: 0, height: 200), WeChatListRow(title: "好的", y: 200, height: 60)],
                                               after: [WeChatListRow(title: "图片", y: 300, height: 200), WeChatListRow(title: long, y: 500, height: 200)]), 1)
        // Rows that agree but moved by different distances are not one scroll.
        var moved = look(5...8, top: 0)
        moved[2] = WeChatListRow(title: moved[2].title, y: moved[2].y + 30, height: 60)
        moved[3] = WeChatListRow(title: moved[3].title, y: moved[3].y + 30, height: 60)
        XCTAssertNil(WeChatListMemory.offset(of: moved, after: look(3...7, top: 300)))
        XCTAssertEqual(WeChatListMemory.offset(of: look(5...8, top: 0), after: look(3...7, top: 300)), 2)
        // Several overlaps that agree are no better than none.
        let repeated = (0..<4).map { WeChatListRow(title: conversation[5], y: Double($0) * 60, height: 60) }
        XCTAssertNil(WeChatListMemory.offset(of: Array(repeated.dropFirst()), after: repeated.map {
            WeChatListRow(title: $0.title, y: $0.y + 50, height: $0.height)
        }))
        // A look that has not moved joins whatever it shows.
        XCTAssertEqual(remember([look(7...8), look(7...8)]).stretchCount, 1)
    }

    // MARK: - Ticks that may have changed off screen

    /// Rows 0 to 5, a click on row 0, then scrolled to rows 3 to 9.
    private func clickedThenScrolled() -> WeChatListMemory {
        var memory = WeChatListMemory()
        memory.observe(chat: chat, rows: look(0...5, ticked: []), at: start)
        memory.observe(chat: chat, rows: look(0...5, ticked: [0]), at: start.addingTimeInterval(0.2))
        memory.observe(chat: chat, rows: look(3...9, top: 0, ticked: [0]), at: start.addingTimeInterval(0.4))
        return memory
    }

    func testAClickForgetsTicksBetweenItAndTheLastClick() throws {
        var memory = clickedThenScrolled()
        // A click on row 6: as a Shift-click it would have ticked 1 to 5.
        memory.observe(chat: chat, rows: look(3...9, top: 0, ticked: [0, 6]), at: start.addingTimeInterval(0.6))
        let rows = try XCTUnwrap(memory.evidence(chat: chat, exportedAt: later).stretches.first?.rows)
        XCTAssertEqual(rows.map(\.ticked), [true, nil, nil, false, false, false, true, false, false, false])
    }

    func testAClickAtTheTopOrOnTwoRowsForgetsEveryTickOffScreen() throws {
        for (clicked, at) in [([0, 3], "top"), ([0, 6, 7], "two rows")] {
            var memory = clickedThenScrolled()
            memory.observe(chat: chat, rows: look(3...9, top: 0, ticked: Set(clicked)), at: start.addingTimeInterval(0.6))
            let rows = try XCTUnwrap(memory.evidence(chat: chat, exportedAt: later).stretches.first?.rows)
            XCTAssertEqual(Array(rows.prefix(3).map(\.ticked)), [nil, nil, nil], at)
            XCTAssertEqual(rows[3].ticked, clicked.contains(3), at)
        }
    }

    func testWithNoClickSeenYetAnyRowMayBeWhereAShiftClickStarted() throws {
        // Row 0 was ticked before the stretch began, by a click Dukou never
        // saw; WeChat's Shift anchor could be anywhere.
        var memory = WeChatListMemory()
        memory.observe(chat: chat, rows: look(0...3, ticked: [0]), at: start)
        memory.observe(chat: chat, rows: look(2...7, top: 0, ticked: [5]), at: start.addingTimeInterval(0.2))
        memory.observe(chat: chat, rows: look(0...3, ticked: [0]), at: start.addingTimeInterval(0.4))
        memory.observe(chat: chat, rows: look(0...3, ticked: [0, 3]), at: start.addingTimeInterval(0.6))
        var rows = try XCTUnwrap(memory.evidence(chat: chat, exportedAt: later).stretches.first?.rows)
        XCTAssertEqual(rows.map(\.ticked), [true, false, false, true, nil, nil, nil, nil])
        // Back down: rows 4 and 6 turn out ticked. That was no click on
        // screen, so it says nothing about where one started.
        memory.observe(chat: chat, rows: look(2...7, top: 0, ticked: [3, 4, 5, 6]), at: start.addingTimeInterval(0.8))
        rows = try XCTUnwrap(memory.evidence(chat: chat, exportedAt: later).stretches.first?.rows)
        XCTAssertEqual(rows.map(\.ticked), [nil, nil, false, true, true, true, true, false])
    }

    func testRowsTickedOffScreenByARangeAreNotTakenAsUnticked() {
        // Clicked row 0, scrolled, Shift-clicked row 6: WeChat ticked 0 to 6,
        // and rows 1 and 2 were last seen unticked. Believed, that would
        // leave no reading; forgotten, the lines it no longer knows about
        // stay alone and the ones it does are pinned.
        let text = export(Array(0...6))
        var memory = clickedThenScrolled()
        memory.observe(chat: chat, rows: look(3...9, top: 0, ticked: Set(0...6)), at: start.addingTimeInterval(0.6))
        let (merged, outcome) = WeChatVoiceMatch.merge(memory.evidence(chat: chat, exportedAt: later), into: text)
        XCTAssertEqual(summary(outcome), .init(voiceLines: 3, attached: 2, ambiguous: 1))
        let body = String(decoding: merged, as: UTF8.self)
        XCTAssertTrue(body.hasPrefix("·大家早，今天下午三点开会\n\n·[语音] 18\"\n\n·好的\n\n·[语音] 18\" 转文字：我晚点到，先开始吧\n"), body)
        XCTAssertTrue(body.contains("[语音] 7\" 转文字：收到\n"))
    }

    func testTicksComeOnlyFromTheSelectionTheExportCameFrom() {
        let text = export([9, 10])
        var memory = WeChatListMemory()
        memory.observe(chat: chat, rows: look(5...10, ticked: [9, 10]), at: start)
        // A selection begun after the export says nothing about it.
        let before = start.addingTimeInterval(-1)
        XCTAssertEqual(summary(WeChatVoiceMatch.merge(memory.evidence(chat: chat, exportedAt: before), into: text).outcome)?.attached, 0)
        XCTAssertEqual(summary(WeChatVoiceMatch.merge(memory.evidence(chat: chat, exportedAt: later), into: text).outcome)?.attached, 1)
        // Nor does one clicked again after it.
        memory.observe(chat: chat, rows: look(5...10, ticked: [10]), at: start.addingTimeInterval(5))
        let clickedAfter = memory.evidence(chat: chat, exportedAt: start.addingTimeInterval(2))
        XCTAssertTrue(clickedAfter.stretches.allSatisfy { $0.rows.allSatisfy { $0.ticked == nil } })
        // And an older selection gives way to a newer one.
        memory.interrupt()
        memory.observe(chat: chat, rows: look(0...4, ticked: [1]), at: start.addingTimeInterval(6))
        let evidence = memory.evidence(chat: chat, exportedAt: later)
        XCTAssertEqual(evidence.stretches.count, 2)
        XCTAssertTrue(evidence.stretches[0].rows.allSatisfy { $0.ticked == nil })
        XCTAssertEqual(evidence.stretches[1].rows.map(\.ticked), [false, true, false, false, false])
    }

    // MARK: - Nothing to go on

    func testAnotherChatOrNothingSeenLeavesTheExportAlone() {
        let text = export([5, 6, 9])
        let elsewhere = remember([look(0...10, ticked: [5, 6, 9])], chat: "另一个群")
        for evidence in [elsewhere.evidence(chat: chat, exportedAt: later), WeChatListMemory().evidence(chat: chat, exportedAt: later)] {
            let (merged, outcome) = WeChatVoiceMatch.merge(evidence, into: text)
            XCTAssertEqual(outcome, .notObserved(voiceLines: 1))
            XCTAssertEqual(merged, text)
        }
        // A chat's name with its member count is still that chat.
        XCTAssertEqual(remember([look(4...10)], chat: "项目群(12)").evidence(chat: chat, exportedAt: later).rowCount, 7)
    }

    func testAnExportAlreadyMergedIsLeftAlone() {
        let source = export([5, 6, 7, 8, 9])
        let ticked = remember([look(4...10, ticked: [5, 6, 7, 8, 9])]).evidence(chat: chat, exportedAt: later)
        let once = WeChatVoiceMatch.merge(ticked, into: source).text
        XCTAssertNotEqual(once, source)
        let again = WeChatVoiceMatch.merge(ticked, into: once)
        XCTAssertEqual(again.outcome, .alreadyMerged)
        XCTAssertEqual(again.text, once)
        // So is one a quick forward already went through.
        let quick = WeChatVoiceTranscripts.merge([WeChatVoiceMessage(seconds: 7, transcript: "收到"), WeChatVoiceMessage(seconds: 20, transcript: "")],
                                                 into: source).text
        XCTAssertEqual(WeChatVoiceMatch.merge(ticked, into: quick).outcome, .alreadyMerged)
        // CRLF and a byte order mark do not hide one.
        let crlf = Data([0xEF, 0xBB, 0xBF]) + Data("·[语音] 7\" 转文字：收到\r\n\r\n".utf8)
        XCTAssertEqual(WeChatVoiceMatch.merge(WeChatListEvidence(stretches: []), into: crlf).outcome, .alreadyMerged)
    }

    func testNoVoiceLinesAndUnfamiliarLayouts() {
        XCTAssertEqual(WeChatVoiceMatch.merge(WeChatListEvidence(stretches: []), into: export([5, 9])).outcome, .noVoiceLines)
        // A voice line inside some other message's text: the TXT is not one
        // this can split into messages with confidence.
        let odd = Data("前言\n[语音] 5\"\n".utf8)
        XCTAssertEqual(WeChatVoiceMatch.merge(remember([look(0...10)]).evidence(chat: chat, exportedAt: later), into: odd).outcome, .unreadable)
    }

    func testCRLFAndAByteOrderMarkSurvive() {
        let plain = String(decoding: export([5, 6, 9]), as: UTF8.self).replacingOccurrences(of: "\n", with: "\r\n")
        let source = Data([0xEF, 0xBB, 0xBF]) + Data(plain.utf8)
        let evidence = remember([look(4...10, ticked: [5, 6, 9])]).evidence(chat: chat, exportedAt: later)
        let (merged, outcome) = WeChatVoiceMatch.merge(evidence, into: source)
        XCTAssertEqual(summary(outcome)?.attached, 1)
        XCTAssertEqual(merged, Data([0xEF, 0xBB, 0xBF]) + Data(plain.replacingOccurrences(of: "[语音] 7\"\r\n", with: "[语音] 7\" 转文字：收到\r\n").utf8))
    }

    // MARK: - Memory

    func testATranscriptThatGrowsIsKeptAndOneThatChangesIsNotJoined() throws {
        var memory = WeChatListMemory()
        func rows(_ voice: String) -> [WeChatListRow] {
            [WeChatListRow(title: conversation[5], y: 0, height: 60), WeChatListRow(title: voice, y: 60, height: 60)]
        }
        for (index, voice) in ["语音7\"秒", "语音7\"秒收", "语音7\"秒收到", "语音7\"秒"].enumerated() {
            memory.observe(chat: chat, rows: rows(voice), at: start.addingTimeInterval(Double(index) * 0.2))
        }
        let row = try XCTUnwrap(memory.evidence(chat: chat, exportedAt: later).stretches.first?.rows.last)
        XCTAssertEqual(row.voice?.transcript, "收到", "Converted, then folded away again")
        XCTAssertEqual(memory.stretchCount, 1)
        memory.observe(chat: chat, rows: rows("语音7\"秒好"), at: start.addingTimeInterval(1))
        XCTAssertEqual(memory.stretchCount, 2)
        // Two stretches that pin one line to different texts leave it alone,
        // and so do one never converted and one that was.
        let text = export([5, 6])
        for (first, second) in [("语音7\"秒收到", "语音7\"秒好"), ("语音7\"秒", "语音7\"秒收到")] {
            let evidence = WeChatListEvidence(stretches: [first, second].map { voice in
                WeChatObservedStretch(multiSelect: true, rows: [WeChatObservedRow(title: conversation[5], ticked: true),
                                                               WeChatObservedRow(title: voice, voice: WeChatVoiceMessage.parse(row: voice), ticked: true)])
            })
            XCTAssertEqual(summary(WeChatVoiceMatch.merge(evidence, into: text).outcome), .init(voiceLines: 1, ambiguous: 1))
        }
    }

    func testMemoryIsBoundedByAgeAndSize() {
        var memory = WeChatListMemory(maximumAge: 10, maximumRows: 8)
        memory.observe(chat: chat, rows: look(0...4), at: start)
        memory.interrupt()
        memory.observe(chat: "另一个群", rows: look(0...4), at: start.addingTimeInterval(1))
        XCTAssertEqual(memory.rowCount, 5, "The older stretch goes to make room")
        XCTAssertEqual(memory.evidence(chat: chat, exportedAt: later).rowCount, 0)
        // One stretch longer than the limit is cut from the end the list has left.
        memory.observe(chat: "另一个群", rows: look(3...7, top: 340), at: start.addingTimeInterval(2))
        memory.observe(chat: "另一个群", rows: look(5...10, top: 460), at: start.addingTimeInterval(3))
        XCTAssertEqual(memory.rowCount, 8)
        let kept = memory.evidence(chat: "另一个群", exportedAt: later).stretches.first?.rows.map(\.title)
        XCTAssertEqual(kept, Array(conversation[3...10]))
        memory.prune(now: start.addingTimeInterval(14))
        XCTAssertEqual(memory.rowCount, 0)
        memory.observe(chat: chat, rows: look(0...4), at: start)
        memory.forget()
        XCTAssertEqual(memory.stretchCount, 0)
    }

    func testLooksThatAreNotOneCleanWindowAreNotUsed() {
        var memory = WeChatListMemory()
        // Rows in both modes at once, while WeChat redraws.
        var mixed = look(0...3)
        mixed[2] = WeChatListRow(title: conversation[2], ticked: false, y: mixed[2].y, height: 60)
        memory.observe(chat: chat, rows: mixed, at: start)
        // Out of order.
        memory.observe(chat: chat, rows: look(0...3).reversed(), at: start)
        // Not laid out.
        memory.observe(chat: chat, rows: [WeChatListRow(title: conversation[0], y: 0, height: 0)], at: start)
        XCTAssertEqual(memory.stretchCount, 0)
    }

    // MARK: - The receipt

    func testAHandForwardedReceiptIsRewrittenInPlaceAndReadsStrictly() throws {
        let text = export([5, 6, 7, 8, 9])
        let photo = Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let source = nativeZIP([("聊天记录.txt", text, true), ("聊天记录内的图片、视频和文件/图片_1.jpg", photo, true)])
        let evidence = remember([look(4...10, ticked: [5, 6, 7, 8, 9])]).evidence(chat: chat, exportedAt: later)
        for action in [ShareAction.clipboard, .custom, .shelf] {
            let receipt = try batch(source, action: action)
            XCTAssertEqual(try WeChatVoiceMatch.merge(evidence, intoReceiptAt: receipt.directory),
                           .matched(.init(voiceLines: 2, attached: 1, notConverted: 1)))
            let reread = try XCTUnwrap(temporary.reader.batch(at: receipt.directory))
            let item = try XCTUnwrap(reread.items.first)
            XCTAssertEqual(reread.action, action)
            let data = try WeChatNativeArchive.receipt(at: receipt.directory, accepting: [action]).data
            XCTAssertEqual(Int64(data.count), item.byteCount)
            let merged = String(decoding: text, as: UTF8.self).replacingOccurrences(of: "[语音] 7\"\n", with: "[语音] 7\" 转文字：收到\n")
            XCTAssertEqual(try WeChatNativeArchive.transcript(data)?.body, merged)
            XCTAssertEqual(try WeChatNativeArchive.messageCount(data), nil, "No senders and times: no estimate, and no failure")
            XCTAssertTrue(WeChatNativeArchive.isReplacement(data, of: source, at: "聊天记录.txt", holding: Data(merged.utf8)))
            let folder = temporary.root.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            XCTAssertEqual(try WeChatNativeArchive.extract(data, to: folder).count, 2)
            XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("聊天记录内的图片、视频和文件/图片_1.jpg")), photo)
            // A second pass finds it done and changes nothing.
            XCTAssertEqual(try WeChatVoiceMatch.merge(evidence, intoReceiptAt: receipt.directory), .alreadyMerged)
            XCTAssertEqual(try Data(contentsOf: item.url), data)
        }
    }

    func testAReceiptWithNothingToAttachIsLeftByteForByte() throws {
        let text = exportWithSenders([0, 3, 5])
        let receipt = try batch(nativeZIP([("聊天记录.txt", text, true)]), action: .clipboard)
        let zip = try Data(contentsOf: receipt.items[0].url)
        let manifest = try Data(contentsOf: receipt.directory.appendingPathComponent(BatchStaging.manifestFileName))
        for evidence in [remember([look(0...6)]).evidence(chat: chat, exportedAt: later), WeChatListEvidence(stretches: [])] {
            let outcome = try WeChatVoiceMatch.merge(evidence, intoReceiptAt: receipt.directory)
            XCTAssertNotEqual(outcome, .matched(.init(voiceLines: 1, attached: 1)))
        }
        XCTAssertEqual(try Data(contentsOf: receipt.items[0].url), zip)
        XCTAssertEqual(try Data(contentsOf: receipt.directory.appendingPathComponent(BatchStaging.manifestFileName)), manifest)
        // A quick forward's merge still takes only its own entry's receipts.
        XCTAssertThrowsError(try WeChatVoiceTranscripts.merge([WeChatVoiceMessage(seconds: 18, transcript: "好")], intoReceiptAt: receipt.directory))
    }

    private func batch(_ data: Data, action: ShareAction) throws -> ReadyBatch {
        let stage = try BatchStaging.create(in: temporary.inbox)
        let id = UUID(), name = "聊天记录.zip"
        try data.write(to: stage.destination(for: id, displayName: name))
        let item = ManifestItem(id: id, displayName: name, relativePath: stage.relativePath(for: id, displayName: name),
                                contentType: "public.zip-archive", byteCount: Int64(data.count), itemIndex: 0, attachmentIndex: 0, loadStrategy: .fileRepresentation)
        let ready = try stage.commit(manifest: BatchManifest(batchID: stage.batchID, createdAt: Date(), items: [item], action: action),
                                     diagnostics: nil, intent: nil, in: temporary.inbox)
        return try XCTUnwrap(temporary.reader.batch(at: ready))
    }

    /// Shaped like WeChat 4.2.0's own ZIPs; see WeChatVoiceTranscriptsTests.
    private func nativeZIP(_ entries: [(String, Data, Bool)]) -> Data {
        var data = Data(), central = Data()
        func put(_ value: UInt32, _ bytes: Int, into output: inout Data) {
            for index in 0..<bytes { output.append(UInt8(truncatingIfNeeded: value >> (index * 8))) }
        }
        for (name, content, deflated) in entries {
            let path = Data(name.utf8), offset = data.count
            let body = deflated ? deflate(content) : content
            let crc = content.withUnsafeBytes { UInt32(crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count))) }
            put(0x04034b50, 4, into: &data)
            for value: UInt32 in [20, 0x800, deflated ? 8 : 0, 0x5A2B, 0x5B6F] { put(value, 2, into: &data) }
            for value in [crc, UInt32(body.count), UInt32(content.count)] { put(value, 4, into: &data) }
            put(UInt32(path.count), 2, into: &data); put(0, 2, into: &data)
            data.append(path); data.append(body)
            put(0x02014b50, 4, into: &central)
            for value: UInt32 in [0, 20, 0x800, deflated ? 8 : 0, 0x5A2B, 0x5B6F] { put(value, 2, into: &central) }
            for value in [crc, UInt32(body.count), UInt32(content.count)] { put(value, 4, into: &central) }
            for value: UInt32 in [UInt32(path.count), 0, 0, 0, 0] { put(value, 2, into: &central) }
            put(0, 4, into: &central); put(UInt32(offset), 4, into: &central); central.append(path)
        }
        let start = data.count
        data.append(central)
        put(0x06054b50, 4, into: &data)
        for value in [UInt32(0), 0, UInt32(entries.count), UInt32(entries.count)] { put(value, 2, into: &data) }
        put(UInt32(central.count), 4, into: &data); put(UInt32(start), 4, into: &data); put(0, 2, into: &data)
        return data
    }

    private func deflate(_ content: Data) -> Data {
        var stream = z_stream()
        XCTAssertEqual(deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, -MAX_WBITS, 8, Z_DEFAULT_STRATEGY,
                                     ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)), Z_OK)
        defer { deflateEnd(&stream) }
        var input = [UInt8](content)
        var output = [UInt8](repeating: 0, count: Int(deflateBound(&stream, uLong(input.count))) + 16)
        let status = input.withUnsafeMutableBufferPointer { source in
            output.withUnsafeMutableBufferPointer { target in
                stream.next_in = source.baseAddress; stream.avail_in = uInt(source.count)
                stream.next_out = target.baseAddress; stream.avail_out = uInt(target.count)
                return zlib.deflate(&stream, Z_FINISH)
            }
        }
        XCTAssertEqual(status, Z_STREAM_END)
        return Data(output.prefix(Int(stream.total_out)))
    }
}

private extension Data {
    /// The export with one voice line's duration changed.
    func replacingVoice(_ seconds: Int, with other: Int) -> Data {
        Data(String(decoding: self, as: UTF8.self).replacingOccurrences(of: "[语音] \(seconds)\"", with: "[语音] \(other)\"").utf8)
    }
}
