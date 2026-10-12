import Foundation
import Testing
@testable import ClaudeSwitcherCore

struct ChromeExtensionLoginTests {
    @Test func labelsMatchIgnoringCaseAndSpace() {
        #expect(ChromeExtensionLogin.control(forLabel: " Log in\n") == .logIn)
        #expect(ChromeExtensionLogin.control(forLabel: "LOG OUT") == .logOut)
        #expect(ChromeExtensionLogin.control(forLabel: "Log in with Google") == nil)
        #expect(ChromeExtensionLogin.control(forLabel: "Login") == nil)
    }
    @Test func onlyOptionsWindowsAreCandidates() {
        #expect(ChromeExtensionLogin.isCandidate(windowTitle: "Claude Options - Google Chrome – Boris"))
        #expect(!ChromeExtensionLogin.isCandidate(windowTitle: "Claude in Chrome - Google Chrome"))
        #expect(!ChromeExtensionLogin.isCandidate(windowTitle: ""))
    }
    @Test func doneOnlyWhenEveryExpectedWindowIsSignedIn() {
        typealias Progress = ChromeExtensionLogin.Progress
        #expect(!Progress().isDone(expectedWindows: 1))
        #expect(Progress(windows: 1, pressed: 1, signedIn: 1).isDone(expectedWindows: 1))
        #expect(Progress(windows: 1, signedIn: 1).isDone(expectedWindows: 0))
        #expect(!Progress(windows: 1, signedIn: 1).isDone(expectedWindows: 2))
        #expect(!Progress(windows: 2, pressed: 2, signedIn: 1).isDone(expectedWindows: 2))
    }
    @Test func resultsNameTheFailure() {
        typealias Progress = ChromeExtensionLogin.Progress
        let none = Progress().result(expectedWindows: 1, timedOut: true)
        #expect(none["ok"] as? Bool == false)
        #expect(none["error"] as? String == "no_window")
        let stuck = Progress(windows: 1, pressed: 1).result(expectedWindows: 1, timedOut: true)
        #expect(stuck["error"] as? String == "timeout")
        #expect(stuck["pressed"] as? Int == 1)
        let done = Progress(windows: 1, pressed: 1, signedIn: 1).result(expectedWindows: 1, timedOut: true)
        #expect(done["ok"] as? Bool == true)
        #expect(done["error"] == nil)
    }
    @Test func extensionOutcomeShapesTheSummary() throws {
        func summary(_ json: String) throws -> String {
            try JSONDecoder().decode(CoordinatedResult.self, from: Data(json.utf8)).summary
        }
        #expect(try summary(#"{"ok":true,"browserReady":true}"#) == "Chrome and Code switched")
        #expect(try summary(#"{"ok":true,"browserReady":true,"extensionReady":true}"#) == "Chrome and Code switched")
        #expect(try summary(#"{"ok":true,"browserReady":true,"extensionReady":false,"extensionError":"timeout"}"#)
                == "Chrome and Code switched · Claude extension needs attention")
        #expect(try summary(#"{"ok":true,"browserReady":true,"extensionReady":false,"extensionError":"accessibility_needed"}"#)
                == "Switched · allow Accessibility so Chrome's Claude extension follows")
        #expect(try summary(#"{"ok":true,"browserReady":false,"extensionReady":false}"#) == "Code switched · Chrome needs setup")
    }
    @Test func autoSwitchDecodesTheExtensionOutcome() throws {
        let data = Data(#"{"ok":true,"switched":true,"codeEmail":"one@example.com","browserReady":true,"extensionReady":false,"extensionError":"accessibility_needed"}"#.utf8)
        let result = try JSONDecoder().decode(AutoSwitchResult.self, from: data)
        #expect(result.extensionReady == false)
        #expect(result.extensionError == "accessibility_needed")
    }
}
