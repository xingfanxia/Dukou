import CommonCrypto
import Foundation
import SQLite3
import XCTest
import zlib
@testable import DukouCore
@testable import DukouWeChatDatabase

/// Reading voice transcripts out of a WeChat-shaped database, all of it
/// synthetic: pages are encrypted here with CommonCrypto the way WeChat 4's
/// SQLCipher writes them, WAL frames are built from the SQLite file-format
/// spec, and no text, username or key comes from a real chat.
final class WeChatDatabaseTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("dukou-db-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    // MARK: - Pages

    func testKeysAreDerivedTheSQLCipherFourWay() {
        let key = Synthetic.key
        let derived = WeChatDatabaseCipher.Keys(rawKey: key.raw, salt: key.salt)
        XCTAssertEqual(derived.encryption, key.encryption)
        XCTAssertEqual(derived.hmac, key.hmac)
    }

    func testAPageDecryptsToWhatWasEncryptedAndKeepsItsReserve() throws {
        let keys = Synthetic.keys
        var first = Synthetic.random(4096)
        first.replaceSubrange(0..<16, with: WeChatDatabaseCipher.header)
        first[20] = 80
        for (number, plain) in [(UInt32(1), first), (7, Synthetic.random(4096))] {
            let page = Synthetic.encrypt(plain, number: number)
            let decrypted = try XCTUnwrap(page.withUnsafeBytes { WeChatDatabaseCipher.decrypt($0, number: number, keys: keys) })
            XCTAssertEqual(decrypted[0..<4016], plain[0..<4016], "page \(number)")
            XCTAssertEqual(decrypted[4016...], page[4016...], "the IV and HMAC are copied through")
        }
    }

    func testAWrongKeyATamperedPageOrAnotherPageNumberDoesNotAuthenticate() {
        let page = Synthetic.encrypt(Synthetic.random(4096), number: 3)
        let wrong = WeChatDatabaseCipher.Keys(rawKey: Synthetic.otherRawKey, salt: Synthetic.key.salt)
        page.withUnsafeBytes { bytes in
            XCTAssertTrue(WeChatDatabaseCipher.authenticates(bytes, number: 3, keys: Synthetic.keys))
            XCTAssertNil(WeChatDatabaseCipher.decrypt(bytes, number: 3, keys: wrong))
            XCTAssertNil(WeChatDatabaseCipher.decrypt(bytes, number: 4, keys: Synthetic.keys))
        }
        var tampered = page
        tampered[100] ^= 1
        XCTAssertNil(tampered.withUnsafeBytes { WeChatDatabaseCipher.decrypt($0, number: 3, keys: Synthetic.keys) })
    }

    // MARK: - WAL

    func testOnlyFramesUpToTheLastCommitCount() {
        let a = Synthetic.random(4096), b = Synthetic.random(4096), c = Synthetic.random(4096)
        for bigEndian in [false, true] {
            let log = Synthetic.wal([(2, a, 0), (3, b, 9), (2, c, 0)], bigEndian: bigEndian)
            let wal = WeChatDatabaseWAL(log)
            XCTAssertEqual(wal.databasePages, 9)
            XCTAssertEqual(Set(wal.pages.keys), [2, 3], "the uncommitted tail is ignored")
            XCTAssertEqual(wal.pages[2].map { Array(log[$0..<$0 + 4096]) }, a)
        }
        XCTAssertNil(WeChatDatabaseWAL(Synthetic.wal([(2, a, 0)])).databasePages, "nothing committed")
    }

    func testANewerCommitReplacesAPageAndABrokenFrameEndsTheLog() {
        let a = Synthetic.random(4096), b = Synthetic.random(4096), c = Synthetic.random(4096)
        let log = Synthetic.wal([(2, a, 5), (2, b, 6)])
        XCTAssertEqual(WeChatDatabaseWAL(log).pages[2].map { Array(log[$0..<$0 + 4096]) }, b)
        XCTAssertEqual(WeChatDatabaseWAL(log).databasePages, 6)

        // A frame from before the log was restarted has the old salts, and
        // one half written has a checksum that does not hold.
        let stale = Synthetic.wal([(2, a, 5), (3, c, 6)], saltOf: [1: (1, 1)])
        XCTAssertEqual(WeChatDatabaseWAL(stale).databasePages, 5)
        var torn = Synthetic.wal([(2, a, 5), (3, c, 6)])
        torn[32 + 4120 + 24 + 10] ^= 0xFF
        XCTAssertEqual(WeChatDatabaseWAL(torn).databasePages, 5)
        XCTAssertEqual(WeChatDatabaseWAL(Data()), WeChatDatabaseWAL(Data("not a log".utf8)))
    }

    func testTheDatabaseIsReadThroughTheWALOverlay() throws {
        let plain = Synthetic.PlainDatabase()
        plain.exec("CREATE TABLE t (id INTEGER PRIMARY KEY, body TEXT)")
        for id in 1...20 { plain.exec("INSERT INTO t (body) VALUES ('first \(id)')") }
        let before = plain.image()
        for id in 21...400 { plain.exec("INSERT INTO t (body) VALUES ('\(String(repeating: "second", count: 20)) \(id)')") }
        let committed = plain.image()
        plain.exec("DELETE FROM t WHERE id > 5")
        let uncommitted = plain.image()
        XCTAssertGreaterThan(committed.count, before.count)

        // The file holds the first state; the WAL the pages the second one
        // changed or added, committed, then a page of a third, not.
        let file = root.appendingPathComponent("message_0.db")
        try Data(Synthetic.encrypt(database: before)).write(to: file)
        var frames: [(UInt32, [UInt8], UInt32)] = []
        let pages = committed.count / 4096
        for index in 0..<pages where index * 4096 >= before.count || committed[index * 4096..<(index + 1) * 4096] != before[index * 4096..<(index + 1) * 4096] {
            frames.append((UInt32(index + 1), Synthetic.encrypt(Array(committed[index * 4096..<(index + 1) * 4096]), number: UInt32(index + 1)), 0))
        }
        frames[frames.count - 1].2 = UInt32(pages)
        let changed = (0..<uncommitted.count / 4096).first { uncommitted[$0 * 4096..<($0 + 1) * 4096] != committed[$0 * 4096..<($0 + 1) * 4096] && $0 > 0 }!
        frames.append((UInt32(changed + 1), Synthetic.encrypt(Array(uncommitted[changed * 4096..<(changed + 1) * 4096]), number: UInt32(changed + 1)), 0))
        try Synthetic.wal(frames).write(to: URL(fileURLWithPath: file.path + "-wal"))

        let connection = try WeChatDatabase.Connection(file: file, rawKey: Synthetic.key.raw)
        var count: Int64 = 0, last = ""
        try connection.query("SELECT count(*), max(body) FROM t") { row in
            count = row.int(0)
            last = row.text(1) ?? ""
        }
        XCTAssertEqual(count, 400)
        XCTAssertTrue(last.hasPrefix("second"))

        // Without the WAL, the file alone.
        try FileManager.default.removeItem(atPath: file.path + "-wal")
        try WeChatDatabase.Connection(file: file, rawKey: Synthetic.key.raw).query("SELECT count(*) FROM t") { count = $0.int(0) }
        XCTAssertEqual(count, 20)
        XCTAssertThrowsError(try WeChatDatabase.Connection(file: file, rawKey: Synthetic.otherRawKey).query("SELECT count(*) FROM t") { _ in })
    }

    // MARK: - Rows

    func testProtobufFieldFive() {
        let text = Array("明天上午十点开会".utf8)
        XCTAssertEqual(WeChatDatabaseRow.transcript(in: Synthetic.packed(text)), "明天上午十点开会")
        // Past 127 bytes the lengths take two bytes and field 5 is no longer
        // UTF-8 as a whole: the transcript of a long voice message.
        let long = String(repeating: "这段话说了很久。", count: 40)
        XCTAssertEqual(WeChatDatabaseRow.transcript(in: Synthetic.packed(Array(long.utf8))), long)
        XCTAssertNil(WeChatDatabaseRow.transcript(in: Data([0x08, 0x01, 0x10, 0x96, 0x01, 0x18, 0x00])), "an unconverted voice")
        XCTAssertNil(WeChatDatabaseRow.transcript(in: Data([0x2A, 0x02, 0x08, 0x02])), "field 5 without a text")
        XCTAssertNil(WeChatProtobuf.string(field: 5, in: Data([0x08, 0x01, 0x10, 0x96, 0x01, 0x18, 0x00])), "an unconverted voice")
        XCTAssertNil(WeChatProtobuf.string(field: 5, in: Data([0x2A, 0x09, 0x41])), "a length past the end")
        XCTAssertNil(WeChatProtobuf.string(field: 5, in: Data([0x08, 0x01, 0x2B, 0x2A, 0x01, 0x41])), "a group")
        XCTAssertNil(WeChatProtobuf.string(field: 5, in: Data([0x08] + Array(repeating: 0xFF, count: 11))), "a varint that never ends")
        XCTAssertNil(WeChatProtobuf.string(field: 5, in: Data([0x2A, 0x02, 0xC3, 0x28])), "not UTF-8")
        XCTAssertEqual(WeChatProtobuf.string(field: 5, in: Data([0x09] + Array(repeating: 0, count: 8) + [0x15, 1, 2, 3, 4, 0x2A, 0x01, 0x41])), "A",
                       "fixed-size fields are skipped")
    }

    func testZstdFramesWithAndWithoutTheirSize() throws {
        let decoder = try XCTUnwrap(Zstd())
        let xml = #"<msg><voicemsg endflag="1" voicelength="7160" length="11520" /></msg>"#
        XCTAssertEqual(decoder.decompress(Synthetic.zstdVoice).map { String(decoding: $0, as: UTF8.self) }, xml)
        XCTAssertEqual(decoder.decompress(Synthetic.zstdVoiceStreamed).map { String(decoding: $0, as: UTF8.self) }, xml)
        let long = (0..<40).map { "第\($0)条：渡口把语音转成的文字补回导出里。" }.joined()
        XCTAssertEqual(decoder.decompress(Synthetic.zstdLong).map { String(decoding: $0, as: UTF8.self) }, long)
        XCTAssertNil(decoder.decompress(Synthetic.zstdLong.prefix(80)), "truncated")
        XCTAssertNil(decoder.decompress(Data("plain".utf8)))
        XCTAssertNil(decoder.decompress(Synthetic.zstdLong, limit: 100))
    }

    func testRowsAreReadForWhatTheyAreComparedOn() {
        func kind(_ type: Int64, _ content: String?, packed: Data? = nil) -> WeChatDatabaseRow.Kind {
            WeChatDatabaseRow(localType: type, content: content.map { Data($0.utf8) }, packed: packed).kind
        }
        XCTAssertEqual(kind(1, "  会议室改到   三楼 "), .text("会议室改到 三楼", afterSender: nil))
        XCTAssertEqual(kind(1, "wxid_test01:\n会议室改到三楼"), .text("wxid_test01: 会议室改到三楼", afterSender: "会议室改到三楼"))
        XCTAssertEqual(kind(1, "注意: 会议\n改期"), .text("注意: 会议 改期", afterSender: nil), "a colon and a space is no sender")
        let quote = #"<msg><appmsg appid=""><title>好的 &lt;周五&gt; &amp; &#x4E09;点</title><type>57</type><refermsg><content>&lt;title&gt;别的&lt;/title&gt;</content></refermsg></appmsg></msg>"#
        XCTAssertEqual(kind(57 << 32 | 49, "wxid_test01:\n" + quote), .app(title: "好的 <周五> & 三点"))
        XCTAssertEqual(kind(5 << 32 | 49, #"<msg><appmsg><title><![CDATA[一篇 <文章>]]></title></appmsg></msg>"#), .app(title: "一篇 <文章>"))
        XCTAssertEqual(WeChatDatabaseRow(localType: 34, content: Synthetic.zstdVoice, packed: Synthetic.packed(Array("收到\n明天见".utf8))).kind,
                       .voice(milliseconds: 7160, transcript: "收到 明天见"))
        XCTAssertEqual(kind(34, #"<msg><voicemsg voicelength="980" /></msg>"#, packed: Data([0x08, 0x01])), .voice(milliseconds: 980, transcript: ""))
        XCTAssertEqual(kind(34, "<msg/>"), .other)
        XCTAssertEqual(kind(10000, "你撤回了一条消息"), .system)
        XCTAssertEqual(kind(3, nil), .other)
    }

    func testVoiceLengthsAgreeWithTheRoundedSecondsWeChatWrites() {
        func agrees(_ seconds: Int, _ milliseconds: Int) -> Bool {
            WeChatDatabaseMatch.agrees(.voice(seconds: seconds), WeChatDatabaseRow(kind: .voice(milliseconds: milliseconds, transcript: "")))
        }
        for (milliseconds, seconds) in [(7160, 7), (3580, 4), (1980, 2), (3140, 3), (3160, 3), (4020, 4)] {
            XCTAssertTrue(agrees(seconds, milliseconds), "\(milliseconds) ms as \(seconds)\"")
        }
        XCTAssertTrue(agrees(3, 3580), "within 0.6 s either way")
        XCTAssertTrue(agrees(1, 400), "under a second is 1\"")
        XCTAssertFalse(agrees(2, 2700))
        XCTAssertFalse(agrees(5, 4300))
        XCTAssertFalse(WeChatDatabaseMatch.agrees(.opaque, WeChatDatabaseRow(kind: .system)))
        XCTAssertTrue(WeChatDatabaseMatch.agrees(.opaque, WeChatDatabaseRow(kind: .other)))
        XCTAssertTrue(WeChatDatabaseMatch.agrees(.text("收到"), WeChatDatabaseRow(kind: .app(title: "收到"))))
    }

    // MARK: - Matching

    private func voice(_ milliseconds: Int, _ transcript: String = "") -> WeChatDatabaseRow {
        WeChatDatabaseRow(kind: .voice(milliseconds: milliseconds, transcript: transcript))
    }

    private func text(_ text: String) -> WeChatDatabaseRow { WeChatDatabaseRow(kind: .text(text, afterSender: nil)) }

    private let other = WeChatDatabaseRow(kind: .other), notice = WeChatDatabaseRow(kind: .system)

    func testAContiguousSelectionPinsItsVoices() {
        let table = [text("早"), voice(4000, "不对的"), text("会议室改到三楼"), voice(7160, "明天上午十点"), notice, voice(3580), other, text("好的")]
        let verdicts = WeChatDatabaseMatch.verdicts([.text("会议室改到三楼"), .voice(seconds: 7), .voice(seconds: 4), .opaque], in: [table])
        XCTAssertEqual(verdicts, [1: .transcript("明天上午十点"), 2: .notConverted])
    }

    func testASelectionWithGapsIsReadOffItsTightestWindow() {
        let table = [voice(7160, "很久以前"), text("会议室改到三楼"), text("没选"), voice(7000, "选了"), other, text("也没选"), text("散会"),
                     voice(7100, "更晚")]
        let verdicts = WeChatDatabaseMatch.verdicts([.text("会议室改到三楼"), .voice(seconds: 7), .text("散会")], in: [table])
        XCTAssertEqual(verdicts, [1: .transcript("选了")])
    }

    func testTheTighterOfTwoTablesWinsAndTwoAsTightAreAmbiguous() {
        let tight = [text("收到"), voice(7160, "这一张"), text("散会")]
        let loose = [text("收到"), other, voice(7160, "那一张"), text("散会")]
        let messages: [WeChatVoiceMatch.Message] = [.text("收到"), .voice(seconds: 7), .text("散会")]
        XCTAssertEqual(WeChatDatabaseMatch.verdicts(messages, in: [loose, tight]), [1: .transcript("这一张")])
        let twin = [text("收到"), voice(7160, "另一张"), text("散会")]
        XCTAssertEqual(WeChatDatabaseMatch.verdicts(messages, in: [tight, twin, loose]), [1: .ambiguous])
        XCTAssertEqual(WeChatDatabaseMatch.verdicts(messages, in: [tight, tight]), [1: .transcript("这一张")], "the same transcript either way")
    }

    func testVoicesOfOneLengthInEqualWindowsAreAmbiguous() {
        let table = [text("收到"), voice(4000, "第一条"), text("其他"), text("收到"), voice(4100, "第二条")]
        XCTAssertEqual(WeChatDatabaseMatch.verdicts([.text("收到"), .voice(seconds: 4)], in: [table]), [1: .ambiguous])
        let mixed = [text("收到"), voice(4000, "转过"), text("其他"), text("收到"), voice(4100)]
        XCTAssertEqual(WeChatDatabaseMatch.verdicts([.text("收到"), .voice(seconds: 4)], in: [mixed]), [1: .ambiguous],
                       "one converted and one not may be two messages")
    }

    func testAWeakExportNeedsEveryEmbeddingToAgree() {
        // Two voices alone: the tightest reading is the adjacent pair, but
        // nothing rules out the pair further apart.
        let table = [voice(7160, "早的"), voice(4000, "早的二"), text("中间"), voice(7000, "晚的"), other, voice(4100, "晚的二")]
        let weak: [WeChatVoiceMatch.Message] = [.voice(seconds: 7), .voice(seconds: 4)]
        XCTAssertEqual(WeChatDatabaseMatch.verdicts(weak, in: [table]), [0: .ambiguous, 1: .ambiguous])
        // The same voices, every embedding on one row each, are pinned.
        XCTAssertEqual(WeChatDatabaseMatch.verdicts(weak, in: [[text("x"), voice(7160, "早的"), voice(4000, "早的二")]]),
                       [0: .transcript("早的"), 1: .transcript("早的二")])
        // Three voices are not weak: the tightest reading is taken.
        let three: [WeChatVoiceMatch.Message] = [.voice(seconds: 7), .voice(seconds: 4), .voice(seconds: 2)]
        let longer = [voice(7160, "a"), voice(4000, "b"), voice(2000, "c"), text("中间"), voice(7000, "d"), other, voice(4100, "e"), other, voice(1900, "f")]
        XCTAssertEqual(WeChatDatabaseMatch.verdicts(three, in: [longer]), [0: .transcript("a"), 1: .transcript("b"), 2: .transcript("c")])
    }

    func testNoTableThatEmbedsTheExportIsNotFound() {
        XCTAssertNil(WeChatDatabaseMatch.verdicts([.text("没有这句"), .voice(seconds: 7)], in: [[text("别的"), voice(7160, "x")]]))
        XCTAssertNil(WeChatDatabaseMatch.verdicts([.voice(seconds: 7), .text("收到")], in: [[text("收到"), voice(7160, "x")]]), "out of order")
        XCTAssertNil(WeChatDatabaseMatch.verdicts([.opaque, .voice(seconds: 7)], in: [[notice, voice(7160, "x")]]), "a notice is never selected")
        XCTAssertNil(WeChatDatabaseMatch.verdicts([.voice(seconds: 7)], in: []))
    }

    func testTimesWhenTheExportHasThemRuleOutRowsSentInAnotherMinute() {
        let minute: Int64 = 1_800_000_000
        func timed(_ row: WeChatDatabaseRow, _ time: Int64) -> WeChatDatabaseRow { WeChatDatabaseRow(kind: row.kind, time: time) }
        let old = [timed(voice(7160, "去年的"), minute - 400 * 86400), timed(voice(4000, "去年的二"), minute - 400 * 86400 + 5),
                   timed(voice(2000, "去年的三"), minute - 400 * 86400 + 9)]
        let now = [timed(voice(7160, "今天的"), minute + 30), timed(other, minute + 50), timed(voice(4000, "今天的二"), minute + 70),
                   timed(voice(2000, "今天的三"), minute + 75)]
        let messages: [WeChatVoiceMatch.Message] = [.voice(seconds: 7), .voice(seconds: 4), .voice(seconds: 2)]
        let minutes = [minute, minute + 60, minute + 60]
        XCTAssertEqual(WeChatDatabaseMatch.verdicts(messages, in: [old, now]), [0: .transcript("去年的"), 1: .transcript("去年的二"), 2: .transcript("去年的三")],
                       "without times the tighter, older run wins")
        XCTAssertEqual(WeChatDatabaseMatch.verdicts(messages, minutes: minutes, in: [old, now]),
                       [0: .transcript("今天的"), 1: .transcript("今天的二"), 2: .transcript("今天的三")])
        XCTAssertNil(WeChatDatabaseMatch.verdicts(messages, minutes: minutes, in: [old]))
    }

    // MARK: - The whole merge

    func testAForwardIsMergedFromTheDatabaseAndTheTextIsOtherwiseUntouched() throws {
        let home = try Synthetic.home(in: root, rows: Synthetic.conversation)
        let export = "·会议室改到三楼\n\n·[语音] 7\"\n\n·[图片]\n\n·[语音] 4\"\n\n·好的，收到\n"
        let (text, report) = WeChatDatabase.merge(Data(export.utf8), home: home)
        XCTAssertEqual(report.outcome, .merged)
        XCTAssertEqual(report.summary, WeChatDatabaseMatch.Summary(voiceLines: 2, attached: 1, notConverted: 1))
        XCTAssertEqual([report.files, report.tables], [1, 1])
        XCTAssertEqual(String(decoding: text, as: UTF8.self),
                       "·会议室改到三楼\n\n·[语音] 7\" 转文字：明天上午十点 在三楼\n\n·[图片]\n\n·[语音] 4\"\n\n·好的，收到\n")

        let again = WeChatDatabase.merge(text, home: home)
        XCTAssertEqual(again.report.outcome, .alreadyMerged)
        XCTAssertEqual(again.text, text)
    }

    func testTheLayoutWithSendersAndTimesUsesTheTimes() throws {
        let home = try Synthetic.home(in: root, rows: Synthetic.conversation)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy年M月d日 HH:mm"
        func record(_ time: Int64, _ body: String) -> String {
            "·小林\n\(formatter.string(from: Date(timeIntervalSince1970: TimeInterval(time))))\n\(body)\n"
        }
        let start = Synthetic.start
        let right = record(start + 60, "会议室改到三楼") + "\n" + record(start + 120, "[语音] 7\"")
        XCTAssertEqual(WeChatDatabase.merge(Data(right.utf8), home: home).report.outcome, .merged)
        let wrong = record(start + 7200, "会议室改到三楼") + "\n" + record(start + 7260, "[语音] 7\"")
        XCTAssertEqual(WeChatDatabase.merge(Data(wrong.utf8), home: home).report.outcome, .notFound)
    }

    func testOutcomesThatNeverReachOrNeverFindTheDatabase() throws {
        let nowhere = root.appendingPathComponent("empty-home")
        XCTAssertEqual(WeChatDatabase.merge(Data("·只有文字\n".utf8), home: nowhere).report.outcome, .noVoice)
        XCTAssertEqual(WeChatDatabase.merge(Data([0xFF, 0xFE]), home: nowhere).report.outcome, .unreadable)
        let voiceOnly = Data("·[语音] 7\"\n".utf8)
        XCTAssertEqual(WeChatDatabase.merge(voiceOnly, home: nowhere).report.outcome, .noKey)
        XCTAssertEqual(WeChatDatabase.check(home: nowhere), .noKeyFile)

        let home = try Synthetic.home(in: root, rows: Synthetic.conversation)
        XCTAssertEqual(WeChatDatabase.check(home: home), .ready)
        let notThere = WeChatDatabase.merge(Data("·这句不在库里\n\n·[语音] 7\"\n".utf8), home: home)
        XCTAssertEqual(notThere.report.outcome, .notFound)
        XCTAssertEqual(notThere.report.summary.voiceLines, 1)
        let late = WeChatDatabase.merge(Data("·会议室改到三楼\n\n·[语音] 7\"\n".utf8), home: home, deadline: Date.distantPast)
        XCTAssertEqual(late.report.outcome, .notFound)
        XCTAssertTrue(late.report.timedOut)

        let stale = try Synthetic.home(in: root.appendingPathComponent("stale"), rows: Synthetic.conversation, savedKeys: [Synthetic.otherRawKey])
        XCTAssertEqual(WeChatDatabase.check(home: stale), .keyMismatch)
        XCTAssertEqual(WeChatDatabase.merge(voiceOnly, home: stale).report.outcome, .noKey)

        let unreadable = root.appendingPathComponent("no-wechat")
        try Synthetic.saveKeys([Synthetic.key.raw], home: unreadable)
        XCTAssertEqual(WeChatDatabase.check(home: unreadable), .unreadable)
    }

    func testTheReceiptIsRewrittenInPlace() throws {
        let home = try Synthetic.home(in: root, rows: Synthetic.conversation)
        let export = "·会议室改到三楼\n\n·[语音] 7\"\n"
        let receipt = try Synthetic.receipt(in: root.appendingPathComponent("Ready"), txt: Data(export.utf8))
        let report = WeChatDatabase.merge(intoReceiptAt: receipt, home: home)
        XCTAssertEqual(report.outcome, .merged)
        let zip = try WeChatNativeArchive.receipt(at: receipt, accepting: Set(ShareAction.allCases)).data
        XCTAssertEqual(try WeChatNativeArchive.transcript(zip)?.body, "·会议室改到三楼\n\n·[语音] 7\" 转文字：明天上午十点 在三楼\n")
        XCTAssertEqual(WeChatDatabase.merge(intoReceiptAt: receipt, home: home).outcome, .alreadyMerged)
    }
}

// MARK: - Fixtures

enum Synthetic {
    static func random(_ count: Int) -> [UInt8] { (0..<count).map { _ in UInt8.random(in: 0...255) } }

    struct Key {
        let raw: [UInt8], salt: [UInt8], encryption: [UInt8], hmac: [UInt8]
    }

    /// Derived here, independently of `WeChatDatabaseCipher.Keys`, and once:
    /// 256 000 rounds are a noticeable fraction of a second.
    static let key: Key = {
        let raw = (0..<32).map { UInt8($0 * 7 + 1) }, salt = (0..<16).map { UInt8(0xA0 + $0) }
        func pbkdf2(_ password: [UInt8], _ salt: [UInt8], _ rounds: UInt32) -> [UInt8] {
            var derived = [UInt8](repeating: 0, count: 32)
            _ = password.withUnsafeBytes {
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), $0.baseAddress?.assumingMemoryBound(to: CChar.self), $0.count,
                                     salt, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA512), rounds, &derived, 32)
            }
            return derived
        }
        let encryption = pbkdf2(raw, salt, 256_000)
        return Key(raw: raw, salt: salt, encryption: encryption, hmac: pbkdf2(encryption, salt.map { $0 ^ 0x3A }, 2))
    }()

    static let keys = WeChatDatabaseCipher.Keys(rawKey: key.raw, salt: key.salt)
    static let otherRawKey = (0..<32).map { UInt8(255 - $0) }

    /// A plaintext page as WeChat's SQLCipher writes it: AES-256-CBC up to
    /// the reserve, then the IV and an HMAC-SHA512 over the encrypted part,
    /// the IV and the page number; page 1 starts with the salt.
    static func encrypt(_ plain: [UInt8], number: UInt32) -> [UInt8] {
        precondition(plain.count == 4096)
        let start = number == 1 ? 16 : 0, end = 4096 - 80, iv = random(16)
        var page = [UInt8](repeating: 0, count: 4096)
        if number == 1 { page.replaceSubrange(0..<16, with: key.salt) }
        let body = Array(plain[start..<end])
        var output = [UInt8](repeating: 0, count: body.count), moved = 0
        let status = CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), 0, key.encryption, 32, iv,
                             body, body.count, &output, output.count, &moved)
        precondition(status == kCCSuccess && moved == body.count)
        page.replaceSubrange(start..<end, with: output)
        page.replaceSubrange(end..<end + 16, with: iv)
        var context = CCHmacContext(), mac = [UInt8](repeating: 0, count: 64)
        CCHmacInit(&context, CCHmacAlgorithm(kCCHmacAlgSHA512), key.hmac, 32)
        let signed = Array(page[start..<end + 16])
        CCHmacUpdate(&context, signed, signed.count)
        let little: [UInt8] = [UInt8(number & 0xFF), UInt8(number >> 8 & 0xFF), UInt8(number >> 16 & 0xFF), UInt8(number >> 24)]
        CCHmacUpdate(&context, little, 4)
        CCHmacFinal(&context, &mac)
        page.replaceSubrange(end + 16..<4096, with: mac)
        return page
    }

    static func encrypt(database plain: [UInt8]) -> [UInt8] {
        stride(from: 0, to: plain.count, by: 4096).flatMap { encrypt(Array(plain[$0..<$0 + 4096]), number: UInt32($0 / 4096 + 1)) }
    }

    /// A write-ahead log per the SQLite file format: big-endian header and
    /// frame headers, running checksums over 32-bit words in the order the
    /// magic number names. `saltOf` gives a frame other salts.
    static func wal(_ frames: [(UInt32, [UInt8], UInt32)], bigEndian: Bool = false,
                    saltOf: [Int: (UInt32, UInt32)] = [:]) -> Data {
        let salts: (UInt32, UInt32) = (0x1234_5678, 0x9ABC_DEF0)
        func put(_ value: UInt32, into bytes: inout [UInt8]) {
            bytes += [UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
        }
        func word(_ bytes: [UInt8], _ index: Int) -> UInt32 {
            let b = bytes[index..<index + 4].map(UInt32.init)
            return bigEndian ? b[0] << 24 | b[1] << 16 | b[2] << 8 | b[3] : b[3] << 24 | b[2] << 16 | b[1] << 8 | b[0]
        }
        func sums(_ bytes: [UInt8], _ seed: (UInt32, UInt32)) -> (UInt32, UInt32) {
            var (a, b) = seed
            for index in stride(from: 0, to: bytes.count, by: 8) {
                a = a &+ word(bytes, index) &+ b
                b = b &+ word(bytes, index + 4) &+ a
            }
            return (a, b)
        }
        var log: [UInt8] = []
        for value in [bigEndian ? 0x377F_0683 : 0x377F_0682, 3_007_000, 4096, 0, salts.0, salts.1] as [UInt32] { put(value, into: &log) }
        var running = sums(log, (0, 0))
        put(running.0, into: &log); put(running.1, into: &log)
        for (index, (number, page, commit)) in frames.enumerated() {
            var header: [UInt8] = []
            let salt = saltOf[index] ?? salts
            for value in [number, commit, salt.0, salt.1] { put(value, into: &header) }
            running = sums(page, sums(Array(header[0..<8]), running))
            put(running.0, into: &header); put(running.1, into: &header)
            log += header + page
        }
        return Data(log)
    }

    /// An in-memory SQLite database whose pages keep 80 bytes back, as a
    /// SQLCipher database's plaintext does.
    final class PlainDatabase {
        let handle: OpaquePointer

        init() {
            var handle: OpaquePointer?
            precondition(sqlite3_open(":memory:", &handle) == SQLITE_OK)
            self.handle = handle!
            var reserve: Int32 = 80
            // SQLITE_FCNTL_RESERVE_BYTES, before the first page exists.
            precondition(sqlite3_file_control(handle, "main", 38, &reserve) == SQLITE_OK)
        }

        deinit { sqlite3_close(handle) }

        func exec(_ sql: String) { precondition(sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK, sql) }

        func insert(_ sql: String, _ values: [Any?]) {
            var statement: OpaquePointer?
            precondition(sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK)
            defer { sqlite3_finalize(statement) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            for (index, value) in values.enumerated() {
                let column = Int32(index + 1)
                switch value {
                case let value as Int64: sqlite3_bind_int64(statement, column, value)
                case let value as String: sqlite3_bind_text(statement, column, value, -1, transient)
                case let value as Data: _ = value.withUnsafeBytes { sqlite3_bind_blob(statement, column, $0.baseAddress, Int32($0.count), transient) }
                default: sqlite3_bind_null(statement, column)
                }
            }
            precondition(sqlite3_step(statement) == SQLITE_DONE)
        }

        func image() -> [UInt8] {
            var size: sqlite3_int64 = 0
            let bytes = sqlite3_serialize(handle, "main", &size, 0)!
            defer { sqlite3_free(bytes) }
            precondition(bytes[20] == 80 && size % 4096 == 0)
            return Array(UnsafeBufferPointer(start: bytes, count: Int(size)))
        }
    }

    /// Protobuf with a varint field 1 and the transcript as field 5.
    /// As WeChat stores a converted voice: field 5 is a message whose field 2
    /// is the text.
    static func packed(_ text: [UInt8]) -> Data {
        func varint(_ value: Int) -> [UInt8] {
            var value = value, bytes: [UInt8] = []
            repeat {
                bytes.append(UInt8(value & 0x7F) | (value > 0x7F ? 0x80 : 0))
                value >>= 7
            } while value > 0
            return bytes
        }
        let inner = [0x08, 0x02, 0x12] + varint(text.count) + text
        return Data([0x08, 0x01, 0x10, 0x02, 0x2A] + varint(inner.count) + inner + [0x58, 0x00])
    }

    static let start: Int64 = {
        // A whole minute in the current time zone, as the TXT's times are.
        let now = Int64(Date().timeIntervalSince1970) - 3 * 86400
        return now - now % 3600
    }()

    typealias Row = (type: Int64, content: Data?, packed: Data?, time: Int64)

    /// One group chat: a voice before the selection, then text, a converted
    /// voice, an image, a voice nobody converted and a reply.
    static let conversation: [Row] = [
        (34, Data(#"<msg><voicemsg voicelength="7020" /></msg>"#.utf8), packed(Array("更早的一条".utf8)), start),
        (1, Data("wxid_test01:\n会议室改到三楼".utf8), nil, start + 70),
        (34, zstdVoice, packed(Array("明天上午十点\n在三楼".utf8)), start + 125),
        (1, Data("wxid_test03:\n没被选上".utf8), nil, start + 130),
        (3, Data("<msg><img/></msg>".utf8), nil, start + 140),
        (10000, Data("wxid_test03 加入了群聊".utf8), nil, start + 150),
        (34, Data(#"<msg><voicemsg voicelength="3580" /></msg>"#.utf8), Data([0x08, 0x01, 0x10, 0x02]), start + 160),
        (57 << 32 | 49, Data(#"wxid_test01:\#n<msg><appmsg><title>好的，收到</title><type>57</type></appmsg></msg>"#.utf8), nil, start + 170),
    ]

    static let table = "Msg_" + String(repeating: "0123456789abcdef", count: 2)

    /// A home folder with chatlog's key file and one WeChat account whose
    /// only message file holds `rows` in one conversation, plus an empty one.
    static func home(in root: URL, rows: [Row], savedKeys: [[UInt8]] = [otherRawKey, key.raw]) throws -> URL {
        let home = root.appendingPathComponent("home-\(UUID().uuidString)")
        let folder = home.appendingPathComponent("Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files/wxid_test_0000/db_storage/message")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let plain = PlainDatabase()
        for name in [table, "Msg_" + String(repeating: "f", count: 32)] {
            plain.exec("""
                CREATE TABLE "\(name)" (local_id INTEGER PRIMARY KEY AUTOINCREMENT, server_id INTEGER, local_type INTEGER, sort_seq INTEGER,
                    real_sender_id INTEGER, create_time INTEGER, status INTEGER, source TEXT, message_content TEXT, compress_content TEXT,
                    packed_info_data BLOB, WCDB_CT_message_content INTEGER)
                """)
            plain.exec("CREATE INDEX \"\(name)_SORTSEQ\" ON \"\(name)\" (sort_seq)")
            plain.exec("CREATE INDEX \"\(name)_TYPE_SEQ\" ON \"\(name)\" (local_type, sort_seq)")
        }
        plain.exec("CREATE TABLE Name2Id (user_name TEXT)")
        for (index, row) in rows.enumerated() {
            plain.insert("INSERT INTO \"\(table)\" (local_type, sort_seq, create_time, message_content, packed_info_data) VALUES (?, ?, ?, ?, ?)",
                         [row.type, Int64(index + 1) * 1000, row.time, row.content, row.packed])
        }
        try Data(encrypt(database: plain.image())).write(to: folder.appendingPathComponent("message_0.db"))
        try saveKeys(savedKeys, home: home)
        return home
    }

    static func saveKeys(_ keys: [[UInt8]], home: URL) throws {
        let folder = home.appendingPathComponent(".chatlog")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let history = keys.map { ["type": "wechat", "data_key": $0.map { String(format: "%02x", $0) }.joined(), "data_dir": "/nowhere"] }
        try JSONSerialization.data(withJSONObject: ["history": history]).write(to: folder.appendingPathComponent("chatlog.json"))
    }

    /// `Ready/<batch>/` with a manifest and a one-entry stored ZIP.
    static func receipt(in ready: URL, txt: Data) throws -> URL {
        let id = UUID(), item = UUID(), directory = ready.appendingPathComponent(id.uuidString)
        let relative = "items/\(item.uuidString)/聊天记录.zip"
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("items/\(item.uuidString)"), withIntermediateDirectories: true)
        var zip = Data(), central = Data()
        func put(_ value: UInt32, _ bytes: Int, into output: inout Data) {
            for index in 0..<bytes { output.append(UInt8(truncatingIfNeeded: value >> (index * 8))) }
        }
        let name = Data("聊天记录.txt".utf8)
        let crc = txt.withUnsafeBytes { UInt32(crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count))) }
        put(0x04034b50, 4, into: &zip)
        for value: UInt32 in [20, 0x800, 0, 0, 0] { put(value, 2, into: &zip) }
        for value in [crc, UInt32(txt.count), UInt32(txt.count)] { put(value, 4, into: &zip) }
        put(UInt32(name.count), 2, into: &zip); put(0, 2, into: &zip)
        zip.append(name); zip.append(txt)
        put(0x02014b50, 4, into: &central)
        for value: UInt32 in [0, 20, 0x800, 0, 0, 0] { put(value, 2, into: &central) }
        for value in [crc, UInt32(txt.count), UInt32(txt.count)] { put(value, 4, into: &central) }
        for value: UInt32 in [UInt32(name.count), 0, 0, 0, 0] { put(value, 2, into: &central) }
        put(0, 4, into: &central); put(0, 4, into: &central); central.append(name)
        let start = zip.count
        zip.append(central)
        put(0x06054b50, 4, into: &zip)
        for value: UInt32 in [0, 0, 1, 1] { put(value, 2, into: &zip) }
        put(UInt32(central.count), 4, into: &zip); put(UInt32(start), 4, into: &zip); put(0, 2, into: &zip)
        try zip.write(to: directory.appendingPathComponent(relative))
        let manifest = BatchManifest(batchID: id, createdAt: Date(), items: [
            ManifestItem(id: item, displayName: "聊天记录.zip", relativePath: relative, contentType: "public.zip-archive",
                         byteCount: Int64(zip.count), itemIndex: 0, attachmentIndex: 0, loadStrategy: .fileRepresentation),
        ], action: .clipboard)
        try BatchManifest.encoder().encode(manifest).write(to: directory.appendingPathComponent(BatchStaging.manifestFileName))
        return directory
    }

    /// `<msg><voicemsg endflag="1" voicelength="7160" length="11520" /></msg>`
    /// as zstd 1.5.7 writes it, with its size and, from a pipe, without.
    static let zstdVoice = Data([
        0x28, 0xB5, 0x2F, 0xFD, 0x24, 0x45, 0xF5, 0x01, 0x00, 0x82, 0xC3, 0x0C, 0x11, 0xA0, 0x6F, 0x40, 0xAA, 0x7F, 0xC7, 0xB4,
        0xAA, 0x87, 0x50, 0xC9, 0x51, 0x61, 0x26, 0xFF, 0x61, 0x0D, 0xE7, 0x27, 0x04, 0x7E, 0xC0, 0x72, 0x10, 0xA3, 0x7B, 0x39,
        0x90, 0x2E, 0x6C, 0x1A, 0xFD, 0xB8, 0xDE, 0x72, 0xB3, 0x79, 0xF4, 0x98, 0x8A, 0x6B, 0x7F, 0xC2, 0x95, 0x9C, 0xAC, 0x7E,
        0x7E, 0x42, 0x0F, 0x02, 0x00, 0x31, 0x49, 0x8D, 0xD7, 0x1C, 0x03, 0x70, 0x64, 0x82, 0x2F,
    ])
    static let zstdVoiceStreamed = Data([
        0x28, 0xB5, 0x2F, 0xFD, 0x04, 0x68, 0xF5, 0x01, 0x00, 0x82, 0xC3, 0x0C, 0x11, 0xA0, 0x6F, 0x40, 0xAA, 0x7F, 0xC7, 0xB4,
        0xAA, 0x87, 0x50, 0xC9, 0x51, 0x61, 0x26, 0xFF, 0x61, 0x0D, 0xE7, 0x27, 0x04, 0x7E, 0xC0, 0x72, 0x10, 0xA3, 0x7B, 0x39,
        0x90, 0x2E, 0x6C, 0x1A, 0xFD, 0xB8, 0xDE, 0x72, 0xB3, 0x79, 0xF4, 0x98, 0x8A, 0x6B, 0x7F, 0xC2, 0x95, 0x9C, 0xAC, 0x7E,
        0x7E, 0x42, 0x0F, 0x02, 0x00, 0x31, 0x49, 0x8D, 0xD7, 0x1C, 0x03, 0x70, 0x64, 0x82, 0x2F,
    ])
    /// Forty numbered copies of one sentence: literals, sequences and repeats.
    static let zstdLong = Data([
        0x28, 0xB5, 0x2F, 0xFD, 0x64, 0x2E, 0x08, 0x95, 0x04, 0x00, 0x64, 0x06, 0xE7, 0xAC, 0xAC, 0x30, 0xE6, 0x9D, 0xA1, 0xEF,
        0xBC, 0x9A, 0xE6, 0xB8, 0xA1, 0xE5, 0x8F, 0xA3, 0xE6, 0x8A, 0x8A, 0xE8, 0xAF, 0xAD, 0xE9, 0x9F, 0xB3, 0xE8, 0xBD, 0xAC,
        0xE6, 0x88, 0x90, 0xE7, 0x9A, 0x84, 0xE6, 0x96, 0x87, 0xE5, 0xAD, 0x97, 0xE8, 0xA1, 0xA5, 0xE5, 0x9B, 0x9E, 0xE5, 0xAF,
        0xBC, 0xE5, 0x87, 0xBA, 0xE9, 0x87, 0x8C, 0xE3, 0x80, 0x82, 0xE7, 0xAC, 0xAC, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37,
        0x38, 0x39, 0x31, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x32, 0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36,
        0x37, 0x38, 0x39, 0x33, 0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x27, 0xA8, 0x11, 0xC0, 0xB7, 0xFF,
        0x77, 0xE0, 0x35, 0xCB, 0x01, 0x11, 0xFC, 0xFF, 0xFF, 0xF7, 0x1B, 0xFB, 0xFF, 0xFF, 0x6E, 0xEF, 0xFF, 0xF7, 0xFF, 0xE5,
        0xFD, 0xFB, 0xFF, 0x87, 0xFB, 0xAD, 0x00, 0x89, 0x6D, 0xB3, 0xED, 0xC5, 0xEE, 0x3E, 0x4B, 0x35, 0x90, 0xF8, 0xE3, 0xA7,
    ])
}
