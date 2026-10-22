import XCTest
@testable import ClaudeUsageBar

final class CodexLogServiceTests: XCTestCase {
    func testResponseRecordsTakePrecedenceOverTokenCountEvents() {
        let jsonl = """
        {"timestamp":"2026-10-22T10:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"output_tokens":20},"last_token_usage":{"input_tokens":100,"output_tokens":20}}}}
        {"timestamp":"2026-10-22T10:00:01.000Z","type":"token_usage_record","payload":{"thread_id":"t","response_id":"r","usage":{"input_tokens":100,"cached_input_tokens":40,"output_tokens":20,"reasoning_output_tokens":5}}}
        """
        let records = CodexLogReader.parse(Data(jsonl.utf8))
        let stats = CodexLogReader.aggregate(records)
        XCTAssertEqual(stats.responseCount, 1)
        XCTAssertEqual(stats.allTime.total, 120)
        XCTAssertEqual(stats.allTime.cachedInput, 40)
        XCTAssertEqual(stats.allTime.reasoningOutput, 5)
    }

    func testDuplicateResponseAcrossFilesCountsOnce() {
        let jsonl = """
        {"timestamp":"2026-10-22T10:00:01.000Z","type":"token_usage_record","payload":{"thread_id":"t","response_id":"r","usage":{"input_tokens":100,"output_tokens":20}}}
        """
        let records = CodexLogReader.parse(Data(jsonl.utf8))
        let stats = CodexLogReader.aggregate(records + records)
        XCTAssertEqual(stats.responseCount, 1)
        XCTAssertEqual(stats.allTime.total, 120)
    }

    func testLegacyTokenEventsUseLastUsageOnlyWhenCumulativeChanges() {
        let jsonl = """
        {"timestamp":"2026-10-22T10:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"output_tokens":20},"last_token_usage":{"input_tokens":100,"output_tokens":20}}}}
        {"timestamp":"2026-10-22T10:00:01.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"output_tokens":20},"last_token_usage":{"input_tokens":100,"output_tokens":20}}}}
        {"timestamp":"2026-10-22T10:01:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":150,"output_tokens":30},"last_token_usage":{"input_tokens":50,"output_tokens":10}}}}
        """
        let stats = CodexLogReader.aggregate(CodexLogReader.parse(Data(jsonl.utf8)))
        XCTAssertEqual(stats.responseCount, 2)
        XCTAssertEqual(stats.allTime.total, 180)
    }
}
