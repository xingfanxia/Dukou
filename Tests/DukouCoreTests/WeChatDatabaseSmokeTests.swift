import Darwin
import Foundation
import XCTest
@testable import DukouCore
@testable import DukouWeChatDatabase

/// The whole database merge against this Mac's real WeChat database and a
/// real export, run only when `DUKOU_VOICE_DB_ZIP` names the export's ZIP.
/// The ZIP is read, never written; the merge happens in memory. What it
/// prints is counts, times and transcript lengths — never a transcript, a
/// name or a key, since the data is someone's private chats.
final class WeChatDatabaseSmokeTests: XCTestCase {
    func testRealDatabaseAndExport() throws {
        guard let path = ProcessInfo.processInfo.environment["DUKOU_VOICE_DB_ZIP"], !path.isEmpty else {
            throw XCTSkip("set DUKOU_VOICE_DB_ZIP to an export ZIP to run against the real database")
        }
        let zip = try Data(contentsOf: URL(fileURLWithPath: path))
        let transcript = try XCTUnwrap(try WeChatNativeArchive.transcript(zip), "the ZIP has no TXT")
        let text = try WeChatNativeArchive.contents(of: transcript.path, in: zip)
        let before = Self.peakResidentBytes()
        let (merged, report) = WeChatDatabase.merge(text)
        let after = Self.peakResidentBytes()
        let lengths = report.transcripts.sorted { $0.key < $1.key }.map { $0.value.count }
        print("""
            SMOKE outcome=\(report.outcome.rawValue) unreadable=\(report.unreadable ?? "-") \
            inExport=\(report.summary.voiceLines) merged=\(report.summary.attached) \
            notConverted=\(report.summary.notConverted) ambiguous=\(report.summary.ambiguous) \
            files=\(report.files) tables=\(report.tables) ms=\(report.milliseconds) \
            transcriptLengths=\(lengths) peakRSS=\(before >> 20)MB→\(after >> 20)MB
            """)
        XCTAssertEqual(merged == text, report.outcome != .merged)
        XCTAssertEqual(try WeChatNativeArchive.transcript(Data(contentsOf: URL(fileURLWithPath: path)))?.body, transcript.body,
                       "the ZIP must be left as it was")
    }

    private static func peakResidentBytes() -> Int {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return usage.ru_maxrss
    }
}
