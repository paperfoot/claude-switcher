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

    @Test func anOpenedSignInPageTellsTheUserHowToFinish() throws {
        let json = #"{"ok":false,"partial":true,"codeEmail":"a@example.com","error":"code_only_after_web_failure","browserError":"web_login_expired","loginOpened":true,"selectedAt":100.5}"#
        let result = try JSONDecoder().decode(CoordinatedResult.self, from: Data(json.utf8))
        #expect(result.summary == "Code switched · sign in on the claude.ai tab to finish")
        let closed = #"{"ok":false,"partial":true,"codeEmail":"a@example.com","error":"code_only_after_web_failure","browserError":"web_login_expired"}"#
        #expect(try JSONDecoder().decode(CoordinatedResult.self, from: Data(closed.utf8)).summary
                == "Code switched · Chrome login expired, sign in to claude.ai once")
    }

    @Test func aPartialSwitchIsFinishedOnlyBySavedStateForTheSameSelection() throws {
        func decode(_ json: String) throws -> CoordinatedResult { try JSONDecoder().decode(CoordinatedResult.self, from: Data(json.utf8)) }
        let partial = try decode(#"{"ok":false,"partial":true,"codeEmail":"a@example.com","error":"code_only_after_web_failure","selectedAt":100.5}"#)
        #expect(partial.isFinished(by: try decode(#"{"ok":true,"codeEmail":"A@example.com","browserReady":true,"selectedAt":100.5}"#)))
        #expect(!partial.isFinished(by: try decode(#"{"ok":true,"codeEmail":"a@example.com","browserReady":true,"selectedAt":200}"#)))
        #expect(!partial.isFinished(by: try decode(#"{"ok":true,"codeEmail":"b@example.com","browserReady":true,"selectedAt":100.5}"#)))
        #expect(!partial.isFinished(by: partial))
    }

    @Test func aSetupFromBeforeTheInHouseEngineStillLoads() throws {
        let old = #"{"enabled":true,"python":"/p","helper":"/h","cswap":"/old/cswap","claude":"/c"}"#
        #expect(try JSONDecoder().decode(CoordinatedSetup.self, from: Data(old.utf8)).engine == "/old/cswap")
        let new = #"{"enabled":true,"python":"/p","helper":"/h","engine":"/new/engine"}"#
        #expect(try JSONDecoder().decode(CoordinatedSetup.self, from: Data(new.utf8)).engine == "/new/engine")
    }

    @Test func anAutomaticPartialSwitchIsFinishedBySavedStateForItsSelection() throws {
        let auto = try JSONDecoder().decode(AutoSwitchResult.self, from: Data(
            #"{"ok":true,"switched":true,"codeEmail":"a@example.com","browserReady":false,"browserError":"web_unavailable","selectedAt":100.5}"#.utf8))
        let selectedAt = try #require(auto.selectedAt)
        func saved(_ json: String) throws -> CoordinatedResult { try JSONDecoder().decode(CoordinatedResult.self, from: Data(json.utf8)) }
        #expect(try saved(#"{"ok":true,"codeEmail":"a@example.com","browserReady":true,"selectedAt":100.5,"recovered":true}"#)
            .finishes(email: "a@example.com", selectedAt: selectedAt))
        #expect(!(try saved(#"{"ok":false,"partial":true,"codeEmail":"a@example.com","browserReady":false,"selectedAt":100.5}"#)
            .finishes(email: "a@example.com", selectedAt: selectedAt)))
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
        return (CoordinatedSetup(enabled: true, python: "/bin/sh", helper: script.path, engine: "/usr/bin/false"), directory)
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
        #expect(result.summary == "Code switched · Chrome kept the previous account")
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
