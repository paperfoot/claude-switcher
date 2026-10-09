import Foundation
import Testing
@testable import ClaudeSwitcherCore

struct CoordinatedSwitchingTests {
    @Test func backendCacheRetainsItsOriginalAge() throws {
        let json = #"{"accounts":[{"email":"one@example.com","active":true,"usageStatus":"ok","usage":{"fiveHour":{"pct":17,"resetsAt":"2026-09-28T12:00:00Z"}},"usageFetchedAt":"2026-09-28T10:00:00Z"}],"codeEmail":"one@example.com","browser":{"ok":false}}"#
        let snapshot = try JSONDecoder().decode(CoordinatedSnapshot.self, from: Data(json.utf8))
        let reading = try #require(snapshot.reading(email: "ONE@example.com"))
        #expect(reading.fiveHour?.percent == 17)
        #expect(ISO8601DateFormatter().string(from: reading.fetchedAt) == "2026-09-28T10:00:00Z")
        #expect(snapshot.reading(email: "another@example.com") == nil)
    }
    @Test func undatedCacheIsNeverPresentedAsFresh() throws {
        let json = #"{"accounts":[{"email":"one@example.com","active":false,"usageStatus":"ok","usage":{"fiveHour":{"pct":17}}}],"browser":{"ok":false}}"#
        let snapshot = try JSONDecoder().decode(CoordinatedSnapshot.self, from: Data(json.utf8))
        #expect(snapshot.reading(email: "one@example.com") == nil)
    }
    @Test func partialSuccessIsExplicit() throws {
        let data = Data(#"{"ok":true,"codeEmail":"one@example.com","browserReady":false}"#.utf8)
        let result = try JSONDecoder().decode(CoordinatedResult.self, from: data)
        #expect(result.summary == "Code switched · Chrome needs setup")
    }
    @Test func browserFailureKeepsTheCodeSelectionVisible() throws {
        let data = Data(#"{"ok":false,"partial":true,"codeEmail":"one@example.com","browserReady":false,"error":"code_only_after_web_failure","browserError":"host_timeout"}"#.utf8)
        let result = try JSONDecoder().decode(CoordinatedResult.self, from: data)
        #expect(result.codeEmail == "one@example.com")
        #expect(result.summary == "Code switched · Chrome is not responding")
    }
}
