import Foundation
import XCTest
import zlib
@testable import DukouCore

final class WeChatVoiceTranscriptsTests: XCTestCase {
    private var temporary: TemporaryInbox!
    override func setUp() { temporary = TemporaryInbox() }
    override func tearDown() { temporary.tearDown() }

    // Synthetic chat. Two senders whose names have a space and the word 语音
    // in them, a voice message nobody converted, and an image between.
    private let export = """
    ·小林 Lin
    2026年11月20日 09:10
    [语音] 18"

    ·阿 语音
    2026年11月20日 09:11
    今天的会改到下午

    ·小林 Lin
    2026年11月20日 09:12
    [语音] 20"

    ·阿 语音
    2026年11月20日 09:13
    [图片] 图片_1.jpg

    ·阿 语音
    2026年11月20日 09:14
    [语音] 7"

    """
    /// The same five messages as multi-select reads them, oldest first.
    private let rows = [
        "小林 Lin 语音18\"秒明天上午十点开会",
        "阿 语音 今天的会改到下午",
        "小林 Lin 语音20\"秒",
        "阿 语音 图片",
        "阿 语音 语音7\"秒收到，我去订会议室",
    ]
    private var voices: [WeChatVoiceMessage] { rows.compactMap(WeChatVoiceMessage.parse(row:)) }
    private var merged: String {
        export.replacingOccurrences(of: "[语音] 18\"\n", with: "[语音] 18\" 转文字：明天上午十点开会\n")
            .replacingOccurrences(of: "[语音] 7\"\n", with: "[语音] 7\" 转文字：收到，我去订会议室\n")
    }

    // MARK: - Rows

    func testRowsReadTheSameOutsideAndInsideMultiSelect() {
        let plain = WeChatVoiceMessage(seconds: 18, transcript: "明天上午十点开会")
        XCTAssertEqual(WeChatVoiceMessage.parse(row: "语音18\"秒明天上午十点开会"), plain)
        XCTAssertEqual(WeChatVoiceMessage.parse(row: "小林 语音18\"秒明天上午十点开会"), plain)
        XCTAssertEqual(WeChatVoiceMessage.parse(row: "小林 Lin 语音18\"秒明天上午十点开会"), plain, "A name with spaces in it")
        XCTAssertEqual(WeChatVoiceMessage.parse(row: "语音小助手 语音18\"秒明天上午十点开会"), plain, "A name that starts with 语音")
        XCTAssertEqual(WeChatVoiceMessage.parse(row: "阿 语音 语音18\"秒明天上午十点开会"), plain, "A name that ends in 语音 after a space")
        XCTAssertEqual(WeChatVoiceMessage.parse(row: "小林 语音60\"秒语音5\"秒是另一条吗"),
                       WeChatVoiceMessage(seconds: 60, transcript: "语音5\"秒是另一条吗"), "Only the first duration is the message's")
    }

    func testAnUnconvertedVoiceMessageIsStillAVoiceMessage() {
        for row in ["语音20\"秒", "小林 Lin 语音20\"秒", "语音20\"秒  ", "语音20\"秒\n"] {
            XCTAssertEqual(WeChatVoiceMessage.parse(row: row), WeChatVoiceMessage(seconds: 20, transcript: ""), row)
        }
    }

    func testRowsThatAreNotVoiceMessages() {
        for row in ["", "你好", "图片", "阿 语音 今天的会改到下午", "小林 [语音] 5\"", "发了条语音5\"秒", "语音\"秒", "语音5秒", "语音abc\"秒", "语音1234\"秒"] {
            XCTAssertNil(WeChatVoiceMessage.parse(row: row), row)
        }
    }

    func testATranscriptIsAlwaysOneLine() {
        XCTAssertEqual(WeChatVoiceMessage.parse(row: "语音9\"秒第一句\n第二句\r\n\u{2028}第三句 ")?.transcript, "第一句 第二句 第三句")
        XCTAssertEqual(WeChatVoiceMessage(seconds: 9, transcript: "x\n·伪造\n2026年9月8日 10:00\n").transcript, "x ·伪造 2026年9月8日 10:00")
    }

    // MARK: - Text

    func testEachTranscriptGoesOnTheEndOfItsOwnVoiceLineAndNothingElseChanges() {
        let (text, outcome) = WeChatVoiceTranscripts.merge(voices, into: Data(export.utf8))
        XCTAssertEqual(outcome, .merged(voiceMessages: 3, transcripts: 2))
        XCTAssertEqual(String(decoding: text, as: UTF8.self), merged)
    }

    func testAnExportWithoutSendersOrTimesIsMergedTheSameWay() {
        let plain = "·今天的会改到下午\n\n·[语音] 10\"\n\n·[语音] 18\"\n\n·[图片]\n\n"
        let voices = [WeChatVoiceMessage(seconds: 10, transcript: "好"), WeChatVoiceMessage(seconds: 18, transcript: "明天见")]
        let (text, outcome) = WeChatVoiceTranscripts.merge(voices, into: Data(plain.utf8))
        XCTAssertEqual(outcome, .merged(voiceMessages: 2, transcripts: 2))
        XCTAssertEqual(String(decoding: text, as: UTF8.self),
                       "·今天的会改到下午\n\n·[语音] 10\" 转文字：好\n\n·[语音] 18\" 转文字：明天见\n\n·[图片]\n\n")
    }

    func testAByteOrderMarkAndCRLFSurvive() {
        let source = Data([0xEF, 0xBB, 0xBF]) + Data("·[语音] 5\"\r\n\r\n·好\r\n".utf8)
        let (text, outcome) = WeChatVoiceTranscripts.merge([WeChatVoiceMessage(seconds: 5, transcript: "收到")], into: source)
        XCTAssertEqual(outcome, .merged(voiceMessages: 1, transcripts: 1))
        XCTAssertEqual(text, Data([0xEF, 0xBB, 0xBF]) + Data("·[语音] 5\" 转文字：收到\r\n\r\n·好\r\n".utf8))
    }

    func testAnyDisagreementLeavesTheTextExactlyAsWeChatWroteIt() {
        let source = Data(export.utf8)
        let cases: [([WeChatVoiceMessage], WeChatVoiceTranscripts.Outcome)] = [
            (Array(voices.dropLast()), .mismatch(inExport: 3, onScreen: 2, firstDifference: nil)),
            (voices + [WeChatVoiceMessage(seconds: 3, transcript: "多一条")], .mismatch(inExport: 3, onScreen: 4, firstDifference: nil)),
            ([voices[0], WeChatVoiceMessage(seconds: 21, transcript: ""), voices[2]], .mismatch(inExport: 3, onScreen: 3, firstDifference: 1)),
            (voices.reversed(), .mismatch(inExport: 3, onScreen: 3, firstDifference: 0)),
            ([], .mismatch(inExport: 3, onScreen: 0, firstDifference: nil)),
        ]
        for (voices, expected) in cases {
            let (text, outcome) = WeChatVoiceTranscripts.merge(voices, into: source)
            XCTAssertEqual(outcome, expected)
            XCTAssertEqual(text, source)
        }
        let none = Data("·甲\n2026年11月20日 09:10\n好\n".utf8)
        let (text, outcome) = WeChatVoiceTranscripts.merge([WeChatVoiceMessage(seconds: 5, transcript: "收到")], into: none)
        XCTAssertEqual(outcome, .mismatch(inExport: 0, onScreen: 1, firstDifference: nil))
        XCTAssertEqual(text, none)
    }

    func testNothingToAddLeavesTheTextAlone() {
        let none = Data("·甲\n2026年11月20日 09:10\n好\n".utf8)
        XCTAssertEqual(WeChatVoiceTranscripts.merge([], into: none).outcome, .noVoiceMessages)
        let unconverted = voices.map { WeChatVoiceMessage(seconds: $0.seconds, transcript: "") }
        let (text, outcome) = WeChatVoiceTranscripts.merge(unconverted, into: Data(export.utf8))
        XCTAssertEqual(outcome, .noTranscripts(voiceMessages: 3))
        XCTAssertEqual(text, Data(export.utf8))
    }

    func testCardInsidesAndMergedLinesAreNotVoiceLines() {
        // A forwarded chat record is one row on screen; what it holds is
        // indented in the TXT and never a voice message of this chat.
        let card = "·甲\n2026年11月20日 09:10\n[聊天记录]\n\n    ·乙\n    2026年11月19日 08:00\n    [语音] 5\"\n\n·甲\n2026年11月20日 09:11\n[语音] 8\"\n"
        let (text, outcome) = WeChatVoiceTranscripts.merge([WeChatVoiceMessage(seconds: 8, transcript: "好")], into: Data(card.utf8))
        XCTAssertEqual(outcome, .merged(voiceMessages: 1, transcripts: 1))
        XCTAssertEqual(String(decoding: text, as: UTF8.self), card.replacingOccurrences(of: "[语音] 8\"\n", with: "[语音] 8\" 转文字：好\n"))
        // Merging what has already been merged finds no voice line to match.
        let again = WeChatVoiceTranscripts.merge(voices, into: Data(merged.utf8))
        XCTAssertEqual(again.outcome, .mismatch(inExport: 1, onScreen: 3, firstDifference: 0))
        XCTAssertEqual(again.text, Data(merged.utf8))
    }

    func testMergedTextKeepsItsRecordsAndHasNoAttachmentOnAVoiceLine() throws {
        let before = try WeChatTranscriptRecord.parse(export), after = try WeChatTranscriptRecord.parse(merged)
        XCTAssertEqual(after.count, 5)
        XCTAssertEqual(after.map(\.sender), before.map(\.sender))
        XCTAssertEqual(after.map(\.date), before.map(\.date))
        XCTAssertEqual(after[0].text, "[语音] 18\" 转文字：明天上午十点开会")
        XCTAssertEqual(Array(after[1...3].map(\.text)), Array(before[1...3].map(\.text)))
        let image = "聊天记录内的图片、视频和文件/图片_1.jpg"
        let paths: Set<String> = [image]
        let byName = Dictionary(grouping: paths, by: { ($0 as NSString).lastPathComponent })
        XCTAssertNil(WeChatAttachmentKind.attachment(in: after[0].text, paths: paths, byName: byName))
        XCTAssertEqual(WeChatAttachmentKind.attachment(in: after[3].text, paths: paths, byName: byName)?.path, image)
    }

    // MARK: - Receipt

    func testTheReceiptIsRewrittenInPlaceAndStillReadsStrictly() throws {
        let photo = Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let source = nativeZIP([("聊天记录.txt", Data(export.utf8), true), ("聊天记录内的图片、视频和文件/图片_1.jpg", photo, true),
                                ("聊天记录内的图片、视频和文件/说明.dat", Data([9, 8, 7]), false)])
        XCTAssertEqual(try WeChatNativeArchive.messageCount(source), 5)
        let receipt = try batch(source)
        let outcome = try WeChatVoiceTranscripts.merge(voices, intoReceiptAt: receipt.directory)
        XCTAssertEqual(outcome, .merged(voiceMessages: 3, transcripts: 2))

        let reread = try XCTUnwrap(temporary.reader.batch(at: receipt.directory))
        let item = try XCTUnwrap(reread.items.first)
        XCTAssertEqual(item.id, receipt.items[0].id)
        XCTAssertEqual(item.displayName, receipt.items[0].displayName)
        let data = try WeChatNativeArchive.receipt(at: receipt.directory).data
        XCTAssertEqual(Int64(data.count), item.byteCount)
        XCTAssertEqual(try Data(contentsOf: item.url), data)
        let transcript = try XCTUnwrap(WeChatNativeArchive.transcript(data))
        XCTAssertEqual(transcript.path, "聊天记录.txt")
        XCTAssertEqual(transcript.body, merged)
        XCTAssertEqual(transcript.records?.count, 5)
        XCTAssertEqual(try WeChatNativeArchive.messageCount(data), 5, "Every entry still passes its CRC")
        XCTAssertTrue(WeChatNativeArchive.isReplacement(data, of: source, at: "聊天记录.txt", holding: Data(merged.utf8)),
                      "Every other entry keeps WeChat's compressed bytes")
        let folder = temporary.root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let extracted = try WeChatNativeArchive.extract(data, to: folder)
        XCTAssertEqual(extracted.count, 3)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("聊天记录内的图片、视频和文件/图片_1.jpg")), photo)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: item.url.deletingLastPathComponent().path), [item.displayName])
    }

    func testEveryDeliveryPathCarriesTheTranscripts() throws {
        let photo = Data([1, 2, 3])
        let files: [(String, Data, Bool)] = [("聊天记录.txt", Data(export.utf8), true), ("聊天记录内的图片、视频和文件/图片_1.jpg", photo, true)]
        func withTranscripts(_ data: Data) throws -> ReadyBatch {
            let receipt = try batch(data)
            XCTAssertEqual(try WeChatVoiceTranscripts.merge(voices, intoReceiptAt: receipt.directory), .merged(voiceMessages: 3, transcripts: 2))
            return try XCTUnwrap(temporary.reader.batch(at: receipt.directory))
        }
        // The native ZIP as it is, renamed.
        let plain = try withTranscripts(nativeZIP(files))
        let delivered = try WeChatExportArchive.prepare([plain], chat: "测试群", fallbackCounts: [100], mergeArchives: false,
                                                        htmlPreview: false, in: temporary.inbox)
        XCTAssertEqual(delivered, [plain.directory])
        let renamed = try XCTUnwrap(temporary.reader.batch(at: plain.directory)?.items.first)
        XCTAssertTrue(renamed.displayName.contains("5条"), renamed.displayName)
        XCTAssertEqual(try WeChatNativeArchive.transcript(Data(contentsOf: renamed.url))?.body, self.merged)

        // Merged, with the HTML preview, and as a Markdown note.
        let second = "·小林 Lin\n2026年11月20日 10:00\n[语音] 3\"\n"
        let first = try withTranscripts(nativeZIP(files))
        let later = try batch(nativeZIP([("聊天记录.txt", Data(second.utf8), true)]))
        XCTAssertEqual(try WeChatVoiceTranscripts.merge([WeChatVoiceMessage(seconds: 3, transcript: "好的")], intoReceiptAt: later.directory),
                       .merged(voiceMessages: 1, transcripts: 1))
        let both = try [first, XCTUnwrap(temporary.reader.batch(at: later.directory))]
        for markdown in [false, true] {
            let prepared = try WeChatExportArchive.prepare(both, chat: "测试群", fallbackCounts: [100, 100], mergeArchives: true,
                                                           htmlPreview: !markdown, markdown: markdown, in: temporary.inbox)
            let item = try XCTUnwrap(temporary.reader.batch(at: XCTUnwrap(prepared.first))?.items.first)
            XCTAssertTrue(item.displayName.contains("6条"), item.displayName)
            let extracted = try unzip(item.url)
            let root = try String(contentsOf: extracted.appendingPathComponent("聊天记录.txt"), encoding: .utf8)
            XCTAssertTrue(root.contains(self.merged))
            XCTAssertTrue(root.contains("[语音] 3\" 转文字：好的"))
            XCTAssertEqual(try String(contentsOf: extracted.appendingPathComponent("batches/0001/聊天记录.txt"), encoding: .utf8), self.merged)
            XCTAssertEqual(try Data(contentsOf: extracted.appendingPathComponent("batches/0001/聊天记录内的图片、视频和文件/图片_1.jpg")), photo)
            if markdown {
                let note = try String(contentsOf: extracted.appendingPathComponent("聊天记录.md"), encoding: .utf8)
                XCTAssertTrue(note.contains("messages: 6"))
                XCTAssertTrue(note.contains("\\[语音] 18\" 转文字：明天上午十点开会"))
                XCTAssertTrue(note.contains("\\[语音] 20\"\n"))
                XCTAssertTrue(note.contains("![图片_1.jpg](batches/0001/"))
            } else {
                let messages = try previewMessages(in: extracted)
                XCTAssertEqual(messages.count, 6)
                let parts = messages.map { $0["parts"] as? [[String: Any]] ?? [] }
                XCTAssertEqual(parts[0].map { $0["text"] as? String }, ["[语音] 18\" 转文字：明天上午十点开会"])
                XCTAssertEqual(parts[2].map { $0["text"] as? String }, ["[语音] 20\""])
                XCTAssertNotNil(parts[3].first?["file"], "The image is still an attachment")
                XCTAssertEqual(parts[5].map { $0["text"] as? String }, ["[语音] 3\" 转文字：好的"])
            }
        }
    }

    func testAMismatchLeavesTheReceiptByteForByte() throws {
        let receipt = try batch(nativeZIP([("聊天记录.txt", Data(export.utf8), true)]))
        let zip = try Data(contentsOf: receipt.items[0].url)
        let manifest = try Data(contentsOf: receipt.directory.appendingPathComponent(BatchStaging.manifestFileName))
        for wrong in [Array(voices.dropFirst()), [voices[0], voices[2], voices[1]]] {
            let outcome = try WeChatVoiceTranscripts.merge(wrong, intoReceiptAt: receipt.directory)
            guard case .mismatch = outcome else { return XCTFail("\(outcome)") }
        }
        XCTAssertEqual(try WeChatVoiceTranscripts.merge(voices.map { WeChatVoiceMessage(seconds: $0.seconds, transcript: "") },
                                                       intoReceiptAt: receipt.directory), .noTranscripts(voiceMessages: 3))
        XCTAssertEqual(try Data(contentsOf: receipt.items[0].url), zip)
        XCTAssertEqual(try Data(contentsOf: receipt.directory.appendingPathComponent(BatchStaging.manifestFileName)), manifest)
    }

    func testCancellingBeforeTheSwapLeavesTheReceiptAsItArrived() throws {
        let receipt = try batch(nativeZIP([("聊天记录.txt", Data(export.utf8), true), ("large.bin", Data(repeating: 0x35, count: 3_000_000), false)]))
        let zip = try Data(contentsOf: receipt.items[0].url)
        let manifest = try Data(contentsOf: receipt.directory.appendingPathComponent(BatchStaging.manifestFileName))
        for stop in [1, 3, 6, 9] {
            var checks = 0
            XCTAssertThrowsError(try WeChatVoiceTranscripts.merge(voices, intoReceiptAt: receipt.directory) {
                checks += 1
                if checks == stop { throw CancellationError() }
            }) { XCTAssertTrue($0 is CancellationError, "\($0)") }
            XCTAssertEqual(try Data(contentsOf: receipt.items[0].url), zip)
            XCTAssertEqual(try Data(contentsOf: receipt.directory.appendingPathComponent(BatchStaging.manifestFileName)), manifest)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: receipt.items[0].url.deletingLastPathComponent().path),
                           [receipt.items[0].displayName], "No partial file is left behind")
        }
    }

    func testDataDescriptorsAndExtraFieldsComeOutInTheStrictShape() throws {
        // bsdtar writes both, so its ZIP stands in for a source not shaped
        // like WeChat's.
        let payload = temporary.root.appendingPathComponent("payload-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: payload.appendingPathComponent("media"), withIntermediateDirectories: true)
        try Data(export.utf8).write(to: payload.appendingPathComponent("聊天记录.txt"))
        let blob = Data((0..<20_000).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ $0 / 13) })
        try blob.write(to: payload.appendingPathComponent("media/clip.bin"))
        let archive = temporary.root.appendingPathComponent("\(UUID().uuidString).zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-c", "--format=zip", "--options=zip:hdrcharset=UTF-8", "-f", archive.path, "-C", payload.path, "聊天记录.txt", "media/clip.bin"]
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let source = try Data(contentsOf: archive)
        XCTAssertNotEqual(source[6] & 0x08, 0, "The fixture does carry a data descriptor")

        let text = WeChatVoiceTranscripts.merge(voices, into: Data(export.utf8)).text
        var written = Data()
        try WeChatNativeArchive.replacing("聊天记录.txt", with: text, in: source, to: { written.append($0) })
        XCTAssertTrue(WeChatNativeArchive.isReplacement(written, of: source, at: "聊天记录.txt", holding: text))
        XCTAssertEqual(try WeChatNativeArchive.transcript(written)?.body, merged)
        XCTAssertEqual(try WeChatNativeArchive.messageCount(written), 5)
        // Local headers name their own sizes now: no descriptor, no extra field.
        XCTAssertEqual(written[6] & 0x08, 0)
        XCTAssertEqual(written[28], 0); XCTAssertEqual(written[29], 0)
        XCTAssertFalse(WeChatNativeArchive.isReplacement(written, of: source, at: "聊天记录.txt", holding: Data(export.utf8)))
        XCTAssertThrowsError(try WeChatNativeArchive.replacing("missing.txt", with: text, in: source, to: { _ in }))
    }

    // MARK: - Fixtures

    private func batch(_ data: Data) throws -> ReadyBatch {
        let stage = try BatchStaging.create(in: temporary.inbox)
        let id = UUID(), name = "聊天记录.zip"
        try data.write(to: stage.destination(for: id, displayName: name))
        let item = ManifestItem(id: id, displayName: name, relativePath: stage.relativePath(for: id, displayName: name),
                                contentType: "public.zip-archive", byteCount: Int64(data.count), itemIndex: 0, attachmentIndex: 0, loadStrategy: .fileRepresentation)
        let ready = try stage.commit(manifest: BatchManifest(batchID: stage.batchID, createdAt: Date(), items: [item]), diagnostics: nil, intent: nil, in: temporary.inbox)
        return try XCTUnwrap(temporary.reader.batch(at: ready))
    }

    /// Shaped like WeChat 4.2.0's own ZIPs, independently of the production
    /// writer: made by DOS, version 2.0, the UTF-8 flag, no extra fields, sizes
    /// in the local headers. `deflated` entries are raw deflate.
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

    private func unzip(_ file: URL) throws -> URL {
        let destination = temporary.root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-xf", file.path, "-C", destination.path]
        process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return destination
    }

    private func previewMessages(in extracted: URL) throws -> [[String: Any]] {
        let html = try String(contentsOf: extracted.appendingPathComponent("index.html"), encoding: .utf8)
        let pattern = try NSRegularExpression(pattern: #"<script\b[^>]*\bid=["']chat-data["'][^>]*>([\s\S]*?)</script>"#)
        let match = try XCTUnwrap(pattern.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)))
        let range = try XCTUnwrap(Range(match.range(at: 1), in: html))
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(html[range].utf8)) as? [String: Any])
        return try XCTUnwrap(payload["messages"] as? [[String: Any]])
    }
}
