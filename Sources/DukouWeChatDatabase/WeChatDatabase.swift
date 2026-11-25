import Darwin
import DukouCore
import Foundation
import SQLite3

/// WeChat's own message database, read for the transcripts a forward made by
/// hand leaves out of its TXT. Off unless the user turns it on.
///
/// Read only, and only into memory. WeChat's files are opened `O_RDONLY` and
/// read with `pread`: no lock is taken, nothing is written, and the WAL index
/// is not touched. Pages are decrypted one at a time as SQLite asks for them,
/// through a VFS of Dukou's own (`PageSource`), so no plaintext page ever
/// reaches a disk and a file of hundreds of megabytes costs only the pages a
/// query reads. The key is the one chatlog saved in `~/.chatlog/chatlog.json`;
/// Dukou never extracts one itself, and never logs or stores one.
///
/// Layout, on WeChat 4.2.0 for Mac: an account's history is split over
/// `db_storage/message/message_<N>.db`, new messages going to the newest
/// file. Each conversation is a table `Msg_<md5 of the peer's username>`
/// ordered by `sort_seq`; see `WeChatDatabaseRow` for its columns.
public enum WeChatDatabase {
    /// How long a merge may search before it gives up as not found. A
    /// forward to an app pastes only after it, so it waits; the newest file,
    /// where a recent selection is, takes well under a second, and going
    /// through all of an account's history takes longer than anyone should
    /// wait for a paste. The clipboard entry does not wait at all: see
    /// `AppModel.nameThenAnnounce`.
    public static let searchSeconds: TimeInterval = 3

    // MARK: - What a merge did

    public struct Report: Equatable, Sendable {
        public enum Outcome: String, Sendable {
            case merged, unmatched, notFound = "not-found", noKey = "no-key", unreadable
            case noVoice = "no-voice", alreadyMerged = "already-merged", failed
        }

        public var outcome: Outcome
        /// For `unreadable`: "export" when the TXT is not one WeChat writes,
        /// "denied" when macOS refused Dukou WeChat's folder, "database" when
        /// it is missing or could not be read.
        public var unreadable: String?
        public var summary = WeChatDatabaseMatch.Summary()
        public var files = 0
        public var tables = 0
        public var milliseconds = 0
        /// The search ran out of time before it found the export, or before
        /// it had looked everywhere.
        public var timedOut = false
        /// Voice ordinal → transcript attached. For the caller to measure,
        /// never to log.
        public var transcripts: [Int: String] = [:]

        public init(outcome: Outcome) {
            self.outcome = outcome
        }
    }

    /// Conversations looked at per file: the most recently active that have
    /// enough voice messages. Rows looked at per conversation: its latest.
    static let tableLimit = 60
    static let rowLimit = 3000

    /// `text` is the export's TXT as bytes. The text that comes back carries
    /// the transcripts that could be pinned, the way `WeChatVoiceTranscripts`
    /// writes them, and is `text` itself in every other outcome.
    public static func merge(_ text: Data, home: URL = FileManager.default.homeDirectoryForCurrentUser,
                             deadline: Date = .distantFuture) -> (text: Data, report: Report) {
        let started = Date()
        var (merged, report) = mergeTimed(text, home: home, deadline: deadline)
        report.milliseconds = Int(Date().timeIntervalSince(started) * 1000)
        if report.outcome != .merged { merged = text }
        return (merged, report)
    }

    private static func mergeTimed(_ text: Data, home: URL, deadline: Date) -> (Data, Report) {
        guard let body = WeChatVoiceMatch.normalized(text) else {
            var report = Report(outcome: .unreadable)
            report.unreadable = "export"
            return (text, report)
        }
        if body.split(separator: "\n", omittingEmptySubsequences: false).contains(where: WeChatVoiceTranscripts.isMergedVoiceLine) {
            return (text, Report(outcome: .alreadyMerged))
        }
        let lines = WeChatVoiceTranscripts.voiceLines(in: text)
        guard !lines.isEmpty else { return (text, Report(outcome: .noVoice)) }
        var report = Report(outcome: .failed)
        report.summary.voiceLines = lines.count
        guard let messages = WeChatVoiceMatch.messages(in: body), messages.compactMap(\.seconds) == lines.map(\.seconds) else {
            report.outcome = .unreadable
            report.unreadable = "export"
            return (text, report)
        }
        // The layout with senders gives each message's time, to the minute.
        let minutes = (try? WeChatTranscriptRecord.parse(body)).flatMap { records in
            records.count == messages.count ? records.map { Int64($0.date.timeIntervalSince1970) } : nil
        }
        let account: Account
        do {
            account = try Account.find(home: home)
        } catch {
            report.outcome = error == .noKeyFile || error == .keyMismatch ? .noKey : .unreadable
            if report.outcome == .unreadable { report.unreadable = error == .denied ? "denied" : "database" }
            return (text, report)
        }
        let verdicts: [Int: WeChatDatabaseMatch.Verdict]
        do {
            guard let found = try search(messages, minutes: minutes, in: account, deadline: deadline, report: &report) else {
                report.outcome = .notFound
                return (text, report)
            }
            verdicts = found
        } catch Failure.timedOut {
            report.outcome = .notFound
            report.timedOut = true
            return (text, report)
        } catch {
            report.outcome = (error as? Failure) == .denied ? .unreadable : .failed
            if report.outcome == .unreadable { report.unreadable = "denied" }
            return (text, report)
        }
        let voices = messages.indices.filter { messages[$0].seconds != nil }
        for (ordinal, index) in voices.enumerated() {
            switch verdicts[index] {
            case .transcript(let transcript): report.transcripts[ordinal] = transcript; report.summary.attached += 1
            case .notConverted: report.summary.notConverted += 1
            case .ambiguous, nil: report.summary.ambiguous += 1
            }
        }
        guard !report.transcripts.isEmpty else {
            report.outcome = .unmatched
            return (text, report)
        }
        report.outcome = .merged
        return (WeChatVoiceTranscripts.insert(report.transcripts, into: text, at: lines), report)
    }

    /// The receipt at `directory`, from any entry, its TXT rewritten in place
    /// when `merge` attached anything — exactly as `WeChatVoiceMatch` rewrites
    /// one — and untouched otherwise.
    public static func merge(intoReceiptAt directory: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser,
                             deadline: Date = .distantFuture) -> Report {
        let started = Date()
        var report = Report(outcome: .noVoice)
        do {
            report = try WeChatVoiceTranscripts.rewriteTranscript(
                ofReceiptAt: directory, accepting: Set(ShareAction.allCases), checkCancellation: {},
                withoutTranscript: Report(outcome: .noVoice)
            ) { original in
                let (text, report) = merge(original, home: home, deadline: deadline)
                return (report.outcome == .merged ? text : nil, report)
            }
        } catch {
            // The receipt could not be read, or the new ZIP not written: the
            // export is as WeChat wrote it.
            report = Report(outcome: .failed)
        }
        report.milliseconds = Int(Date().timeIntervalSince(started) * 1000)
        return report
    }

    // MARK: - Status

    public enum Status: Equatable, Sendable {
        case ready
        case noKeyFile
        case keyMismatch
        /// macOS did not let Dukou read WeChat's folder.
        case denied
        /// WeChat's folder or files are missing or cannot be read.
        case unreadable
    }

    /// Finds the account's files and the key that opens them. The first time
    /// Dukou reads WeChat's folder, macOS asks the user whether it may; this
    /// waits for the answer.
    public static func check(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Status {
        do {
            _ = try Account.find(home: home)
            return .ready
        } catch {
            switch error {
            case .noKeyFile: return .noKeyFile
            case .keyMismatch: return .keyMismatch
            case .denied: return .denied
            case .unreadable, .timedOut: return .unreadable
            }
        }
    }

    enum Failure: Error, Equatable {
        case noKeyFile, keyMismatch, denied, unreadable, timedOut
    }

    // MARK: - The account

    /// The files of the account a saved key opens, newest first, and that key.
    struct Account {
        let files: [URL]
        let rawKey: [UInt8]

        static func folder(home: URL) -> URL {
            home.appendingPathComponent("Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files", isDirectory: true)
        }

        static func keyFile(home: URL) -> URL {
            home.appendingPathComponent(".chatlog/chatlog.json")
        }

        /// The account whose files changed last, among those a saved key
        /// opens: the one signed in, which is the one a forward comes from.
        static func find(home: URL) throws(Failure) -> Account {
            let keys = try savedKeys(home: home)
            let root = folder(home: home)
            let names: [String]
            do {
                names = try FileManager.default.contentsOfDirectory(atPath: root.path)
            } catch {
                throw failure(error)
            }
            var accounts: [(files: [URL], newest: Date)] = []
            for name in names where !name.hasPrefix(".") {
                let files = messageFiles(in: root.appendingPathComponent(name).appendingPathComponent("db_storage/message"))
                if let first = files.first { accounts.append((files.map(\.url), first.modified)) }
            }
            guard !accounts.isEmpty else { throw .unreadable }
            for account in accounts.sorted(by: { $0.newest > $1.newest }) {
                let page = try firstPage(of: account.files[0])
                guard let salt = WeChatDatabaseCipher.salt(ofFirstPage: page) else { continue }
                for key in keys {
                    let derived = KeyCache.shared.keys(rawKey: key, salt: salt)
                    if page.withUnsafeBytes({ WeChatDatabaseCipher.authenticates($0, number: 1, keys: derived) }) {
                        return Account(files: account.files, rawKey: key)
                    }
                }
            }
            throw .keyMismatch
        }

        /// Every 64-hex-digit `data_key` in chatlog's history. Several are
        /// normal — one per account and WeChat version chatlog has seen — and
        /// only the page-1 HMAC says which is current.
        static func savedKeys(home: URL) throws(Failure) -> [[UInt8]] {
            guard let data = try? Data(contentsOf: keyFile(home: home)),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let history = object["history"] as? [[String: Any]] else { throw .noKeyFile }
            var keys: [[UInt8]] = []
            for entry in history {
                guard let hex = entry["data_key"] as? String, let key = bytes(hex: hex), key.count == 32, !keys.contains(key) else { continue }
                keys.append(key)
            }
            guard !keys.isEmpty else { throw .noKeyFile }
            return keys
        }

        static func bytes(hex: String) -> [UInt8]? {
            let digits = Array(hex.utf8)
            guard digits.count % 2 == 0 else { return nil }
            var bytes: [UInt8] = []
            bytes.reserveCapacity(digits.count / 2)
            for index in stride(from: 0, to: digits.count, by: 2) {
                guard let high = nibble(digits[index]), let low = nibble(digits[index + 1]) else { return nil }
                bytes.append(high << 4 | low)
            }
            return bytes
        }

        private static func nibble(_ digit: UInt8) -> UInt8? {
            switch digit {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): digit - UInt8(ascii: "0")
            case UInt8(ascii: "a")...UInt8(ascii: "f"): digit - UInt8(ascii: "a") + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"): digit - UInt8(ascii: "A") + 10
            default: nil
            }
        }

        /// `message_<N>.db`, most recently written first — the file itself or
        /// its WAL, whichever changed last: new messages sit in the WAL until
        /// WeChat checkpoints it.
        static func messageFiles(in folder: URL) -> [(url: URL, modified: Date)] {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [] }
            var files: [(url: URL, modified: Date)] = []
            for name in names {
                guard name.hasPrefix("message_"), name.hasSuffix(".db"),
                      name.dropFirst(8).dropLast(3).allSatisfy(\.isASCII), Int(name.dropFirst(8).dropLast(3)) != nil else { continue }
                let url = folder.appendingPathComponent(name)
                guard let modified = modification(of: url.path) else { continue }
                files.append((url, max(modified, modification(of: url.path + "-wal") ?? modified)))
            }
            return files.sorted { $0.modified > $1.modified }
        }

        static func modification(of path: String) -> Date? {
            var info = stat()
            guard stat(path, &info) == 0 else { return nil }
            return Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1e9)
        }

        static func firstPage(of url: URL) throws(Failure) -> [UInt8] {
            let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC)
            guard descriptor >= 0 else { throw errno == EPERM || errno == EACCES ? .denied : .unreadable }
            defer { Darwin.close(descriptor) }
            var page = [UInt8](repeating: 0, count: WeChatDatabaseCipher.pageSize)
            guard pread(descriptor, &page, page.count, 0) == page.count else { throw .unreadable }
            return page
        }

        static func failure(_ error: Error) -> Failure {
            let underlying = (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError
            let code = underlying?.domain == NSPOSIXErrorDomain ? underlying?.code : nil
            if code == Int(EPERM) || code == Int(EACCES) || (error as NSError).code == NSFileReadNoPermissionError { return .denied }
            return .unreadable
        }
    }

    /// Derived page keys, per raw key and file salt, for as long as the app
    /// runs: 256 000 rounds of PBKDF2 are most of what a merge would
    /// otherwise spend. Memory only.
    final class KeyCache: @unchecked Sendable {
        static let shared = KeyCache()
        private let lock = NSLock()
        private var derived: [[UInt8]: WeChatDatabaseCipher.Keys] = [:]

        func keys(rawKey: [UInt8], salt: [UInt8]) -> WeChatDatabaseCipher.Keys {
            let index = rawKey + salt
            lock.lock()
            if let hit = derived[index] { lock.unlock(); return hit }
            lock.unlock()
            let keys = WeChatDatabaseCipher.Keys(rawKey: rawKey, salt: salt)
            lock.lock()
            if derived.count >= 64 { derived.removeAll() }
            derived[index] = keys
            lock.unlock()
            return keys
        }
    }

    // MARK: - Searching

    /// Files newest first, up to the first where some conversation embeds the
    /// export; see `WeChatDatabaseMatch`. Nil when none does.
    static func search(_ messages: [WeChatVoiceMatch.Message], minutes: [Int64]?, in account: Account,
                       deadline: Date = .distantFuture, report: inout Report) throws -> [Int: WeChatDatabaseMatch.Verdict]? {
        let voices = messages.compactMap(\.seconds).count
        let texts = messages.contains { if case .text = $0 { true } else { false } }
        for file in account.files {
            guard Date() < deadline else { throw Failure.timedOut }
            report.files += 1
            let (tables, count) = try readStable(file, rawKey: account.rawKey, voices: voices, texts: texts, deadline: deadline)
            report.tables += count
            if let verdicts = WeChatDatabaseMatch.verdicts(messages, minutes: minutes, in: tables) { return verdicts }
        }
        return nil
    }

    /// The candidate conversations of one file, read twice at most: when
    /// WeChat checkpoints its WAL into the file, or restarts the WAL, while
    /// the file is being read, what was read may mix two moments.
    static func readStable(_ file: URL, rawKey: [UInt8], voices: Int, texts: Bool,
                           deadline: Date = .distantFuture) throws -> (tables: [[WeChatDatabaseRow]], count: Int) {
        for _ in 0..<2 {
            let before = Snapshot(file)
            let database = try Connection(file: file, rawKey: rawKey)
            let names = try database.candidateTables(voices: voices)
            let tables = try names.map { name in
                guard Date() < deadline else { throw Failure.timedOut }
                return try database.rows(of: name, texts: texts)
            }
            if Snapshot(file) == before { return (tables, names.count) }
        }
        throw Failure.unreadable
    }

    /// What changes when WeChat writes the file itself or starts its WAL over.
    struct Snapshot: Equatable {
        let modified: Date?
        let size: Int64?
        let walHeader: [UInt8]

        init(_ file: URL) {
            var info = stat()
            let found = stat(file.path, &info) == 0
            modified = found ? Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1e9) : nil
            size = found ? info.st_size : nil
            var header = [UInt8](repeating: 0, count: WeChatDatabaseWAL.headerSize)
            let descriptor = Darwin.open(file.path + "-wal", O_RDONLY | O_CLOEXEC)
            if descriptor >= 0 {
                header = pread(descriptor, &header, header.count, 0) == header.count ? header : []
                Darwin.close(descriptor)
            } else {
                header = []
            }
            walHeader = header
        }
    }

    // MARK: - SQLite

    /// One file opened through `PageSource`, read only.
    final class Connection {
        private let handle: OpaquePointer
        private let token: String

        init(file: URL, rawKey: [UInt8]) throws {
            let source = try PageSource(file: file, rawKey: rawKey)
            token = "dukou-wechat-" + UUID().uuidString
            PageSource.register(source, as: token)
            var handle: OpaquePointer?
            let status = sqlite3_open_v2(token, &handle, SQLITE_OPEN_READONLY, PageSource.vfsName)
            guard status == SQLITE_OK, let handle else {
                sqlite3_close_v2(handle)
                PageSource.unregister(token)
                throw Failure.unreadable
            }
            self.handle = handle
            // Temporary tables in memory, so the VFS is never asked for a file
            // of its own; a cache large enough that pages are decrypted once.
            for pragma in ["PRAGMA query_only = 1", "PRAGMA temp_store = MEMORY", "PRAGMA cache_size = -16384"] {
                sqlite3_exec(handle, pragma, nil, nil, nil)
            }
        }

        deinit {
            sqlite3_close_v2(handle)
            PageSource.unregister(token)
        }

        /// The conversations with at least `voices` voice messages, most
        /// recently active first, at most `tableLimit` of them. The counts and
        /// the latest `sort_seq` come from the indexes alone.
        func candidateTables(voices: Int) throws -> [String] {
            var names: [String] = []
            try query("SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE 'Msg\\_%' ESCAPE '\\'") { row in
                if let name = row.text(0), Self.isMessageTable(name) { names.append(name) }
            }
            var active: [(name: String, latest: Int64)] = []
            for name in names {
                try query("""
                    SELECT (SELECT count(*) FROM (SELECT 1 FROM "\(name)" WHERE local_type = 34 LIMIT \(voices))),
                           (SELECT max(sort_seq) FROM "\(name)")
                    """) { row in
                    if row.int(0) >= Int64(voices) { active.append((name, row.int(1))) }
                }
            }
            return active.sorted { $0.latest > $1.latest }.prefix(WeChatDatabase.tableLimit).map(\.name)
        }

        static func isMessageTable(_ name: String) -> Bool {
            let digest = name.dropFirst(4)
            return name.hasPrefix("Msg_") && digest.count == 32 && digest.allSatisfy { $0.isHexDigit && !$0.isUppercase }
        }

        /// The table's latest rows, oldest first. Content is read only for
        /// the kinds compared on it — voice always, texts and app messages
        /// only when the export has text — so an image's XML is never even
        /// paged in.
        func rows(of table: String, texts: Bool) throws -> [WeChatDatabaseRow] {
            let compared = texts ? "IN (1, 34, 49)" : "= 34"
            var rows: [WeChatDatabaseRow] = []
            let decoder = Zstd()
            try query("""
                SELECT local_type,
                       CASE WHEN (local_type & 4294967295) \(compared) THEN message_content END,
                       CASE WHEN local_type = 34 THEN packed_info_data END,
                       create_time
                FROM "\(table)" ORDER BY sort_seq DESC LIMIT \(WeChatDatabase.rowLimit)
                """) { row in
                rows.append(WeChatDatabaseRow(localType: row.int(0), content: row.data(1), packed: row.data(2), time: row.int(3), decoder: decoder))
            }
            return rows.reversed()
        }

        struct Row {
            let statement: OpaquePointer
            func int(_ column: Int32) -> Int64 { sqlite3_column_int64(statement, column) }
            func text(_ column: Int32) -> String? { sqlite3_column_text(statement, column).map { String(cString: $0) } }
            func data(_ column: Int32) -> Data? {
                guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
                let count = Int(sqlite3_column_bytes(statement, column))
                guard count > 0, let bytes = sqlite3_column_blob(statement, column) else { return Data() }
                return Data(bytes: bytes, count: count)
            }
        }

        func query(_ sql: String, _ each: (Row) throws -> Void) throws {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                sqlite3_finalize(statement)
                throw Failure.unreadable
            }
            defer { sqlite3_finalize(statement) }
            while true {
                switch sqlite3_step(statement) {
                case SQLITE_ROW: try each(Row(statement: statement))
                case SQLITE_DONE: return
                default: throw Failure.unreadable
                }
            }
        }
    }
}
