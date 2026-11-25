import Darwin
import Foundation
import SQLite3

extension WeChatDatabase {
    /// One of WeChat's database files as SQLite sees it through Dukou's VFS:
    /// plain pages, decrypted when read, from the file or — where the WAL has
    /// a newer committed copy — from the WAL, which is read into memory once.
    ///
    /// SQLite is told the file is immutable, so it takes no lock and looks for
    /// no journal, and page 1 is handed over saying the database is not in WAL
    /// mode, so it never asks for a WAL or WAL index of its own: the overlay
    /// here is the whole of the WAL as far as SQLite knows. Writes fail.
    final class PageSource: @unchecked Sendable {
        let descriptor: Int32
        let keys: WeChatDatabaseCipher.Keys
        let log: Data
        let wal: WeChatDatabaseWAL
        /// As of the last commit in the WAL, else the file's own size.
        let pages: Int

        static let pageSize = WeChatDatabaseCipher.pageSize

        init(file: URL, rawKey: [UInt8]) throws {
            descriptor = Darwin.open(file.path, O_RDONLY | O_CLOEXEC)
            guard descriptor >= 0 else { throw errno == EPERM || errno == EACCES ? Failure.denied : Failure.unreadable }
            var first = [UInt8](repeating: 0, count: Self.pageSize)
            var info = stat()
            guard pread(descriptor, &first, first.count, 0) == first.count, fstat(descriptor, &info) == 0,
                  let salt = WeChatDatabaseCipher.salt(ofFirstPage: first) else {
                Darwin.close(descriptor)
                throw Failure.unreadable
            }
            keys = KeyCache.shared.keys(rawKey: rawKey, salt: salt)
            do {
                log = try Data(contentsOf: URL(fileURLWithPath: file.path + "-wal"))
            } catch CocoaError.fileReadNoSuchFile {
                log = Data()
            } catch {
                Darwin.close(descriptor)
                throw Account.failure(error)
            }
            wal = WeChatDatabaseWAL(log)
            pages = wal.databasePages ?? Int(info.st_size) / Self.pageSize
        }

        deinit { Darwin.close(descriptor) }

        /// Page `number` as SQLite reads it; nil when it does not authenticate.
        func page(_ number: UInt32) -> [UInt8]? {
            var plain: [UInt8]?
            if let offset = wal.pages[number] {
                plain = log.withUnsafeBytes {
                    WeChatDatabaseCipher.decrypt(UnsafeRawBufferPointer(rebasing: $0[offset..<offset + Self.pageSize]), number: number, keys: keys)
                }
            } else {
                var cipher = [UInt8](repeating: 0, count: Self.pageSize)
                guard pread(descriptor, &cipher, cipher.count, off_t(number - 1) * off_t(Self.pageSize)) == cipher.count else { return nil }
                plain = cipher.withUnsafeBytes { WeChatDatabaseCipher.decrypt($0, number: number, keys: keys) }
            }
            // Bytes 18 and 19 say 2 in a WAL database; 1 is rollback mode.
            if number == 1, plain != nil { plain![18] = 1; plain![19] = 1 }
            return plain
        }

        func read(into buffer: UnsafeMutableRawPointer, count: Int, offset: Int64) -> Int32 {
            var copied = 0, position = offset
            while copied < count {
                let number = Int(position / Int64(Self.pageSize)) + 1, within = Int(position % Int64(Self.pageSize))
                guard number <= pages else {
                    memset(buffer + copied, 0, count - copied)
                    return Self.shortRead
                }
                guard let page = page(UInt32(number)) else { return Self.readError }
                let length = min(Self.pageSize - within, count - copied)
                page.withUnsafeBytes { (buffer + copied).copyMemory(from: $0.baseAddress! + within, byteCount: length) }
                copied += length
                position += Int64(length)
            }
            return SQLITE_OK
        }

        // MARK: - The VFS

        static let vfsName = "dukou-wechat"
        /// `SQLITE_IOERR_READ`, `SQLITE_IOERR_SHORT_READ` and
        /// `SQLITE_IOCAP_IMMUTABLE`, which Swift does not import.
        static let readError: Int32 = 10 | 1 << 8
        static let shortRead: Int32 = 10 | 2 << 8
        static let immutable: Int32 = 0x2000

        private static let lock = NSLock()
        nonisolated(unsafe) private static var sources: [String: PageSource] = [:]

        /// Makes `source` the file SQLite opens under the name `token`.
        static func register(_ source: PageSource, as token: String) {
            _ = vfs
            lock.lock()
            sources[token] = source
            lock.unlock()
        }

        static func unregister(_ token: String) {
            lock.lock()
            sources[token] = nil
            lock.unlock()
        }

        private static func registered(_ token: String) -> PageSource? {
            lock.lock()
            defer { lock.unlock() }
            return sources[token]
        }

        /// Where a file's `PageSource` is kept: right after the
        /// `sqlite3_file` SQLite allocated `szOsFile` bytes for.
        private static func slot(_ file: UnsafeMutablePointer<sqlite3_file>) -> UnsafeMutablePointer<UnsafeMutableRawPointer?> {
            UnsafeMutableRawPointer(file).advanced(by: MemoryLayout<sqlite3_file>.stride).assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
        }

        private static func source(_ file: UnsafeMutablePointer<sqlite3_file>) -> PageSource {
            Unmanaged<PageSource>.fromOpaque(slot(file).pointee!).takeUnretainedValue()
        }

        nonisolated(unsafe) private static let methods: UnsafeMutablePointer<sqlite3_io_methods> = {
            var methods = sqlite3_io_methods()
            methods.iVersion = 1
            methods.xClose = { file in
                guard let file, let pointer = slot(file).pointee else { return SQLITE_OK }
                Unmanaged<PageSource>.fromOpaque(pointer).release()
                slot(file).pointee = nil
                return SQLITE_OK
            }
            methods.xRead = { file, buffer, amount, offset in
                guard let file, let buffer, amount >= 0 else { return readError }
                return source(file).read(into: buffer, count: Int(amount), offset: offset)
            }
            methods.xWrite = { _, _, _, _ in SQLITE_READONLY }
            methods.xTruncate = { _, _ in SQLITE_READONLY }
            methods.xSync = { _, _ in SQLITE_OK }
            methods.xFileSize = { file, size in
                guard let file else { return readError }
                size?.pointee = Int64(source(file).pages) * Int64(pageSize)
                return SQLITE_OK
            }
            methods.xLock = { _, _ in SQLITE_OK }
            methods.xUnlock = { _, _ in SQLITE_OK }
            methods.xCheckReservedLock = { _, reserved in reserved?.pointee = 0; return SQLITE_OK }
            methods.xFileControl = { _, _, _ in SQLITE_NOTFOUND }
            methods.xSectorSize = { _ in Int32(pageSize) }
            methods.xDeviceCharacteristics = { _ in immutable }
            let pointer = UnsafeMutablePointer<sqlite3_io_methods>.allocate(capacity: 1)
            pointer.initialize(to: methods)
            return pointer
        }()

        /// Registered once, never as the default, and never unregistered.
        nonisolated(unsafe) private static let vfs: UnsafeMutablePointer<sqlite3_vfs> = {
            var vfs = sqlite3_vfs()
            vfs.iVersion = 1
            vfs.szOsFile = Int32(MemoryLayout<sqlite3_file>.stride + MemoryLayout<UnsafeMutableRawPointer>.stride)
            vfs.mxPathname = 512
            vfs.zName = UnsafePointer(strdup(vfsName))
            vfs.xOpen = { _, name, file, flags, outFlags in
                guard let file else { return SQLITE_CANTOPEN }
                file.pointee.pMethods = nil
                // Only the main database: a journal, a WAL or a temporary
                // file would be a file of Dukou's own, and none is needed.
                guard let name, flags & SQLITE_OPEN_MAIN_DB != 0, let source = registered(String(cString: name)) else { return SQLITE_CANTOPEN }
                slot(file).pointee = Unmanaged.passRetained(source).toOpaque()
                file.pointee.pMethods = UnsafePointer(methods)
                outFlags?.pointee = SQLITE_OPEN_READONLY
                return SQLITE_OK
            }
            vfs.xDelete = { _, _, _ in SQLITE_READONLY }
            vfs.xAccess = { _, _, _, exists in exists?.pointee = 0; return SQLITE_OK }
            vfs.xFullPathname = { _, name, size, output in
                guard let name, let output, strlen(name) < Int(size) else { return SQLITE_CANTOPEN }
                strcpy(output, name)
                return SQLITE_OK
            }
            vfs.xRandomness = { _, count, output in
                if let output, count > 0 { arc4random_buf(output, Int(count)) }
                return count
            }
            vfs.xSleep = { _, microseconds in
                usleep(UInt32(max(0, microseconds)))
                return microseconds
            }
            vfs.xCurrentTime = { _, now in
                now?.pointee = Date().timeIntervalSince1970 / 86400 + 2_440_587.5
                return SQLITE_OK
            }
            vfs.xGetLastError = { _, _, _ in 0 }
            let pointer = UnsafeMutablePointer<sqlite3_vfs>.allocate(capacity: 1)
            pointer.initialize(to: vfs)
            sqlite3_vfs_register(pointer, 0)
            return pointer
        }()
    }
}
