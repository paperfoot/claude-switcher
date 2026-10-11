import Foundation
import Testing
@testable import ClaudeSwitcherCore

/// Every test talks to a fake transport and a fake key store: no network, no Keychain.
private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [URLRequest] = []
    var requests: [URLRequest] { lock.withLock { stored } }
    func record(_ request: URLRequest) { lock.withLock { stored.append(request) } }
}

private func respond(status: Int = 200, json: String, recorder: Recorder? = nil) -> JevRouter.Transport {
    { request in
        recorder?.record(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        return (Data(json.utf8), response)
    }
}

private func answer(_ probabilities: [String: Double]) -> String {
    let body = try! JSONSerialization.data(withJSONObject: probabilities, options: [.sortedKeys])
    let top = probabilities.max { $0.value < $1.value }?.key ?? ""
    return #"{"model":"jev-1.13.0","answers":{"action":{"type":"choice","choice":"\#(top)","confidence":0.9,"probabilities":\#(String(decoding: body, as: UTF8.self))}},"usage":{"input_tokens":600,"output_tokens":90}}"#
}

private let context = PaletteContext(
    accounts: [
        PaletteAccount(product: .claude, id: "profile-7f3a", email: "work@example.com", isSelected: true, fiveHourUsed: 96, weekUsed: 40),
        PaletteAccount(product: .claude, id: "profile-91bc", email: "personal@example.com", fiveHourUsed: 10, weekUsed: 12),
        PaletteAccount(product: .claude, id: "profile-0d2e", email: "lab-alpha@example.net", needsSignIn: true),
        PaletteAccount(product: .codex, id: "team199@example.org", email: "team199@example.org", fiveHourUsed: 20, weekUsed: 30),
    ],
    desktopProfiles: [PaletteDesktopProfile(id: "profile-7f3a", label: "Work")],
    toggles: [.launchAtLogin: true, .autoSwitch: false],
    coordinated: true, jevAvailable: true)

private func body(of request: URLRequest) throws -> [String: Any] {
    let data = try #require(request.httpBody)
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

struct JevRouterRequestTests {
    @Test func asksOneChoiceQuestionOverTheTitles() async throws {
        let recorder = Recorder()
        let candidates = PaletteEngine.allCandidates(context: context)
        let router = JevRouter(apiKey: "test-key", transport: respond(json: answer(["None of these": 1]), recorder: recorder))
        _ = try await router.interpret("move me to my personal one", candidates: candidates, context: context)

        let request = try #require(recorder.requests.first)
        #expect(recorder.requests.count == 1)
        #expect(request.url == JevRouter.endpoint)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.httpShouldHandleCookies == false)

        let json = try body(of: request)
        #expect(json["model"] as? String == "jev-latest")
        let questions = try #require(json["questions"] as? [String: Any])
        #expect(questions.count == 1)
        let action = try #require(questions["action"] as? [String: Any])
        #expect(action["type"] as? String == "choice")
        let criteria = try #require(action["criteria"] as? [String: Any])
        #expect(Set(criteria.keys) == Set(candidates.map(\.title) + ["None of these"]))
        #expect((criteria["Turn off Open at login"] as? String)?.contains("turns it off") == true)
    }

    @Test func optionsKeepTheCandidatesOrderWithNoneLast() async throws {
        let recorder = Recorder()
        let candidates = Array(PaletteEngine.allCandidates(context: context).prefix(4))
        let router = JevRouter(apiKey: "k", transport: respond(json: answer([:]), recorder: recorder))
        _ = try await router.interpret("anything", candidates: candidates, context: context)
        let text = String(decoding: try #require(recorder.requests.first?.httpBody), as: UTF8.self)
        let positions = (candidates.map(\.title) + ["None of these"]).map { title in
            text.range(of: "\"\(title)\":")?.lowerBound
        }
        #expect(positions.allSatisfy { $0 != nil })
        #expect(positions.compactMap { $0 } == positions.compactMap { $0 }.sorted())
    }

    @Test func stateHoldsTheRequestAndAccountsOnly() async throws {
        let recorder = Recorder()
        let router = JevRouter(apiKey: "k", transport: respond(json: answer([:]), recorder: recorder))
        _ = try await router.interpret("  use the freest one  ", candidates: PaletteEngine.allCandidates(context: context),
                                       context: context)
        let request = try #require(recorder.requests.first)
        let state = try #require(try body(of: request)["state"] as? [String: Any])
        #expect(Set(state.keys) == ["request", "accounts"])
        #expect(state["request"] as? String == "use the freest one")
        let accounts = try #require(state["accounts"] as? [[String: Any]])
        #expect(accounts.count == 4)
        let work = try #require(accounts.first)
        #expect(work["email"] as? String == "work@example.com")
        #expect(work["product"] as? String == "Claude")
        #expect(work["selected"] as? Bool == true)
        #expect(work["needs_sign_in"] as? Bool == false)
        #expect(work["five_hour_used"] as? String == "96%")
        #expect(work["week_used"] as? String == "40%")
        #expect(work["headroom"] as? String == "little")
        let personal = try #require(accounts.first { $0["email"] as? String == "personal@example.com" })
        #expect(personal["most_headroom"] as? Bool == true)
        #expect(personal["headroom"] as? String == "plenty")
        let lab = try #require(accounts.first { $0["email"] as? String == "lab-alpha@example.net" })
        #expect(lab["five_hour_used"] as? String == "unknown")
        #expect(lab["headroom"] as? String == "unknown")
        #expect(lab["needs_sign_in"] as? Bool == true)
        let codex = try #require(accounts.first { $0["product"] as? String == "Codex" })
        #expect(codex["most_headroom"] as? Bool == true)
    }

    @Test func sendsNoProfileIdsOrKeysInTheBody() async throws {
        let recorder = Recorder()
        let router = JevRouter(apiKey: "secret-test-key", transport: respond(json: answer([:]), recorder: recorder))
        _ = try await router.interpret("switch", candidates: PaletteEngine.allCandidates(context: context), context: context)
        let text = String(decoding: try #require(recorder.requests.first?.httpBody), as: UTF8.self)
        for id in ["profile-7f3a", "profile-91bc", "profile-0d2e", "secret-test-key"] {
            #expect(!text.contains(id), "\(id)")
        }
    }

    @Test func repeatedTitlesGetDistinctOptions() {
        let one = PaletteSuggestion(id: "a", action: .openDesktop(profileID: "a"), title: "Open Claude Desktop: Work", symbol: "macwindow", score: 0)
        let two = PaletteSuggestion(id: "b", action: .openDesktop(profileID: "b"), title: "Open Claude Desktop: Work", symbol: "macwindow", score: 0)
        let jev = PaletteSuggestion(id: "askJev", action: .askJev("x"), title: "Ask Jev", symbol: "sparkles", score: 0)
        let options = JevRouter.options(for: [one, jev, two])
        #expect(options.map(\.key) == ["Open Claude Desktop: Work", "Open Claude Desktop: Work (2)"])
        #expect(options.map(\.suggestion.id) == ["a", "b"])
    }

    @Test func optionsStopAtTheChoiceLimit() {
        let many = (0..<400).map {
            PaletteSuggestion(id: "\($0)", action: .openDesktop(profileID: "\($0)"), title: "Open \($0)", symbol: "macwindow", score: 0)
        }
        #expect(JevRouter.options(for: many).count == 254)
    }

    @Test func headroomBucketsAreWordsNotNumbers() {
        func bucket(_ five: Int?, _ week: Int?) -> String {
            JevRouter.headroom(PaletteAccount(product: .claude, id: "x", email: "x@example.com", fiveHourUsed: five, weekUsed: week))
        }
        #expect(bucket(10, 20) == "plenty")
        #expect(bucket(55, 20) == "some")
        #expect(bucket(10, 85) == "little")
        #expect(bucket(98, 10) == "none")
        #expect(bucket(nil, nil) == "unknown")
    }
}

struct JevRouterResponseTests {
    @Test func returnsUpToThreeLikelyCandidatesScoredByProbability() async throws {
        let candidates = PaletteEngine.allCandidates(context: context)
        let probabilities = [
            "Switch to personal@example.com": 0.62, "Turn on Auto-switch at limit": 0.2,
            "Switch to lab-alpha@example.net": 0.1, "Switch Codex to team199@example.org": 0.05,
            "Diagnostics\u{2026}": 0.01, "None of these": 0.02,
        ]
        let router = JevRouter(apiKey: "k", transport: respond(json: answer(probabilities)))
        let result = try await router.interpret("free me up", candidates: candidates, context: context)
        #expect(result.map(\.action) == [.switchClaude(profileID: "profile-91bc"), .toggle(.autoSwitch),
                                         .switchClaude(profileID: "profile-0d2e")])
        #expect(result.map(\.score) == [0.62, 0.2, 0.1])
        #expect(result.first?.title == "Switch to personal@example.com")
    }

    @Test func unlikelyAndNoneAnswersAreDropped() async throws {
        let candidates = PaletteEngine.allCandidates(context: context)
        let router = JevRouter(apiKey: "k", transport: respond(json: answer([
            "None of these": 0.96, "Quit Claude Switcher": 0.04,
        ])))
        #expect(try await router.interpret("what is the weather", candidates: candidates, context: context).isEmpty)
    }

    @Test func refusedKeysAndServerErrorsThrow() async {
        let router = JevRouter(apiKey: "bad", transport: respond(status: 401, json: #"{"detail":"invalid key"}"#))
        await #expect(throws: JevError.rejected(status: 401)) {
            try await router.interpret("x", candidates: PaletteEngine.allCandidates(context: context), context: context)
        }
        #expect(JevError.rejected(status: 401).errorDescription == "TypeSafe refused the API key")
        #expect(JevError.rejected(status: 529).errorDescription == "TypeSafe is busy \u{00B7} try again")
    }

    @Test func anUnexpectedBodyThrows() async {
        let router = JevRouter(apiKey: "k", transport: respond(json: #"{"answers":{}}"#))
        await #expect(throws: JevError.unreadable) {
            try await router.interpret("x", candidates: PaletteEngine.allCandidates(context: context), context: context)
        }
    }

    @Test func aSlowAnswerTimesOut() async {
        let router = JevRouter(apiKey: "k", timeout: .milliseconds(50)) { request in
            try await Task.sleep(for: .seconds(5))
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let started = ContinuousClock.now
        await #expect(throws: JevError.timedOut) {
            try await router.interpret("x", candidates: PaletteEngine.allCandidates(context: context), context: context)
        }
        #expect(ContinuousClock.now - started < .seconds(2))
    }

    @Test func noCandidatesMeansNoRequest() async throws {
        let recorder = Recorder()
        let router = JevRouter(apiKey: "k", transport: respond(json: answer([:]), recorder: recorder))
        #expect(try await router.interpret("x", candidates: [], context: context).isEmpty)
        #expect(recorder.requests.isEmpty)
    }
}

/// An in-memory stand-in for the Keychain.
private final class MemoryKeyStorage: JevKeyStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]
    var failReads = false

    func read(service: String, account: String) throws -> Data? {
        try lock.withLock {
            if failReads { throw JevKeyStoreError.keychain(-25293) }
            return items["\(service)/\(account)"]
        }
    }

    func write(_ data: Data, service: String, account: String) throws {
        lock.withLock { items["\(service)/\(account)"] = data }
    }

    func delete(service: String, account: String) throws {
        lock.withLock { _ = items.removeValue(forKey: "\(service)/\(account)") }
    }

    var keys: [String] { lock.withLock { Array(items.keys) } }
}

struct JevKeyStoreTests {
    @Test func savesLoadsAndRemovesUnderTheAppsItem() throws {
        let storage = MemoryKeyStorage()
        #expect(JevKeyStore.load(from: storage) == nil)
        try JevKeyStore.save("  ts-test-123\n", to: storage)
        #expect(storage.keys == ["Claude Switcher TypeSafe/api-key"])
        #expect(JevKeyStore.load(from: storage) == "ts-test-123")
        try JevKeyStore.remove(from: storage)
        #expect(JevKeyStore.load(from: storage) == nil)
    }

    @Test func anEmptyKeyIsRefused() {
        let storage = MemoryKeyStorage()
        #expect(throws: JevKeyStoreError.empty) { try JevKeyStore.save("   ", to: storage) }
        #expect(storage.keys.isEmpty)
    }

    @Test func anUnreadableKeychainReadsAsNoKey() throws {
        let storage = MemoryKeyStorage()
        try JevKeyStore.save("ts-test-123", to: storage)
        storage.failReads = true
        #expect(JevKeyStore.load(from: storage) == nil)
    }
}
