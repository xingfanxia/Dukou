import Darwin
import Foundation
import zlib

/// Reads the original ZIP in memory, without extracting paths or launching a
/// helper. WeChat currently writes ordinary UTF-8, deflated ZIP entries. ZIP64,
/// encryption and unknown compression methods fail closed.
public enum WeChatNativeArchive {
    public struct Transcript: Sendable {
        public let path: String
        public let body: String
        public let records: [WeChatTranscriptRecord]?
        public var start: Date? { records?.map(\.date).min() }
        public var end: Date? { records?.map(\.date).max() }
    }

    /// Metadata is optional. A new text format can still be named and merged,
    /// and its original bytes remain available alongside the combined text.
    public static func transcript(_ data: Data, checkCancellation: () throws -> Void = {}) throws -> Transcript? {
        var candidates: [Transcript] = []
        for entry in try directory(data) where entry.name.lowercased().hasSuffix(".txt") && entry.expanded <= 16_777_216 {
            try checkCancellation()
            let body = try read(entry, from: data, collect: true, checkCancellation: checkCancellation)
            guard let text = String(data: body, encoding: .utf8) else { continue }
            candidates.append(Transcript(path: entry.name, body: text, records: try? WeChatTranscriptRecord.parse(text)))
        }
        if let native = candidates.first(where: { ($0.path as NSString).lastPathComponent == "聊天记录.txt" }) { return native }
        return candidates.max { ($0.records?.count ?? 0) < ($1.records?.count ?? 0) }
    }

    /// The first and last message time across these exports, for 续聊. Nil
    /// when none of them carries a transcript whose dates can be read — a
    /// merged ZIP Dukou built itself among them — which simply means no note
    /// is added and no cursor moves.
    public static func span(of urls: [URL]) -> (start: Date, end: Date)? {
        var start: Date?, end: Date?
        for url in urls where url.pathExtension.lowercased() == "zip" {
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                  let transcript = try? transcript(data),
                  let first = transcript.start, let last = transcript.end else { continue }
            start = min(start ?? first, first)
            end = max(end ?? last, last)
        }
        guard let start, let end else { return nil }
        return (start, end)
    }

    /// Only called for the optional merge. The destination is an empty, private
    /// staging directory, and each entry is streamed with its size/CRC checked.
    /// No ZIP path or symlink is passed to an external extraction tool.
    public static func extract(_ data: Data, to destination: URL, checkCancellation: () throws -> Void = {}) throws -> [String] {
        let entries = try directory(data)
        guard try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty else { throw WeChatReadError.invalidTranscript }
        var seen: [String: String] = [:]
        for entry in entries {
            try checkCancellation()
            let path = entry.name.hasSuffix("/") ? String(entry.name.dropLast()) : entry.name
            let parts = path.split(separator: "/", omittingEmptySubsequences: false)
            guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
                  !path.contains("\\"), !path.contains(":"),
                  !path.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }),
                  entry.fileType == 0 || entry.fileType == (entry.name.hasSuffix("/") ? 0o040000 : 0o100000) else {
                throw WeChatReadError.invalidTranscript
            }
            // Catch case/normalization aliases in parent directories too.
            for end in 1...parts.count {
                let prefix = parts.prefix(end).joined(separator: "/")
                let key = prefix.precomposedStringWithCanonicalMapping.lowercased()
                if let prior = seen[key], !prior.utf8.elementsEqual(prefix.utf8) { throw WeChatReadError.invalidTranscript }
                seen[key] = prefix
            }
        }
        for entry in entries {
            try checkCancellation()
            let output = destination.appendingPathComponent(entry.name)
            if entry.name.hasSuffix("/") {
                guard entry.expanded == 0 else { throw WeChatReadError.invalidTranscript }
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            } else {
                try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let descriptor = output.withUnsafeFileSystemRepresentation { Darwin.open($0!, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600) }
                guard descriptor >= 0 else { throw WeChatReadError.invalidTranscript }
                let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
                defer { try? file.close() }
                _ = try read(entry, from: data, collect: false, checkCancellation: checkCancellation) { try file.write(contentsOf: $0) }
                try file.close()
            }
        }
        return entries.filter { !$0.name.hasSuffix("/") }.map(\.name)
    }

    /// Checks the complete ZIP and estimates its message count when a native
    /// TXT is recognizable. Bodies, card types, dates and the selected count
    /// do not decide whether the original archive can be delivered.
    ///
    /// A future TXT format (or an attachment-only archive) has no estimate;
    /// callers can report the number selected in WeChat instead. Multiple
    /// recognizable TXT files use the largest count rather than summing
    /// attached or duplicate transcripts.
    public static func messageCount(_ data: Data, checkCancellation: () throws -> Void = {}) throws -> Int? {
        try checkCancellation()
        let entries = try directory(data)
        guard entries.contains(where: { !$0.name.hasSuffix("/") && $0.expanded > 0 }) else { throw WeChatReadError.invalidTranscript }
        var count: Int?
        for entry in entries where !entry.name.hasSuffix("/") {
            try checkCancellation()
            // Large TXT files still receive the same streaming CRC check.
            // Estimating a count must not require collecting them in memory.
            let isText = entry.name.lowercased().hasSuffix(".txt") && entry.expanded <= 16_777_216
            let body = try read(entry, from: data, collect: isText, checkCancellation: checkCancellation)
            guard isText, let text = String(data: body, encoding: .utf8), let records = try? WeChatTranscriptRecord.parse(text) else { continue }
            count = max(count ?? 0, records.count)
        }
        try checkCancellation()
        return count
    }

    /// The one ZIP in a receipt — `Ready/<batch>/` as a share entry committed
    /// it — and the manifest that describes it.
    public struct Receipt: Sendable {
        public let manifest: BatchManifest
        public let item: ManifestItem
        public let file: URL
        public let data: Data
    }

    /// Fails closed on anything but exactly one ZIP, inside the batch
    /// directory, of the size its manifest records, from one of `actions`'
    /// entries. A quick forward's receipts come from 暂存到渡口 alone; a
    /// forward made by hand can come from any entry.
    public static func receipt(at directory: URL, accepting actions: Set<ShareAction> = [.shelf]) throws -> Receipt {
        let manifest = try BatchManifest.decoder().decode(BatchManifest.self, from: Data(contentsOf: directory.appendingPathComponent(BatchStaging.manifestFileName)))
        guard manifest.schemaVersion == BatchManifest.currentSchemaVersion, actions.contains(manifest.action),
              manifest.batchID.uuidString == directory.lastPathComponent, manifest.items.count == 1,
              let item = manifest.items.first else { throw WeChatReadError.invalidTranscript }
        let file = directory.appendingPathComponent(item.relativePath).resolvingSymlinksInPath()
        guard file.path.hasPrefix(directory.resolvingSymlinksInPath().path + "/"), file.pathExtension.lowercased() == "zip" else { throw WeChatReadError.invalidTranscript }
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        guard Int64(data.count) == item.byteCount else { throw WeChatReadError.invalidTranscript }
        return Receipt(manifest: manifest, item: item, file: file, data: data)
    }

    /// One entry's bytes as WeChat wrote them, CRC checked — not decoded, so
    /// a byte order mark or a CR survives.
    static func contents(of path: String, in data: Data, checkCancellation: () throws -> Void = {}) throws -> Data {
        guard let entry = try directory(data).first(where: { $0.name == path }) else { throw WeChatReadError.invalidTranscript }
        return try read(entry, from: data, collect: true, checkCancellation: checkCancellation)
    }

    /// `data` with the entry at `path` holding `contents` instead, handed to
    /// `output` a piece at a time so a ZIP full of video is never held twice.
    ///
    /// Only for the voice transcripts `WeChatVoiceTranscripts` and
    /// `WeChatVoiceMatch` add to the native TXT. Every other entry keeps the
    /// compressed bytes, CRC, sizes, times and attributes WeChat gave it; only
    /// its headers are written afresh. The replacement is stored, which `read`
    /// takes as readily as deflate. What comes out is the one shape
    /// `directory` accepts — no data descriptor, ZIP64, extra field or
    /// comment, the central directory right after the last entry — whatever
    /// the source carried of those.
    static func replacing(_ path: String, with contents: Data, in data: Data,
                          to output: (Data) throws -> Void, checkCancellation: () throws -> Void = {}) throws {
        let entries = try directory(data)
        guard entries.filter({ $0.name == path }).count == 1 else { throw WeChatReadError.invalidTranscript }
        func put(_ value: Int, _ bytes: Int, into data: inout Data) {
            for index in 0..<bytes { data.append(UInt8(truncatingIfNeeded: value >> (index * 8))) }
        }
        var central = Data(), written = 0
        func emit(_ chunk: Data) throws {
            try output(chunk)
            written += chunk.count
        }
        for entry in entries {
            try checkCancellation()
            let replaced = entry.name == path
            let start = try payload(of: entry, in: data)
            let nameLength = try number(data, entry.header + 28, 2)
            let name = data.subdata(in: entry.header + 46..<entry.header + 46 + nameLength)
            // The data descriptor goes: these headers carry the sizes. A stored
            // replacement keeps only the UTF-8 name flag.
            let original = try number(data, entry.header + 8, 2)
            let flags = replaced ? original & 0x0800 : original & ~0x0008
            let method = replaced ? 0 : entry.method
            let crc = replaced ? Int(contents.withUnsafeBytes { crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count)) }) : Int(entry.crc)
            let size = replaced ? contents.count : entry.compressed
            let expanded = replaced ? contents.count : entry.expanded
            // 0xFFFFFFFF would announce ZIP64, which `directory` refuses.
            guard written < 0xFFFF_FFFF, size < 0xFFFF_FFFF, expanded < 0xFFFF_FFFF,
                  written + 30 + nameLength + size < 0xFFFF_FFFF else { throw WeChatReadError.invalidTranscript }
            let needed = try number(data, entry.header + 6, 2)
            let time = try number(data, entry.header + 12, 2), date = try number(data, entry.header + 14, 2)
            let offset = written
            var local = Data()
            put(0x04034b50, 4, into: &local)
            for value in [needed, flags, method, time, date] { put(value, 2, into: &local) }
            for value in [crc, size, expanded] { put(value, 4, into: &local) }
            put(nameLength, 2, into: &local); put(0, 2, into: &local)
            local.append(name)
            try emit(local)
            if replaced {
                try emit(contents)
            } else {
                for chunk in stride(from: 0, to: size, by: 1_048_576) {
                    try checkCancellation()
                    try emit(data.subdata(in: start + chunk..<start + min(size, chunk + 1_048_576)))
                }
            }
            put(0x02014b50, 4, into: &central)
            for value in [try number(data, entry.header + 4, 2), needed, flags, method, time, date] { put(value, 2, into: &central) }
            for value in [crc, size, expanded] { put(value, 4, into: &central) }
            // No extra field, no comment, disk 0; attributes as they were.
            for value in [nameLength, 0, 0, 0, try number(data, entry.header + 36, 2)] { put(value, 2, into: &central) }
            put(try number(data, entry.header + 38, 4), 4, into: &central)
            put(offset, 4, into: &central)
            central.append(name)
        }
        let directoryStart = written
        guard directoryStart + central.count < 0xFFFF_FFFF else { throw WeChatReadError.invalidTranscript }
        var end = Data()
        put(0x06054b50, 4, into: &end)
        for value in [0, 0, entries.count, entries.count] { put(value, 2, into: &end) }
        put(central.count, 4, into: &end); put(directoryStart, 4, into: &end); put(0, 2, into: &end)
        try checkCancellation()
        try emit(central)
        try emit(end)
    }

    /// Whether `written` is `original` with only `path` changed, to
    /// `contents`: the same entries in the same order, every other one with
    /// the same method, CRC, sizes, type and compressed bytes, and `path`
    /// reading back, CRC and all, as `contents`. Checked before a rewritten
    /// archive replaces WeChat's, which is not kept.
    static func isReplacement(_ written: Data, of original: Data, at path: String, holding contents: Data) -> Bool {
        guard let before = try? directory(original), let after = try? directory(written), before.count == after.count else { return false }
        for (old, new) in zip(before, after) {
            guard old.name == new.name, old.fileType == new.fileType else { return false }
            if new.name == path {
                guard (try? read(new, from: written, collect: true, checkCancellation: {})) == contents else { return false }
                continue
            }
            guard old.method == new.method, old.crc == new.crc, old.compressed == new.compressed, old.expanded == new.expanded,
                  let from = try? payload(of: old, in: original), let to = try? payload(of: new, in: written),
                  // Slices share the mapped bytes; `==` compares them without a copy.
                  original[from..<from + old.compressed] == written[to..<to + new.compressed] else { return false }
        }
        return true
    }

    private struct Entry {
        let name: String
        let method: Int
        let crc: UInt32
        let compressed: Int
        let expanded: Int
        let offset: Int
        let fileType: Int
        /// Where its central directory record starts.
        let header: Int
    }
    private static func number(_ data: Data, _ offset: Int, _ bytes: Int) throws -> Int {
        guard offset >= 0, offset <= data.count - bytes else { throw WeChatReadError.invalidTranscript }
        return (0..<bytes).reduce(0) { $0 | (Int(data[offset + $1]) << ($1 * 8)) }
    }
    private static func directory(_ data: Data) throws -> [Entry] {
        guard data.count >= 22 else { throw WeChatReadError.invalidTranscript }
        let end = try stride(from: data.count - 22, through: max(0, data.count - 65_557), by: -1).first {
            try number(data, $0, 4) == 0x06054b50 && $0 + 22 + number(data, $0 + 20, 2) == data.count
        }
        guard let end, try number(data, end + 4, 2) == 0, try number(data, end + 6, 2) == 0 else { throw WeChatReadError.invalidTranscript }
        let count = try number(data, end + 10, 2)
        let size = try number(data, end + 12, 4)
        var cursor = try number(data, end + 16, 4)
        let start = cursor
        guard (1...1000).contains(count), try number(data, end + 8, 2) == count, cursor + size == end else { throw WeChatReadError.invalidTranscript }
        var entries: [Entry] = [], seen = Set<String>(), total = 0
        for _ in 0..<count {
            guard try number(data, cursor, 4) == 0x02014b50 else { throw WeChatReadError.invalidTranscript }
            let flags = try number(data, cursor + 8, 2), method = try number(data, cursor + 10, 2)
            let nameLength = try number(data, cursor + 28, 2), extra = try number(data, cursor + 30, 2), comment = try number(data, cursor + 32, 2)
            guard flags & 1 == 0, [0, 8].contains(method), try number(data, cursor + 34, 2) == 0,
                  cursor + 46 + nameLength + extra + comment <= end else { throw WeChatReadError.invalidTranscript }
            let rawName = data.subdata(in: cursor + 46..<cursor + 46 + nameLength)
            guard let name = String(data: rawName, encoding: .utf8), !name.isEmpty, seen.insert(name).inserted else { throw WeChatReadError.invalidTranscript }
            let entry = Entry(name: name, method: method, crc: UInt32(try number(data, cursor + 16, 4)),
                              compressed: try number(data, cursor + 20, 4), expanded: try number(data, cursor + 24, 4), offset: try number(data, cursor + 42, 4),
                              fileType: try (number(data, cursor + 38, 4) >> 16) & 0o170000, header: cursor)
            total += entry.expanded
            guard total <= 1_073_741_824, entry.offset < start else { throw WeChatReadError.invalidTranscript }
            entries.append(entry)
            cursor += 46 + nameLength + extra + comment
        }
        guard cursor == end else { throw WeChatReadError.invalidTranscript }
        return entries
    }
    /// Where an entry's compressed bytes start, past its local header.
    private static func payload(of entry: Entry, in data: Data) throws -> Int {
        guard try number(data, entry.offset, 4) == 0x04034b50,
              try number(data, entry.offset + 8, 2) == entry.method else { throw WeChatReadError.invalidTranscript }
        let start = try entry.offset + 30 + number(data, entry.offset + 26, 2) + number(data, entry.offset + 28, 2)
        guard start <= data.count, entry.compressed <= data.count - start else { throw WeChatReadError.invalidTranscript }
        return start
    }
    private static func read(_ entry: Entry, from data: Data, collect: Bool, checkCancellation: () throws -> Void, write: ((Data) throws -> Void)? = nil) throws -> Data {
        guard !collect || entry.expanded <= 16_777_216 else { throw WeChatReadError.invalidTranscript }
        let start = try payload(of: entry, in: data)
        var result = Data(), crc = crc32(0, nil, 0), expanded = 0
        if collect { result.reserveCapacity(entry.expanded) }
        try data.withUnsafeBytes { (input: UnsafeRawBufferPointer) in
            let source = input.bindMemory(to: Bytef.self).baseAddress!.advanced(by: start)
            if entry.method == 0 {
                guard entry.expanded == entry.compressed else { throw WeChatReadError.invalidTranscript }
                for offset in stride(from: 0, to: entry.compressed, by: 65_536) {
                    try checkCancellation()
                    let count = min(65_536, entry.compressed - offset)
                    crc = crc32(crc, source.advanced(by: offset), uInt(count))
                    if collect { result.append(source.advanced(by: offset), count: count) }
                    if let write { try write(Data(bytes: source.advanced(by: offset), count: count)) }
                }
                expanded = entry.compressed
            } else {
                var stream = z_stream()
                guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw WeChatReadError.invalidTranscript }
                defer { inflateEnd(&stream) }
                stream.next_in = UnsafeMutablePointer(mutating: source)
                stream.avail_in = uInt(entry.compressed)
                var buffer = [UInt8](repeating: 0, count: 65_536)
                var status: Int32 = Z_OK
                repeat {
                    try checkCancellation()
                    let produced: Int = try buffer.withUnsafeMutableBufferPointer { output in
                        stream.next_out = output.baseAddress!
                        stream.avail_out = uInt(output.count)
                        status = inflate(&stream, Z_NO_FLUSH)
                        let count = output.count - Int(stream.avail_out)
                        crc = crc32(crc, output.baseAddress!, uInt(count))
                        if collect { result.append(output.baseAddress!, count: count) }
                        if let write, count > 0 { try write(Data(bytes: output.baseAddress!, count: count)) }
                        return count
                    }
                    expanded += produced
                    guard expanded <= entry.expanded, status == Z_OK || status == Z_STREAM_END,
                          produced > 0 || status == Z_STREAM_END else { throw WeChatReadError.invalidTranscript }
                } while status != Z_STREAM_END
                guard stream.avail_in == 0 else { throw WeChatReadError.invalidTranscript }
            }
        }
        guard expanded == entry.expanded, UInt32(crc) == entry.crc else { throw WeChatReadError.invalidTranscript }
        return result
    }
}
