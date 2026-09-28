import Foundation
import Testing
@testable import ClaudeSwitcherCore

private final class CodexTestEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ value: String) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }

    func values() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private final class FakeCodexVault: CodexCredentialVault, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Data]

    init(_ storage: [String: Data] = [:]) {
        self.storage = Dictionary(uniqueKeysWithValues: storage.map { ($0.key.lowercased(), $0.value) })
    }

    func load(email: String) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return storage[email.lowercased()]
    }

    func save(_ data: Data, email: String) throws {
        lock.lock()
        storage[email.lowercased()] = data
        lock.unlock()
    }
}

private actor FakeCodexRuntime: CodexAccountVerifying {
    enum Outcome: Sendable {
        case success(rotatedCredential: Data, usage: LiveUsageSnapshot? = nil)
        case failure(CodexSwitchError, rotatedCredential: Data? = nil)
    }

    private let liveHome: URL
    private let events: CodexTestEventLog
    private var outcomes: [Outcome]
    private var blockedInspectionNumbers: Set<Int>
    private var blockedInspections: [Int: CheckedContinuation<Void, Never>] = [:]
    private var inspectionWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var inspectionCount = 0

    init(
        liveHome: URL,
        outcomes: [Outcome] = [],
        blockedInspectionNumbers: Set<Int> = [],
        events: CodexTestEventLog = CodexTestEventLog()
    ) {
        self.liveHome = liveHome.standardizedFileURL
        self.outcomes = outcomes
        self.blockedInspectionNumbers = blockedInspectionNumbers
        self.events = events
    }

    func inspect(home: URL, usage: Bool) async throws -> (CodexCredential, LiveUsageSnapshot?) {
        inspectionCount += 1
        let currentInspection = inspectionCount
        let startingCredential = try CodexCredential(data: Data(contentsOf: home.appendingPathComponent("auth.json")))
        let scope = home.standardizedFileURL == liveHome ? "live" : "preflight"
        events.append("inspect:\(scope):\(startingCredential.email)")
        notifyInspectionWaiters()

        if blockedInspectionNumbers.contains(currentInspection) {
            await withCheckedContinuation { continuation in
                blockedInspections[currentInspection] = continuation
            }
        }

        guard outcomes.isEmpty == false else { throw CodexSwitchError.unavailable }
        let outcome = outcomes.removeFirst()
        let authURL = home.appendingPathComponent("auth.json")
        switch outcome {
        case let .success(rotatedCredential, reading):
            // Codex writes a complete, refreshed auth.json before returning identity data.
            try CodexAccountFiles.writePrivate(rotatedCredential, to: authURL)
            return (try CodexCredential(data: Data(contentsOf: authURL)), reading)
        case let .failure(error, rotatedCredential):
            if let rotatedCredential {
                try CodexAccountFiles.writePrivate(rotatedCredential, to: authURL)
            }
            throw error
        }
    }

    func login(
        home: URL,
        openURL: @escaping @Sendable (URL) async throws -> Void
    ) async throws -> CodexCredential {
        throw CodexSwitchError.signIn
    }

    func waitUntilInspection(_ expectedCount: Int) async {
        if inspectionCount >= expectedCount { return }
        await withCheckedContinuation { continuation in
            inspectionWaiters.append((expectedCount, continuation))
        }
    }

    func resumeInspection(_ number: Int) {
        blockedInspectionNumbers.remove(number)
        blockedInspections.removeValue(forKey: number)?.resume()
    }

    func count() -> Int { inspectionCount }

    private func notifyInspectionWaiters() {
        var pending: [(Int, CheckedContinuation<Void, Never>)] = []
        for waiter in inspectionWaiters {
            if inspectionCount >= waiter.0 {
                waiter.1.resume()
            } else {
                pending.append(waiter)
            }
        }
        inspectionWaiters = pending
    }
}

private actor FakeCodexDesktop: CodexDesktopControlling {
    private let closeResult: Bool
    private let closeError: CodexSwitchError?
    private let openError: CodexSwitchError?
    private let onClose: @Sendable () throws -> Void
    private let events: CodexTestEventLog
    private var closeCount = 0
    private var openCount = 0

    init(
        closeResult: Bool = true,
        closeError: CodexSwitchError? = nil,
        openError: CodexSwitchError? = nil,
        events: CodexTestEventLog = CodexTestEventLog(),
        onClose: @escaping @Sendable () throws -> Void = {}
    ) {
        self.closeResult = closeResult
        self.closeError = closeError
        self.openError = openError
        self.events = events
        self.onClose = onClose
    }

    func close() async throws -> Bool {
        closeCount += 1
        events.append("close")
        if let closeError { throw closeError }
        try onClose()
        return closeResult
    }

    func open() async throws {
        openCount += 1
        events.append("open")
        if let openError { throw openError }
    }

    func counts() -> (close: Int, open: Int) { (closeCount, openCount) }
}

private struct CodexFixture {
    let root: URL
    let files: CodexAccountFiles

    init(activeCredential: Data? = nil) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-switcher-codex-tests-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("codex-home", isDirectory: true)
        let appDirectory = root.appendingPathComponent("switcher-state", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: appDirectory, withIntermediateDirectories: true)
        try CodexAccountFiles.writePrivate(
            Data("cli_auth_credentials_store = \"file\"\n".utf8),
            to: home.appendingPathComponent("config.toml")
        )
        files = CodexAccountFiles(home: home, directory: appDirectory)
        if let activeCredential {
            try CodexAccountFiles.writePrivate(activeCredential, to: files.authURL)
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private func base64URL(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

private func codexCredentialData(email: String, accountID: String, accessToken: String) throws -> Data {
    let header = try JSONSerialization.data(withJSONObject: ["alg": "RS256", "typ": "JWT"], options: [.sortedKeys])
    let payload = try JSONSerialization.data(
        withJSONObject: ["email": email, "sub": "test-user-\(accountID)"],
        options: [.sortedKeys]
    )
    let idToken = "\(base64URL(header)).\(base64URL(payload)).test-signature"
    let officialClientShape: [String: Any] = [
        "auth_mode": "chatgpt",
        "last_refresh": "2026-09-28T12:00:00Z",
        "tokens": [
            "access_token": accessToken,
            "account_id": accountID,
            "id_token": idToken,
            "refresh_token": "refresh-\(accessToken)",
        ],
    ]
    return try JSONSerialization.data(withJSONObject: officialClientShape, options: [.sortedKeys])
}

private func codexJSON(_ source: String) throws -> CodexJSONValue {
    try JSONDecoder().decode(CodexJSONValue.self, from: Data(source.utf8))
}

private func expectCodexError(
    _ expected: CodexSwitchError,
    operation: () async throws -> Void,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    do {
        try await operation()
        Issue.record("Expected \(expected) to be thrown", sourceLocation: sourceLocation)
    } catch let error as CodexSwitchError {
        #expect(String(describing: error) == String(describing: expected), sourceLocation: sourceLocation)
    } catch {
        Issue.record("Expected CodexSwitchError, got \(error)", sourceLocation: sourceLocation)
    }
}

@Suite("Codex accounts")
struct CodexAccountsTests {
    @Test("Credential validation extracts and normalizes the JWT email")
    func credentialValidationAndJWTEmailExtraction() throws {
        let valid = try codexCredentialData(
            email: "Person+Codex@Example.COM",
            accountID: "account-1",
            accessToken: "access-1"
        )
        let credential = try CodexCredential(data: valid)

        #expect(credential.email == "person+codex@example.com")
        #expect(credential.accountID == "account-1")
        #expect(credential.data == valid)

        var apiKeyMode = try #require(JSONSerialization.jsonObject(with: valid) as? [String: Any])
        apiKeyMode["auth_mode"] = "apikey"
        let malformedInputs = [
            try JSONSerialization.data(withJSONObject: apiKeyMode),
            Data("not-json".utf8),
            Data(#"{"tokens":{"access_token":"access","id_token":"not.a.jwt","account_id":"account"}}"#.utf8),
            Data(#"{"tokens":{"access_token":"","id_token":"a.e30.c","account_id":"account"}}"#.utf8),
            Data(#"{"tokens":{"access_token":"access","id_token":"a.e30.c","account_id":""}}"#.utf8),
            Data(repeating: 0x20, count: 1_048_576),
        ]
        for input in malformedInputs {
            do {
                _ = try CodexCredential(data: input)
                Issue.record("Malformed credentials must be rejected")
            } catch let error as CodexSwitchError {
                #expect(String(describing: error) == String(describing: CodexSwitchError.signIn))
            } catch {
                Issue.record("Expected CodexSwitchError, got \(error)")
            }
        }
    }

    @Test("A Gmail display alias resolves to the credential's actual email")
    func gmailAliasUsesCredentialEmail() async throws {
        let actualEmail = "person@googlemail.com"
        let active = try codexCredentialData(email: actualEmail, accountID: "account-a", accessToken: "active-a")
        let fixture = try CodexFixture(activeCredential: active)
        defer { fixture.remove() }
        let vault = FakeCodexVault([actualEmail: active])
        let runtime = FakeCodexRuntime(liveHome: fixture.files.home)
        let service = CodexAccountService(
            emails: ["person@gmail.com"],
            aliases: ["person@gmail.com": actualEmail],
            files: fixture.files,
            vault: vault,
            runtime: runtime
        )

        let accounts = try await service.refresh(usage: false)
        let account = try #require(accounts.first)

        #expect(account.email == "person@gmail.com")
        #expect(account.credentialEmail == actualEmail)
        #expect(account.identityEmail == actualEmail)
        #expect(account.connected)
        #expect(account.active)
        #expect(await runtime.count() == 0)
    }

    @Test("Selecting the already active account does not quit or reopen Codex")
    func selectingActiveAccountIsNoOp() async throws {
        let active = try codexCredentialData(email: "a@example.com", accountID: "account-a", accessToken: "active-a")
        let fixture = try CodexFixture(activeCredential: active)
        defer { fixture.remove() }
        let vault = FakeCodexVault()
        let runtime = FakeCodexRuntime(liveHome: fixture.files.home)
        let desktop = FakeCodexDesktop()
        let service = CodexAccountService(
            emails: ["a@example.com"], files: fixture.files, vault: vault, runtime: runtime
        )

        let accounts = try await service.select(email: "A@EXAMPLE.COM", desktop: desktop)

        #expect(accounts.first?.active == true)
        #expect(await desktop.counts().close == 0)
        #expect(await desktop.counts().open == 0)
        #expect(await runtime.count() == 0)
        #expect(try Data(contentsOf: fixture.files.authURL) == active)
    }

    @Test("A missing target credential fails before Codex is quit")
    func badTargetFailsBeforeQuit() async throws {
        let active = try codexCredentialData(email: "a@example.com", accountID: "account-a", accessToken: "active-a")
        let fixture = try CodexFixture(activeCredential: active)
        defer { fixture.remove() }
        let runtime = FakeCodexRuntime(liveHome: fixture.files.home)
        let desktop = FakeCodexDesktop()
        let service = CodexAccountService(
            emails: ["a@example.com", "b@example.com"],
            files: fixture.files,
            vault: FakeCodexVault(),
            runtime: runtime
        )

        await expectCodexError(.signIn) {
            _ = try await service.select(email: "b@example.com", desktop: desktop)
        }

        #expect(await desktop.counts().close == 0)
        #expect(await desktop.counts().open == 0)
        #expect(await runtime.count() == 0)
        #expect(try Data(contentsOf: fixture.files.authURL) == active)
    }

    @Test("A target preflight failure occurs before Codex is quit")
    func preflightFailureDoesNotQuit() async throws {
        let active = try codexCredentialData(email: "a@example.com", accountID: "account-a", accessToken: "active-a")
        let target = try codexCredentialData(email: "b@example.com", accountID: "account-b", accessToken: "saved-b")
        let fixture = try CodexFixture(activeCredential: active)
        defer { fixture.remove() }
        let runtime = FakeCodexRuntime(
            liveHome: fixture.files.home,
            outcomes: [.failure(.unavailable)]
        )
        let desktop = FakeCodexDesktop()
        let service = CodexAccountService(
            emails: ["a@example.com", "b@example.com"],
            files: fixture.files,
            vault: FakeCodexVault(["b@example.com": target]),
            runtime: runtime
        )

        await expectCodexError(.unavailable) {
            _ = try await service.select(email: "b@example.com", desktop: desktop)
        }

        #expect(await desktop.counts().close == 0)
        #expect(await desktop.counts().open == 0)
        #expect(try Data(contentsOf: fixture.files.authURL) == active)
    }

    @Test("A blocked quit leaves the live authentication unchanged")
    func blockedQuitLeavesAuthenticationUnchanged() async throws {
        let active = try codexCredentialData(email: "a@example.com", accountID: "account-a", accessToken: "active-a")
        let target = try codexCredentialData(email: "b@example.com", accountID: "account-b", accessToken: "saved-b")
        let refreshedTarget = try codexCredentialData(email: "b@example.com", accountID: "account-b", accessToken: "preflight-b")
        let fixture = try CodexFixture(activeCredential: active)
        defer { fixture.remove() }
        let runtime = FakeCodexRuntime(
            liveHome: fixture.files.home,
            outcomes: [.success(rotatedCredential: refreshedTarget)]
        )
        let desktop = FakeCodexDesktop(closeError: .quitBlocked)
        let service = CodexAccountService(
            emails: ["a@example.com", "b@example.com"],
            files: fixture.files,
            vault: FakeCodexVault(["b@example.com": target]),
            runtime: runtime
        )

        await expectCodexError(.quitBlocked) {
            _ = try await service.select(email: "b@example.com", desktop: desktop)
        }

        #expect(try Data(contentsOf: fixture.files.authURL) == active)
        #expect(await desktop.counts().close == 1)
        #expect(await desktop.counts().open == 0)
    }

    @Test("An outgoing identity change after quit aborts and reopens the prior desktop")
    func changedOutgoingIdentityAbortsAndReopens() async throws {
        let active = try codexCredentialData(email: "a@example.com", accountID: "account-a", accessToken: "active-a")
        let target = try codexCredentialData(email: "b@example.com", accountID: "account-b", accessToken: "saved-b")
        let refreshedTarget = try codexCredentialData(email: "b@example.com", accountID: "account-b", accessToken: "preflight-b")
        let external = try codexCredentialData(email: "c@example.com", accountID: "account-c", accessToken: "external-c")
        let fixture = try CodexFixture(activeCredential: active)
        defer { fixture.remove() }
        let events = CodexTestEventLog()
        let runtime = FakeCodexRuntime(
            liveHome: fixture.files.home,
            outcomes: [.success(rotatedCredential: refreshedTarget)],
            events: events
        )
        let authURL = fixture.files.authURL
        let desktop = FakeCodexDesktop(events: events) {
            try CodexAccountFiles.writePrivate(external, to: authURL)
        }
        let service = CodexAccountService(
            emails: ["a@example.com", "b@example.com", "c@example.com"],
            files: fixture.files,
            vault: FakeCodexVault(["b@example.com": target]),
            runtime: runtime
        )

        await expectCodexError(.changed) {
            _ = try await service.select(email: "b@example.com", desktop: desktop)
        }

        #expect(try Data(contentsOf: fixture.files.authURL) == external)
        #expect(events.values() == ["inspect:preflight:b@example.com", "close", "open"])
        #expect(await desktop.counts().close == 1)
        #expect(await desktop.counts().open == 1)
    }

    @Test("A target verification failure restores the outgoing credential and reopens Codex")
    func targetVerificationFailureRestoresOutgoingCredential() async throws {
        let active = try codexCredentialData(email: "a@example.com", accountID: "account-a", accessToken: "active-a")
        let target = try codexCredentialData(email: "b@example.com", accountID: "account-b", accessToken: "saved-b")
        let refreshedTarget = try codexCredentialData(email: "b@example.com", accountID: "account-b", accessToken: "preflight-b")
        let fixture = try CodexFixture(activeCredential: active)
        defer { fixture.remove() }
        let events = CodexTestEventLog()
        let runtime = FakeCodexRuntime(
            liveHome: fixture.files.home,
            outcomes: [
                .success(rotatedCredential: refreshedTarget),
                .failure(.unavailable),
            ],
            events: events
        )
        let desktop = FakeCodexDesktop(events: events)
        let service = CodexAccountService(
            emails: ["a@example.com", "b@example.com"],
            files: fixture.files,
            vault: FakeCodexVault(["b@example.com": target]),
            runtime: runtime
        )

        await expectCodexError(.unavailable) {
            _ = try await service.select(email: "b@example.com", desktop: desktop)
        }

        #expect(try Data(contentsOf: fixture.files.authURL) == active)
        #expect(events.values() == [
            "inspect:preflight:b@example.com", "close", "inspect:live:b@example.com", "open",
        ])
        let accounts = await service.snapshot()
        #expect(accounts.first(where: { $0.email == "a@example.com" })?.active == true)
        #expect(accounts.first(where: { $0.email == "b@example.com" })?.active == false)
    }

    @Test("A successful switch closes, installs, verifies, and reopens while preserving history")
    func successfulSwitchIsOrderedAndPreservesHistory() async throws {
        let active = try codexCredentialData(email: "a@example.com", accountID: "account-a", accessToken: "active-a")
        let target = try codexCredentialData(email: "b@example.com", accountID: "account-b", accessToken: "saved-b")
        let preflightTarget = try codexCredentialData(email: "b@example.com", accountID: "account-b", accessToken: "preflight-b")
        let verifiedTarget = try codexCredentialData(email: "b@example.com", accountID: "account-b", accessToken: "verified-b")
        let fixture = try CodexFixture(activeCredential: active)
        defer { fixture.remove() }
        let historyURL = fixture.files.home.appendingPathComponent("history/session-1.jsonl")
        let history = Data("{\"event\":\"existing history\"}\n".utf8)
        try CodexAccountFiles.writePrivate(history, to: historyURL)
        let events = CodexTestEventLog()
        let runtime = FakeCodexRuntime(
            liveHome: fixture.files.home,
            outcomes: [
                .success(rotatedCredential: preflightTarget),
                .success(rotatedCredential: verifiedTarget),
            ],
            events: events
        )
        let desktop = FakeCodexDesktop(events: events)
        let vault = FakeCodexVault(["b@example.com": target])
        let service = CodexAccountService(
            emails: ["a@example.com", "b@example.com"],
            files: fixture.files,
            vault: vault,
            runtime: runtime
        )

        let accounts = try await service.select(email: "b@example.com", desktop: desktop)

        #expect(events.values() == [
            "inspect:preflight:b@example.com", "close", "inspect:live:b@example.com", "open",
        ])
        #expect(try Data(contentsOf: fixture.files.authURL) == verifiedTarget)
        #expect(try vault.load(email: "b@example.com") == verifiedTarget)
        #expect(try Data(contentsOf: historyURL) == history)
        #expect(accounts.first(where: { $0.email == "a@example.com" })?.active == false)
        #expect(accounts.first(where: { $0.email == "b@example.com" })?.active == true)
    }

    @Test("A launch failure retains the committed account as the truthful active marker")
    func launchFailureRetainsCommittedActiveMarker() async throws {
        let active = try codexCredentialData(email: "a@example.com", accountID: "account-a", accessToken: "active-a")
        let target = try codexCredentialData(email: "b@example.com", accountID: "account-b", accessToken: "saved-b")
        let preflightTarget = try codexCredentialData(email: "b@example.com", accountID: "account-b", accessToken: "preflight-b")
        let verifiedTarget = try codexCredentialData(email: "b@example.com", accountID: "account-b", accessToken: "verified-b")
        let fixture = try CodexFixture(activeCredential: active)
        defer { fixture.remove() }
        let runtime = FakeCodexRuntime(
            liveHome: fixture.files.home,
            outcomes: [
                .success(rotatedCredential: preflightTarget),
                .success(rotatedCredential: verifiedTarget),
            ]
        )
        let desktop = FakeCodexDesktop(openError: .unavailable)
        let service = CodexAccountService(
            emails: ["a@example.com", "b@example.com"],
            files: fixture.files,
            vault: FakeCodexVault(["b@example.com": target]),
            runtime: runtime
        )

        await expectCodexError(.reopenFailed) {
            _ = try await service.select(email: "b@example.com", desktop: desktop)
        }

        #expect(try Data(contentsOf: fixture.files.authURL) == verifiedTarget)
        let accounts = await service.snapshot()
        #expect(accounts.first(where: { $0.email == "a@example.com" })?.active == false)
        #expect(accounts.first(where: { $0.email == "b@example.com" })?.active == true)
        let persisted = fixture.files.loadCache(emails: ["a@example.com", "b@example.com"])
        #expect(persisted.first(where: { $0.email == "b@example.com" })?.active == true)
        #expect(await desktop.counts().open == 1)
    }

    @Test("Refresh is rejected as busy while a selection is in flight")
    func concurrentRefreshRejectsBusySelection() async throws {
        let active = try codexCredentialData(email: "a@example.com", accountID: "account-a", accessToken: "active-a")
        let target = try codexCredentialData(email: "b@example.com", accountID: "account-b", accessToken: "saved-b")
        let preflightTarget = try codexCredentialData(email: "b@example.com", accountID: "account-b", accessToken: "preflight-b")
        let verifiedTarget = try codexCredentialData(email: "b@example.com", accountID: "account-b", accessToken: "verified-b")
        let fixture = try CodexFixture(activeCredential: active)
        defer { fixture.remove() }
        let runtime = FakeCodexRuntime(
            liveHome: fixture.files.home,
            outcomes: [
                .success(rotatedCredential: preflightTarget),
                .success(rotatedCredential: verifiedTarget),
            ],
            blockedInspectionNumbers: [1]
        )
        let desktop = FakeCodexDesktop()
        let service = CodexAccountService(
            emails: ["a@example.com", "b@example.com"],
            files: fixture.files,
            vault: FakeCodexVault(["b@example.com": target]),
            runtime: runtime
        )
        let selection = Task {
            try await service.select(email: "b@example.com", desktop: desktop)
        }
        await runtime.waitUntilInspection(1)

        await expectCodexError(.busy) {
            _ = try await service.refresh(usage: false)
        }

        await runtime.resumeInspection(1)
        _ = try await selection.value
        #expect(await runtime.count() == 2)
    }

    @Test("Selection is rejected as busy while refresh is in flight")
    func concurrentSelectionRejectsBusyRefresh() async throws {
        let active = try codexCredentialData(email: "a@example.com", accountID: "account-a", accessToken: "active-a")
        let refreshedActive = try codexCredentialData(email: "a@example.com", accountID: "account-a", accessToken: "refreshed-a")
        let fixture = try CodexFixture(activeCredential: active)
        defer { fixture.remove() }
        let runtime = FakeCodexRuntime(
            liveHome: fixture.files.home,
            outcomes: [.success(rotatedCredential: refreshedActive)],
            blockedInspectionNumbers: [1]
        )
        let desktop = FakeCodexDesktop()
        let service = CodexAccountService(
            emails: ["a@example.com", "b@example.com"],
            files: fixture.files,
            vault: FakeCodexVault(["a@example.com": active]),
            runtime: runtime
        )
        let refresh = Task { try await service.refresh(usage: true) }
        await runtime.waitUntilInspection(1)

        await expectCodexError(.busy) {
            _ = try await service.select(email: "b@example.com", desktop: desktop)
        }

        await runtime.resumeInspection(1)
        _ = try await refresh.value
        #expect(await desktop.counts().close == 0)
        #expect(await runtime.count() == 1)
    }

    @Test("Usage decoding accepts only exact five-hour and seven-day durations")
    func usageParsingRequiresExactDurations() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let exact = try CodexRuntime.decodeUsage(
            codexJSON(#"{"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":12.5,"windowDurationMins":300,"resetsAt":1800000300},"secondary":{"usedPercent":76,"windowDurationMins":10080,"resetsAt":1800000600}}}}"#),
            email: "person@example.com",
            now: now
        )

        #expect(exact.email == "person@example.com")
        #expect(exact.fetchedAt == now)
        #expect(exact.fiveHour?.percent == 12.5)
        #expect(exact.fiveHour?.resetsAt == Date(timeIntervalSince1970: 1_800_000_300))
        #expect(exact.sevenDay?.percent == 76)
        #expect(exact.sevenDay?.resetsAt == Date(timeIntervalSince1970: 1_800_000_600))

        do {
            _ = try CodexRuntime.decodeUsage(
                codexJSON(#"{"rateLimits":{"primary":{"usedPercent":50,"windowDurationMins":299},"secondary":{"usedPercent":50,"windowDurationMins":10081}}}"#),
                email: "person@example.com",
                now: now
            )
            Issue.record("Near-miss durations must not be classified as supported windows")
        } catch let error as CodexSwitchError {
            #expect(String(describing: error) == String(describing: CodexSwitchError.unavailable))
        }
    }

    @Test("Usage decoding rejects invalid percentages")
    func usageParsingRejectsInvalidPercentages() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let validBoundary = try CodexRuntime.decodeUsage(
            codexJSON(#"{"rateLimits":{"primary":{"usedPercent":0,"windowDurationMins":300},"secondary":{"usedPercent":100,"windowDurationMins":10080}}}"#),
            email: "person@example.com",
            now: now
        )
        #expect(validBoundary.fiveHour?.percent == 0)
        #expect(validBoundary.sevenDay?.percent == 100)

        for percentages in ["-0.001", "100.001", "true"] {
            let value = try codexJSON(
                "{\"rateLimits\":{\"primary\":{\"usedPercent\":\(percentages),\"windowDurationMins\":300}}}"
            )
            do {
                _ = try CodexRuntime.decodeUsage(value, email: "person@example.com", now: now)
                Issue.record("Invalid percentage \(percentages) must be rejected")
            } catch let error as CodexSwitchError {
                #expect(String(describing: error) == String(describing: CodexSwitchError.unavailable))
            }
        }
    }

    @Test("Cached usage expires by age and cannot cross credential identities")
    func cacheAgeAndEmailMismatchAreRejected() throws {
        let fixture = try CodexFixture()
        defer { fixture.remove() }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var account = CodexAccount(email: "person@gmail.com")
        account.credentialEmail = "person@googlemail.com"
        account.usage = LiveUsageSnapshot(
            email: "person@googlemail.com",
            fetchedAt: now.addingTimeInterval(-LiveUsagePolicy.cacheLifetime),
            fiveHour: LiveUsageWindow(percent: 42, resetsAt: nil),
            sevenDay: nil
        )
        try fixture.files.saveCache([account])

        let exactBoundary = fixture.files.loadCache(
            emails: ["person@gmail.com"],
            aliases: ["person@gmail.com": "person@googlemail.com"],
            now: now
        )
        #expect(exactBoundary.first?.usage != nil)

        let expired = fixture.files.loadCache(
            emails: ["person@gmail.com"],
            aliases: ["person@gmail.com": "person@googlemail.com"],
            now: now.addingTimeInterval(0.001)
        )
        #expect(expired.first?.usage == nil)

        account.usage = LiveUsageSnapshot(
            email: "another@example.com",
            fetchedAt: now,
            fiveHour: LiveUsageWindow(percent: 42, resetsAt: nil),
            sevenDay: nil
        )
        try fixture.files.saveCache([account])
        let mismatched = fixture.files.loadCache(
            emails: ["person@gmail.com"],
            aliases: ["person@gmail.com": "person@googlemail.com"],
            now: now
        )
        #expect(mismatched.first?.usage == nil)
    }
}
