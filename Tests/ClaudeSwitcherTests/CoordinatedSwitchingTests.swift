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

    @Test func savedChromeLoginExpiriesAreDecoded() throws {
        let json = #"{"accounts":[],"codeEmail":null,"browser":{"ok":true,"email":"one@example.com","accounts":["one@example.com"],"expiries":{"one@example.com":1790000000.5}}}"#
        let browser = try JSONDecoder().decode(CoordinatedSnapshot.self, from: Data(json.utf8)).browser
        #expect(browser.loginExpiry(email: "ONE@example.com") == Date(timeIntervalSince1970: 1_790_000_000.5))
        #expect(browser.loginExpiry(email: "two@example.com") == nil)
        let older = #"{"accounts":[],"browser":{"ok":false}}"#
        #expect(try JSONDecoder().decode(CoordinatedSnapshot.self, from: Data(older.utf8)).browser.expiries == nil)
    }

    private func result(_ json: String) throws -> CoordinatedResult {
        try JSONDecoder().decode(CoordinatedResult.self, from: Data(json.utf8))
    }

    @Test func codeSwitchedSeparatesAmberFromRed() throws {
        #expect(try result(#"{"ok":true,"codeEmail":"one@example.com","browserReady":true}"#).codeSwitched)
        let partial = try result(#"{"ok":false,"partial":true,"codeEmail":"one@example.com","error":"code_only_after_web_failure","browserError":"web_switch_failed"}"#)
        #expect(partial.codeSwitched)
        #expect(partial.ok == false)
        #expect(try !result(#"{"ok":false,"partial":true,"error":"code_only_after_web_failure"}"#).codeSwitched)
        #expect(try !result(#"{"ok":false,"error":"code_switch_failed"}"#).codeSwitched)
        #expect(try !result(#"{"ok":false,"error":"keychain_unavailable","message":"Unlock your Keychain"}"#).codeSwitched)
    }

    @Test func errorCodesHaveSpecificSummaries() throws {
        let cases = [
            (#"{"ok":false,"error":"keychain_unavailable","message":"Account could not be saved or opened."}"#, "Keychain is locked · unlock it and try again"),
            (#"{"ok":false,"error":"backend_unavailable","message":"Backend unavailable."}"#, "Switching needs setup · open Settings"),
            (#"{"ok":false,"error":"unknown_account"}"#, "This account is not set up for switching"),
            (#"{"ok":false,"partial":true,"codeEmail":"a@example.com","error":"code_only_after_web_failure","browserError":"browser_timeout"}"#, "Code switched · Chrome took too long"),
            (#"{"ok":false,"partial":true,"codeEmail":"a@example.com","error":"code_only_after_web_failure","browserError":"switch_in_progress"}"#, "Code switched · Chrome is busy"),
            (#"{"ok":false,"error":"Backend unavailable. Open Settings → Set up switching."}"#, "Could not switch accounts · try again"),
        ]
        for (json, summary) in cases {
            #expect(try result(json).summary == summary)
        }
    }

    private func fakeHelper(_ body: String) throws -> (CoordinatedSetup, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("coordinated-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let script = directory.appendingPathComponent("helper.sh")
        try Data(body.utf8).write(to: script)
        return (CoordinatedSetup(enabled: true, python: "/bin/sh", helper: script.path, cswap: "/usr/bin/false"), directory)
    }

    @Test func unreadableOutputThrowsWithABoundedStderrTail() throws {
        let (setup, directory) = try fakeHelper("""
        i=0; while [ $i -lt 300 ]; do printf 'early-line-%04d\\n' $i >&2; i=$((i+1)); done
        echo 'Traceback: final failure line' >&2
        echo 'not json'
        exit 3
        """)
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            _ = try CoordinatedSwitching.select(email: "one@example.com", setup: setup)
            Issue.record("unreadable output must throw")
        } catch let error as CoordinatedHelperError {
            #expect(error.description.contains("exit 3"))
            #expect(error.description.contains("Traceback: final failure line"))
            #expect(!error.description.contains("early-line-0000"))
            #expect(error.stderrTail.utf8.count <= CoordinatedSwitching.stderrTailLimit)
        }
    }

    @Test func validOutputStillDecodesWhileStderrIsKeptAside() throws {
        let (setup, directory) = try fakeHelper("""
        echo 'warning: noisy helper' >&2
        echo '{"ok":false,"partial":true,"codeEmail":"one@example.com","error":"code_only_after_web_failure"}'
        exit 1
        """)
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = try CoordinatedSwitching.select(email: "one@example.com", setup: setup)
        #expect(result.codeSwitched)
        #expect(result.summary == "Code switched · Chrome could not switch")
    }

    @Test func aHungHelperIsStoppedWithItsStderrTail() throws {
        let (setup, directory) = try fakeHelper("""
        echo 'still waiting for cswap' >&2
        sleep 30
        """)
        defer { try? FileManager.default.removeItem(at: directory) }
        let started = Date()
        do {
            _ = try CoordinatedSwitching.run(setup: setup, arguments: ["switch", "one@example.com"], timeout: 0.5)
            Issue.record("a hung helper must time out")
        } catch let error as CoordinatedHelperError {
            #expect(error.description.contains("timed out"))
            #expect(error.stderrTail == "still waiting for cswap")
        }
        #expect(Date().timeIntervalSince(started) < 5)
    }
}
