import Darwin
import Foundation

/// A voice message as its row in WeChat's message list reads, with the text
/// WeChat's own 转文字 left under it.
///
/// WeChat's export never carries that text, converted or not: its TXT has
/// `[语音] 18"` and nothing more. The row on screen has it, right after the
/// duration, and in multi-select after the sender's name and a space:
///
///     语音18"秒明天上午十点开会
///     小林 Lin 语音18"秒明天上午十点开会
///
/// Measured on WeChat 4.2.0. A message nobody converted is taken to read
/// `语音20"秒` with nothing after it: a voice message without a transcript,
/// still counted, so the ones around it still line up.
public struct WeChatVoiceMessage: Equatable, Sendable {
    public let seconds: Int
    /// On one line and trimmed; empty when the message was never converted.
    /// Folding line breaks here is what keeps an appended transcript from
    /// ever starting a line of its own in the TXT.
    public let transcript: String

    public init(seconds: Int, transcript: String) {
        self.seconds = seconds
        self.transcript = transcript.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Nil for a row that is not a voice message. The duration counts only at
    /// the start or after a space, so a sender whose name has spaces or the
    /// word 语音 in it is skipped over; a text message that happens to read
    /// like one is caught later, by the export having no such voice line.
    public static func parse(row text: String) -> Self? {
        guard let marker = try? NSRegularExpression(pattern: #"(?:^| )语音(\d{1,3})"秒"#),
              let match = marker.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let digits = Range(match.range(at: 1), in: text), let seconds = Int(text[digits]),
              let whole = Range(match.range, in: text) else { return nil }
        return Self(seconds: seconds, transcript: String(text[whole.upperBound...]))
    }
}

/// Puts those transcripts into the export, each on the end of its own
/// `[语音] N"` line: `[语音] 18" 转文字：明天上午十点开会`.
///
/// Same line, so no message gains or loses a line: `WeChatTranscriptRecord`
/// finds the same records, counts and file names stay as they were, the HTML
/// preview and the Markdown note show the transcript as the message's text,
/// and `WeChatAttachmentKind` still finds no attachment on a voice line. The
/// label is the export's language, like `[语音]` beside it, not the app's.
///
/// Matched by order alone, so it fails closed: the export is rewritten only
/// when its voice lines, in order, have exactly the durations read off
/// screen. One message too many, too few or out of place on either side and
/// the TXT is left exactly as WeChat wrote it.
public enum WeChatVoiceTranscripts {
    static let label = " 转文字："

    public enum Outcome: Equatable, Sendable {
        /// Neither the export nor the selected rows had a voice message.
        case noVoiceMessages
        /// They agree, but none of the voice messages had been converted.
        case noTranscripts(voiceMessages: Int)
        case merged(voiceMessages: Int, transcripts: Int)
        /// The export's voice lines are not, one for one, the voice rows read
        /// off screen; `firstDifference` is where the durations part, nil when
        /// only the counts do.
        case mismatch(inExport: Int, onScreen: Int, firstDifference: Int?)
    }

    /// `voices` oldest first, as WeChat writes them. Works on bytes: the
    /// export is split on LF alone and every byte outside the appended text
    /// is copied through, a byte order mark and CRs included. Decoding it to
    /// a `String` would drop the first and fold CRLF into one character.
    public static func merge(_ voices: [WeChatVoiceMessage], into text: Data) -> (text: Data, outcome: Outcome) {
        let lines = voiceLines(in: text)
        if lines.isEmpty && voices.isEmpty { return (text, .noVoiceMessages) }
        guard lines.map(\.seconds) == voices.map(\.seconds) else {
            let differ = zip(lines, voices).enumerated().first { $0.element.0.seconds != $0.element.1.seconds }?.offset
            return (text, .mismatch(inExport: lines.count, onScreen: voices.count, firstDifference: differ))
        }
        let transcripts = voices.filter { !$0.transcript.isEmpty }.count
        guard transcripts > 0 else { return (text, .noTranscripts(voiceMessages: voices.count)) }
        var added: [Int: String] = [:]
        for (ordinal, voice) in voices.enumerated() where !voice.transcript.isEmpty { added[ordinal] = voice.transcript }
        return (insert(added, into: text, at: lines), .merged(voiceMessages: voices.count, transcripts: transcripts))
    }

    /// One of the export's voice lines: where its own text ends, before any
    /// CR, and its duration.
    package struct VoiceLine: Equatable {
        package let end: Int
        package let seconds: Int
    }

    /// The export's voice lines, oldest first. The text is split on LF alone
    /// and read as bytes, so the offsets are the file's own.
    package static func voiceLines(in text: Data) -> [VoiceLine] {
        let bytes = [UInt8](text)
        var lines: [VoiceLine] = []
        var start = 0
        while start <= bytes.count {
            let next = bytes[start...].firstIndex(of: 0x0A) ?? bytes.count
            var from = start, end = next
            if start == 0, bytes.starts(with: [0xEF, 0xBB, 0xBF]) { from = 3 }
            if end > from, bytes[end - 1] == 0x0D { end -= 1 }
            if end >= from, let seconds = seconds(inVoiceLine: String(decoding: bytes[from..<end], as: UTF8.self)) {
                lines.append(VoiceLine(end: end, seconds: seconds))
            }
            start = next + 1
        }
        return lines
    }

    /// `text` with each transcript on the end of the voice line of its
    /// ordinal in `lines`, and every other byte copied through.
    package static func insert(_ transcripts: [Int: String], into text: Data, at lines: [VoiceLine]) -> Data {
        let bytes = [UInt8](text)
        var output = Data()
        output.reserveCapacity(bytes.count + transcripts.values.reduce(0) { $0 + $1.utf8.count + 16 })
        var copied = 0
        for (ordinal, line) in lines.enumerated() {
            guard let transcript = transcripts[ordinal], !transcript.isEmpty else { continue }
            output.append(contentsOf: bytes[copied..<line.end])
            output.append(contentsOf: Array((label + transcript).utf8))
            copied = line.end
        }
        output.append(contentsOf: bytes[copied...])
        return output
    }

    /// A line that is a voice message and nothing else: `[语音] 18"`, or
    /// `·[语音] 18"` in an export without senders and times. Indented lines
    /// are the inside of a forwarded chat-record card — one row on screen,
    /// not a voice message — and a line already carrying a transcript is not
    /// matched again.
    static func seconds(inVoiceLine line: String) -> Int? {
        var rest = Substring(line)
        if rest.first == "·" { rest = rest.dropFirst() }
        let marker = "[语音] "
        guard rest.hasPrefix(marker), rest.hasSuffix("\"") else { return nil }
        let digits = rest.dropFirst(marker.count).dropLast()
        guard (1...3).contains(digits.count), digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(digits)
    }

    /// A voice line a merge has already been at: `[语音] 18" 转文字：…`.
    package static func isMergedVoiceLine(_ line: Substring) -> Bool {
        var rest = line
        if rest.first == "·" { rest = rest.dropFirst() }
        guard let close = rest.firstIndex(of: "\""),
              seconds(inVoiceLine: String(rest[...close])) != nil else { return false }
        return rest[rest.index(after: close)...].hasPrefix(label)
    }

    /// The receipt at `directory`, its TXT rewritten in place when `merge`
    /// has something to add; untouched in every other outcome and whenever
    /// this throws.
    ///
    /// In place, so every way a quick forward is delivered — the native ZIP
    /// as it is, merged, with the HTML preview, as a Markdown note — reads
    /// the transcripts from the one file they all start from, and a forward
    /// carried on later finds its earlier batches already done. The cost is
    /// that WeChat's own TXT is not kept beside it. Every other entry keeps
    /// its compressed bytes, which `WeChatNativeArchive.isReplacement`
    /// confirms before the new file takes the old one's place.
    public static func merge(_ voices: [WeChatVoiceMessage], intoReceiptAt directory: URL,
                             checkCancellation: () throws -> Void = {}) throws -> Outcome {
        try rewriteTranscript(
            ofReceiptAt: directory, accepting: [.shelf], checkCancellation: checkCancellation,
            withoutTranscript: voices.isEmpty ? .noVoiceMessages : .mismatch(inExport: 0, onScreen: voices.count, firstDifference: nil)
        ) { original in
            let (text, outcome) = merge(voices, into: original)
            guard case .merged = outcome else { return (nil, outcome) }
            return (text, outcome)
        }
    }

    /// The receipt's TXT handed to `change`, and written back in place when
    /// `change` returns new text — see `merge(_:intoReceiptAt:)`. A receipt
    /// whose ZIP has no TXT says `withoutTranscript`.
    package static func rewriteTranscript<Result>(ofReceiptAt directory: URL, accepting actions: Set<ShareAction>,
                                          checkCancellation: () throws -> Void, withoutTranscript: Result,
                                          _ change: (Data) -> (text: Data?, result: Result)) throws -> Result {
        try checkCancellation()
        let receipt = try WeChatNativeArchive.receipt(at: directory, accepting: actions)
        guard let transcript = try WeChatNativeArchive.transcript(receipt.data, checkCancellation: checkCancellation) else {
            return withoutTranscript
        }
        let original = try WeChatNativeArchive.contents(of: transcript.path, in: receipt.data, checkCancellation: checkCancellation)
        let (text, result) = change(original)
        guard let text, text != original else { return result }
        try rewrite(receipt, at: directory, replacing: transcript.path, with: text, checkCancellation: checkCancellation)
        return result
    }

    /// The new ZIP is written beside the old one and checked; then it takes
    /// the old one's name in a single rename, and the manifest takes its new
    /// size. A manifest that cannot be written puts WeChat's bytes back, so a
    /// failure leaves the receipt as it arrived. Cancellation is observed up
    /// to the rename and not after it.
    private static func rewrite(_ receipt: WeChatNativeArchive.Receipt, at directory: URL, replacing path: String, with text: Data,
                                checkCancellation: () throws -> Void) throws {
        let file = receipt.file, manager = FileManager.default
        let folder = file.deletingLastPathComponent()
        let permissions = (try? manager.attributesOfItem(atPath: file.path)[.posixPermissions]) as? NSNumber
        func scratch() throws -> URL {
            let url = folder.appendingPathComponent(".\(UUID().uuidString).partial")
            guard manager.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: permissions ?? 0o644]) else {
                throw WeChatReadError.invalidTranscript
            }
            return url
        }
        func move(_ source: URL, over destination: URL) throws {
            let status = source.withUnsafeFileSystemRepresentation { from in
                destination.withUnsafeFileSystemRepresentation { to in Darwin.rename(from!, to!) }
            }
            guard status == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        let temporary = try scratch()
        defer { try? manager.removeItem(at: temporary) }
        let handle = try FileHandle(forWritingTo: temporary)
        do {
            try WeChatNativeArchive.replacing(path, with: text, in: receipt.data, to: { try handle.write(contentsOf: $0) },
                                              checkCancellation: checkCancellation)
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        let written = try Data(contentsOf: temporary, options: .mappedIfSafe)
        guard WeChatNativeArchive.isReplacement(written, of: receipt.data, at: path, holding: text) else { throw WeChatReadError.invalidTranscript }
        let item = receipt.item, manifest = receipt.manifest
        let updated = BatchManifest(
            batchID: manifest.batchID, createdAt: manifest.createdAt,
            items: [ManifestItem(id: item.id, displayName: item.displayName, relativePath: item.relativePath,
                                 contentType: item.contentType, byteCount: Int64(written.count),
                                 itemIndex: item.itemIndex, attachmentIndex: item.attachmentIndex, loadStrategy: item.loadStrategy)],
            action: manifest.action, schemaVersion: manifest.schemaVersion)
        let encoded = try BatchManifest.encoder().encode(updated)
        try checkCancellation()
        try move(temporary, over: file)
        do {
            try encoded.write(to: directory.appendingPathComponent(BatchStaging.manifestFileName), options: .atomic)
        } catch {
            // `receipt.data` still reads the replaced file: a rename leaves
            // what was mapped from it in place.
            if let restore = try? scratch() {
                if (try? receipt.data.write(to: restore)) == nil || (try? move(restore, over: file)) == nil {
                    try? manager.removeItem(at: restore)
                }
            }
            throw error
        }
    }
}
