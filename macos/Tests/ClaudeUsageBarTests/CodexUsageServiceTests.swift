import XCTest
@testable import ClaudeUsageBar

final class CodexUsageServiceTests: XCTestCase {
    func testSelectsCodexBucketAndParsesBothWindows() throws {
        let result: [String: Any] = [
            "rateLimitsByLimitId": [
                "codex_other": ["primary": ["usedPercent": 99]],
                "codex": [
                    "primary": [
                        "usedPercent": 37.5,
                        "windowDurationMins": 300,
                        "resetsAt": 1_800_000_000
                    ],
                    "secondary": [
                        "usedPercent": 62,
                        "windowDurationMins": 10_080,
                        "resetsAt": 1_800_100_000
                    ]
                ]
            ]
        ]

        let limits = try XCTUnwrap(CodexRateLimits.parse(result))
        XCTAssertEqual(limits.primary?.usedPercent, 37.5)
        XCTAssertEqual(limits.primary?.label, "5-Hour Window")
        XCTAssertEqual(limits.primary?.fractionUsed, 0.375)
        XCTAssertEqual(limits.secondary?.label, "7-Day Window")
        XCTAssertEqual(limits.secondary?.resetsAt?.timeIntervalSince1970, 1_800_100_000)
    }

    func testLegacyBucketAndMissingWindows() {
        let result: [String: Any] = [
            "rateLimits": ["primary": ["usedPercent": 125, "windowDurationMins": 15]]
        ]
        XCTAssertEqual(CodexRateLimits.parse(result)?.primary?.fractionUsed, 1)
        XCTAssertNil(CodexRateLimits.parse(["rateLimits": [:]]))
    }
}
