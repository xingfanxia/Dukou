import CZstd
import DukouCore
import Foundation

/// A row of one of WeChat's `Msg_<md5>` tables, reduced to what lining a
/// forward's TXT up against it needs. See `WeChatDatabaseMatch`.
///
/// `local_type` keeps the base type in its low 32 bits and a subtype in its
/// high 32: 1 text, 3 image, 34 voice, 43 video, 47 sticker, 49 an app
/// message (subtype 57 a quote reply), 10000 a system notice. Short texts are
/// stored as UTF-8; long texts and every XML payload as one zstd frame, which
/// needs no dictionary. In a group chat the content starts with the sender's
/// username and `:\n`.
public struct WeChatDatabaseRow: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// `transcript` is WeChat's own 转文字, folded onto one line the way
        /// `WeChatVoiceMessage` folds one read off screen; empty when the
        /// message was never converted.
        case voice(milliseconds: Int, transcript: String)
        /// What a text message says, whitespace folded, and what it says after
        /// a `<sender>:\n` when it starts with something that looks like one.
        case text(String, afterSender: String?)
        /// An app message's `<title>`, entities decoded and folded.
        case app(title: String?)
        /// Nothing the user can select: notices of joins, recalls, pats.
        case system
        /// Images, videos, stickers, cards, calls; and content that could
        /// not be read.
        case other
    }

    public let kind: Kind
    /// `create_time`, seconds since 1970; nil when it was not read.
    public let time: Int64?

    public init(kind: Kind, time: Int64? = nil) {
        self.kind = kind
        self.time = time
    }

    public static func baseType(_ localType: Int64) -> Int64 { localType & 0xFFFF_FFFF }

    /// `content` is `message_content` as stored, nil when it was not read;
    /// `packed` is `packed_info_data`. Content is decompressed only for the
    /// kinds that are compared on it, with `decoder` when one is given.
    public init(localType: Int64, content: Data?, packed: Data?, time: Int64? = nil) {
        self.init(localType: localType, content: content, packed: packed, time: time, decoder: nil)
    }

    init(localType: Int64, content: Data?, packed: Data?, time: Int64?, decoder: Zstd?) {
        self.init(kind: Self.kind(localType: localType, content: content, packed: packed, decoder: decoder), time: time)
    }

    static func kind(localType: Int64, content: Data?, packed: Data?, decoder: Zstd?) -> Kind {
        func text() -> String? { content.flatMap { Self.text(of: $0, decoder: decoder) } }
        switch Self.baseType(localType) {
        case 1:
            guard let text = text() else { return .other }
            return .text(Self.folded(text), afterSender: Self.afterSender(text).map(Self.folded))
        case 34:
            guard let xml = text(), let milliseconds = Self.attribute("voicelength", in: xml).flatMap({ Int($0) }) else { return .other }
            let transcript = packed.flatMap(Self.transcript(in:)) ?? ""
            return .voice(milliseconds: milliseconds, transcript: WeChatVoiceMessage(seconds: 0, transcript: transcript).transcript)
        case 49:
            return .app(title: text().flatMap(Self.appTitle(in:)).map(Self.folded))
        case 10000, 10002:
            return .system
        default:
            return .other
        }
    }

    /// WeChat's own 转文字 in `packed_info_data`: field 5 is a message of
    /// its own, and that message's field 2 is the text. Read as one string,
    /// field 5 only looks like text while it is under 128 bytes — its header
    /// then passes for control characters — and stops being UTF-8 past that,
    /// which is how every long transcript once read as never converted.
    static func transcript(in packed: Data) -> String? {
        WeChatProtobuf.bytes(field: 5, in: packed).flatMap { WeChatProtobuf.string(field: 2, in: $0) }
    }

    // MARK: - Content

    static let zstdMagic: [UInt8] = [0x28, 0xB5, 0x2F, 0xFD]

    /// UTF-8 as stored, or the text of its zstd frame.
    static func text(of content: Data, decoder: Zstd?) -> String? {
        guard content.starts(with: zstdMagic) else { return String(data: content, encoding: .utf8) }
        return (decoder ?? Zstd())?.decompress(content).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// `WeChatVoiceMatch.folded`, without its cost for the many texts that
    /// have nothing to fold: no whitespace but single spaces between words.
    static func folded(_ text: String) -> String {
        var previous = true
        for scalar in text.unicodeScalars {
            let space = scalar.properties.isWhitespace
            if space && (scalar != " " || previous) { return WeChatVoiceMatch.folded(text) }
            previous = space
        }
        return previous && !text.isEmpty ? WeChatVoiceMatch.folded(text) : text
    }

    /// What follows a leading `<username>:\n`. A username has no whitespace
    /// and is short; anything else is the text itself. Comparing both the
    /// whole text and this, as `WeChatDatabaseMatch` does, means a text that
    /// merely looks like it has a sender only adds a reading, never hides one.
    static func afterSender(_ text: String) -> String? {
        guard let colon = text.range(of: ":\n") else { return nil }
        let sender = text[..<colon.lowerBound]
        guard !sender.isEmpty, sender.count <= 64, !sender.contains(where: { $0.isWhitespace || $0.isNewline }) else { return nil }
        return String(text[colon.upperBound...])
    }

    /// `name="value"` of the first element that has it.
    static func attribute(_ name: String, in xml: String) -> String? {
        guard let start = xml.range(of: " \(name)=\"") else { return nil }
        let rest = xml[start.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
    }

    /// The `<title>` of the `<appmsg>` itself — a quote reply's own text. A
    /// quoted message's XML sits escaped inside `<refermsg>`, so its tags
    /// never read as these.
    static func appTitle(in xml: String) -> String? {
        guard let message = xml.range(of: "<appmsg"),
              let open = xml.range(of: "<title>", range: message.upperBound..<xml.endIndex),
              let close = xml.range(of: "</title>", range: open.upperBound..<xml.endIndex) else { return nil }
        var title = String(xml[open.upperBound..<close.lowerBound])
        if title.hasPrefix("<![CDATA["), title.hasSuffix("]]>") {
            return String(title.dropFirst(9).dropLast(3))
        }
        title = unescaped(title)
        return title
    }

    /// XML's five named entities and numeric references.
    static func unescaped(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var output = "", rest = Substring(text)
        while let amp = rest.firstIndex(of: "&") {
            output += rest[..<amp]
            let tail = rest[amp...]
            guard let semicolon = tail.firstIndex(of: ";"), tail.distance(from: amp, to: semicolon) <= 10 else {
                output += "&"; rest = rest[rest.index(after: amp)...]; continue
            }
            let entity = tail[tail.index(after: amp)..<semicolon]
            let named = ["lt": "<", "gt": ">", "amp": "&", "quot": "\"", "apos": "'"]
            var scalar: Unicode.Scalar?
            if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
                scalar = UInt32(entity.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init)
            } else if entity.hasPrefix("#") {
                scalar = UInt32(entity.dropFirst()).flatMap(Unicode.Scalar.init)
            }
            if let value = named[String(entity)] {
                output += value
            } else if let scalar {
                output.unicodeScalars.append(scalar)
            } else {
                output += tail[...semicolon]
            }
            rest = rest[rest.index(after: semicolon)...]
        }
        return output + rest
    }
}

/// Just enough protobuf to read one top-level field.
enum WeChatProtobuf {
    /// The last top-level length-delimited field `number`, as UTF-8. Nil when
    /// it is absent, is not UTF-8, or the bytes are not a well-formed message:
    /// groups, an unknown wire type, or a length past the end.
    static func string(field number: UInt64, in data: Data) -> String? {
        bytes(field: number, in: data).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// The same field as it is stored: text, or a message inside this one.
    static func bytes(field number: UInt64, in data: Data) -> Data? {
        let bytes = [UInt8](data)
        var index = 0, found: ArraySlice<UInt8>?
        func varint() -> UInt64? {
            var value: UInt64 = 0, shift: UInt64 = 0
            while index < bytes.count, shift < 64 {
                let byte = bytes[index]
                index += 1
                value |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return value }
                shift += 7
            }
            return nil
        }
        while index < bytes.count {
            guard let key = varint() else { return nil }
            switch key & 7 {
            case 0: guard varint() != nil else { return nil }
            case 1: index += 8
            case 2:
                guard let length = varint(), length <= UInt64(bytes.count - index) else { return nil }
                if key >> 3 == number { found = bytes[index..<index + Int(length)] }
                index += Int(length)
            case 5: index += 4
            default: return nil
            }
            guard index <= bytes.count else { return nil }
        }
        return found.map { Data($0) }
    }
}

/// zstd's own decoder, vendored as `CZstd`. One per reader: a context is a
/// couple of hundred kilobytes, and making one per row was most of what
/// reading a conversation cost.
final class Zstd {
    private let context: OpaquePointer

    init?() {
        guard let context = ZSTD_createDCtx() else { return nil }
        self.context = context
    }

    deinit { ZSTD_freeDCtx(context) }

    /// `data` decoded; nil when it is not zstd, is truncated, or would come
    /// to more than `limit` bytes.
    func decompress(_ data: Data, limit: Int = 16 << 20) -> Data? {
        data.withUnsafeBytes { source -> Data? in
            let size = ZSTD_getFrameContentSize(source.baseAddress, source.count)
            // All ones is "unknown", all ones but the last bit "not zstd".
            guard size != UInt64.max - 1 else { return nil }
            guard size == UInt64.max else {
                guard size <= UInt64(limit) else { return nil }
                var output = Data(count: Int(size))
                let result = output.withUnsafeMutableBytes {
                    ZSTD_decompressDCtx(context, $0.baseAddress, $0.count, source.baseAddress, source.count)
                }
                return ZSTD_isError(result) == 0 && result == Int(size) ? output : nil
            }
            return stream(source, limit: limit)
        }
    }

    /// A frame that does not say how large it is.
    private func stream(_ source: UnsafeRawBufferPointer, limit: Int) -> Data? {
        ZSTD_DCtx_reset(context, ZSTD_reset_session_only)
        var input = ZSTD_inBuffer(src: source.baseAddress, size: source.count, pos: 0)
        var output = Data(), chunk = [UInt8](repeating: 0, count: 64 << 10), remaining = 1
        while remaining != 0 {
            let (result, produced) = chunk.withUnsafeMutableBytes { chunk -> (Int, Int) in
                var out = ZSTD_outBuffer(dst: chunk.baseAddress, size: chunk.count, pos: 0)
                let result = ZSTD_decompressStream(context, &out, &input)
                return (result, out.pos)
            }
            guard ZSTD_isError(result) == 0 else { return nil }
            output.append(contentsOf: chunk[0..<produced])
            remaining = result
            guard output.count <= limit else { return nil }
            // All of it read, more expected, nothing coming: truncated.
            if remaining != 0 && produced == 0 && input.pos == input.size { return nil }
        }
        return input.pos == input.size ? output : nil
    }
}
