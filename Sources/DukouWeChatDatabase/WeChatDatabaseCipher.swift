import CommonCrypto
import Foundation

/// The pages of WeChat 4's message databases: SQLCipher 4 with its default
/// settings, read here one page at a time and only ever into memory.
///
/// Every file starts with a 16-byte salt. The 32-byte key chatlog saved is a
/// passphrase, not the page key: the page key is PBKDF2-HMAC-SHA512 of it
/// over that salt, 256 000 rounds; the HMAC key is the same function of the
/// page key over the salt with every byte XOR 0x3a, two rounds. Each 4096-byte
/// page keeps back its last 80 bytes — a 16-byte IV, then a 64-byte HMAC-SHA512
/// over the page from its encrypted start up to and including the IV, followed
/// by the page number as a little-endian `UInt32`. Everything before the IV is
/// AES-256-CBC without padding; page 1's encrypted part starts after the salt,
/// whose place `SQLite format 3\0` takes in the plaintext.
///
/// Checked against WeChat 4.2.0 for Mac: one of the keys chatlog keeps
/// authenticates page 1 of the current account's files and the others do not,
/// which is how the right key is told from the stale ones.
public enum WeChatDatabaseCipher {
    public static let pageSize = 4096
    static let saltSize = 16
    static let ivSize = 16
    static let hmacSize = 64
    /// What every page keeps back at its end, in plaintext as well: the
    /// databases say so in byte 20 of their header, so SQLite leaves it alone.
    public static let reserve = ivSize + hmacSize
    static let rounds: UInt32 = 256_000
    static let header = Array("SQLite format 3\0".utf8)

    public struct Keys: Sendable, Equatable {
        let encryption: [UInt8]
        let hmac: [UInt8]

        /// `rawKey` is the 32 bytes chatlog saved; `salt` the file's first 16.
        /// A quarter of a second or so: the rounds are the point of it.
        public init(rawKey: [UInt8], salt: [UInt8]) {
            encryption = Self.pbkdf2(rawKey, salt: salt, rounds: WeChatDatabaseCipher.rounds)
            hmac = Self.pbkdf2(encryption, salt: salt.map { $0 ^ 0x3a }, rounds: 2)
        }

        static func pbkdf2(_ password: [UInt8], salt: [UInt8], rounds: UInt32) -> [UInt8] {
            var derived = [UInt8](repeating: 0, count: 32)
            let status = password.withUnsafeBytes { password in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                     password.baseAddress?.assumingMemoryBound(to: CChar.self), password.count,
                                     salt, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA512), rounds,
                                     &derived, derived.count)
            }
            precondition(status == kCCSuccess, "PBKDF2 cannot fail for these sizes")
            return derived
        }
    }

    /// The salt a file's keys are derived over: its first 16 bytes.
    public static func salt(ofFirstPage page: some Collection<UInt8>) -> [UInt8]? {
        page.count >= saltSize ? Array(page.prefix(saltSize)) : nil
    }

    /// Whether `page`, page `number` of a file, was written with `keys`. A
    /// wrong key, and a page read while WeChat was halfway through writing
    /// it, both fail here.
    public static func authenticates(_ page: UnsafeRawBufferPointer, number: UInt32, keys: Keys) -> Bool {
        guard page.count == pageSize else { return false }
        let start = number == 1 ? saltSize : 0
        let tag = pageSize - hmacSize
        var expected = [UInt8](repeating: 0, count: hmacSize)
        var context = CCHmacContext()
        keys.hmac.withUnsafeBytes { CCHmacInit(&context, CCHmacAlgorithm(kCCHmacAlgSHA512), $0.baseAddress, $0.count) }
        CCHmacUpdate(&context, page.baseAddress! + start, tag - start)
        var little = number.littleEndian
        withUnsafeBytes(of: &little) { CCHmacUpdate(&context, $0.baseAddress, $0.count) }
        CCHmacFinal(&context, &expected)
        var difference: UInt8 = 0
        for index in 0..<hmacSize { difference |= expected[index] ^ page[tag + index] }
        return difference == 0
    }

    /// Page `number` in plaintext, as SQLite reads a plain database: the same
    /// 4096 bytes, its reserve copied through. Nil when it does not
    /// authenticate — nothing is decrypted that the HMAC has not vouched for.
    public static func decrypt(_ page: UnsafeRawBufferPointer, number: UInt32, keys: Keys) -> [UInt8]? {
        guard authenticates(page, number: number, keys: keys) else { return nil }
        let start = number == 1 ? saltSize : 0
        let end = pageSize - reserve
        var plain = [UInt8](repeating: 0, count: pageSize)
        var moved = 0
        let status = plain.withUnsafeMutableBytes { plain in
            keys.encryption.withUnsafeBytes { key in
                CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), 0,
                        key.baseAddress, key.count, page.baseAddress! + end,
                        page.baseAddress! + start, end - start,
                        plain.baseAddress! + start, end - start, &moved)
            }
        }
        guard status == kCCSuccess, moved == end - start else { return nil }
        if number == 1 { plain.replaceSubrange(0..<saltSize, with: header) }
        for index in end..<pageSize { plain[index] = page[index] }
        return plain
    }
}

/// The committed part of a database's write-ahead log, as SQLite itself
/// recovers it when the WAL index is gone: frames are taken in order while
/// their salts match the header and their running checksums hold, and only
/// up to the last commit frame among them. A transaction WeChat is still
/// writing, and frames left over from before the log was last restarted, are
/// not part of it. SQLCipher keeps its pages in the WAL encrypted exactly as
/// in the file, under the frame's page number.
///
/// The WAL index (`-shm`) is never read: what it would say can be recovered
/// from the log, and reading it is one more file shared with a running WeChat.
public struct WeChatDatabaseWAL: Sendable, Equatable {
    /// Page number → offset of that page's newest committed contents in the
    /// log's bytes.
    public let pages: [UInt32: Int]
    /// The database's size in pages as of the last commit; nil when the log
    /// holds no commit.
    public let databasePages: Int?

    static let headerSize = 32
    static let frameHeaderSize = 24

    /// An empty log, or one that is not a WAL of `pageSize` pages, commits
    /// nothing.
    public init(_ log: Data, pageSize: Int = WeChatDatabaseCipher.pageSize) {
        var pages: [UInt32: Int] = [:], databasePages: Int?
        log.withUnsafeBytes { bytes in
            guard bytes.count >= Self.headerSize else { return }
            let magic = Self.bigEndian(bytes, 0)
            guard magic == 0x377F_0682 || magic == 0x377F_0683, Self.bigEndian(bytes, 4) == 3_007_000,
                  Self.bigEndian(bytes, 8) == UInt32(pageSize) else { return }
            let bigEndianSums = magic & 1 == 1
            let salts = (Self.bigEndian(bytes, 16), Self.bigEndian(bytes, 20))
            var sums = Self.checksum(UnsafeRawBufferPointer(rebasing: bytes[0..<24]), bigEndian: bigEndianSums, seed: (0, 0))
            guard sums == (Self.bigEndian(bytes, 24), Self.bigEndian(bytes, 28)) else { return }
            var offset = Self.headerSize, pending: [(UInt32, Int)] = []
            while offset + Self.frameHeaderSize + pageSize <= bytes.count {
                let number = Self.bigEndian(bytes, offset), commit = Self.bigEndian(bytes, offset + 4)
                guard number > 0, (Self.bigEndian(bytes, offset + 8), Self.bigEndian(bytes, offset + 12)) == salts else { break }
                sums = Self.checksum(UnsafeRawBufferPointer(rebasing: bytes[offset..<offset + 8]), bigEndian: bigEndianSums, seed: sums)
                let data = offset + Self.frameHeaderSize
                sums = Self.checksum(UnsafeRawBufferPointer(rebasing: bytes[data..<data + pageSize]), bigEndian: bigEndianSums, seed: sums)
                guard sums == (Self.bigEndian(bytes, offset + 16), Self.bigEndian(bytes, offset + 20)) else { break }
                pending.append((number, data))
                if commit > 0 {
                    for (number, data) in pending { pages[number] = data }
                    pending.removeAll()
                    databasePages = Int(commit)
                }
                offset = data + pageSize
            }
        }
        self.pages = pages
        self.databasePages = databasePages
    }

    static func bigEndian(_ bytes: UnsafeRawBufferPointer, _ offset: Int) -> UInt32 {
        UInt32(bigEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
    }

    /// SQLite's WAL checksum: pairs of 32-bit words, in the byte order the
    /// magic number names.
    static func checksum(_ bytes: UnsafeRawBufferPointer, bigEndian: Bool, seed: (UInt32, UInt32)) -> (UInt32, UInt32) {
        var (first, second) = seed
        var offset = 0
        while offset + 8 <= bytes.count {
            let a = bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
            let b = bytes.loadUnaligned(fromByteOffset: offset + 4, as: UInt32.self)
            first = first &+ (bigEndian ? UInt32(bigEndian: a) : UInt32(littleEndian: a)) &+ second
            second = second &+ (bigEndian ? UInt32(bigEndian: b) : UInt32(littleEndian: b)) &+ first
            offset += 8
        }
        return (first, second)
    }
}
