import Foundation
import Testing
@testable import ClaudeSwitcherCore

/// An in-memory stand-in for `/usr/bin/security`; nothing here touches the real Keychain.
private final class FakeSecurity: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: String] = [:]
    private(set) var calls: [(arguments: [String], input: String?)] = []

    var runner: SecurityKeychain.Runner {
        { [self] arguments, input in try handle(arguments, input) }
    }

    func stored(service: String, account: String) -> String? {
        lock.withLock { items["\(service)|\(account)"] }
    }

    private func handle(_ arguments: [String], _ input: String?) throws -> (status: Int32, output: String) {
        lock.lock()
        defer { lock.unlock() }
        calls.append((arguments, input))
        var arguments = arguments
        if arguments == ["-i"], let input {
            arguments = Self.split(input.trimmingCharacters(in: .newlines))
        }
        func value(_ flag: String) -> String? {
            arguments.firstIndex(of: flag).map { arguments[$0 + 1] }
        }
        let key = "\(value("-s") ?? "")|\(value("-a") ?? "")"
        switch arguments.first {
        case "find-generic-password":
            guard let stored = items[key] else { return (SecurityKeychain.notFound, "") }
            return (0, arguments.contains("-w") ? stored + "\n" : "attributes")
        case "add-generic-password":
            items[key] = value("-w")
            return (0, "")
        case "delete-generic-password":
            return items.removeValue(forKey: key) == nil ? (SecurityKeychain.notFound, "") : (0, "")
        default:
            return (1, "")
        }
    }

    /// Splits a `security -i` line the way its shell-style parser does, for these tests.
    private static func split(_ line: String) -> [String] {
        var words: [String] = []
        var current = ""
        var quoted = false
        var escaped = false
        for character in line {
            if escaped { current.append(character); escaped = false; continue }
            if character == "\\" && quoted { escaped = true; continue }
            if character == "\"" { quoted.toggle(); continue }
            if character == " " && !quoted {
                if !current.isEmpty { words.append(current); current = "" }
                continue
            }
            current.append(character)
        }
        if !current.isEmpty { words.append(current) }
        return words
    }
}

private struct FakeLegacyVault: CodexCredentialVault {
    let data: [String: Data]
    func load(email: String) throws -> Data? { data[email] }
    func save(_ data: Data, email: String) throws { Issue.record("the legacy vault must never be written") }
}

@Suite("Keychain items kept through security")
struct SecurityKeychainTests {
    @Test("Values round-trip as base64, and a missing item reads as nil")
    func roundTrip() throws {
        let fake = FakeSecurity()
        let keychain = SecurityKeychain(run: fake.runner)
        #expect(try keychain.read(service: "Svc", account: "a@example.com") == nil)
        let value = Data("{\"tokens\":{\"line\":\"one\\ntwo\"}}".utf8)
        try keychain.write(value, service: "Svc", account: "a@example.com", label: "Label")
        #expect(try keychain.read(service: "Svc", account: "a@example.com") == value)
        #expect(keychain.exists(service: "Svc", account: "a@example.com"))
        try keychain.delete(service: "Svc", account: "a@example.com")
        #expect(!keychain.exists(service: "Svc", account: "a@example.com"))
    }

    @Test("Short values go through stdin; long ones fall back to arguments")
    func stdinThenArguments() throws {
        let fake = FakeSecurity()
        let keychain = SecurityKeychain(run: fake.runner)
        try keychain.write(Data("short".utf8), service: "Svc", account: "a", label: "L")
        #expect(fake.calls.last?.arguments == ["-i"])
        #expect(fake.calls.last?.input?.contains(Data("short".utf8).base64EncodedString()) == true)
        try keychain.write(Data(repeating: 65, count: 4_500), service: "Svc", account: "a", label: "L")
        #expect(fake.calls.last?.arguments.first == "add-generic-password")
        #expect(try keychain.read(service: "Svc", account: "a") == Data(repeating: 65, count: 4_500))
    }

    @Test("Names with quotes and backslashes survive the stdin command line")
    func quoting() throws {
        let fake = FakeSecurity()
        let keychain = SecurityKeychain(run: fake.runner)
        try keychain.write(Data("v".utf8), service: "Odd \"name\" \\ here", account: "a b", label: "L")
        #expect(fake.stored(service: "Odd \"name\" \\ here", account: "a b") == Data("v".utf8).base64EncodedString())
    }

    @Test("A failing security call is an error, not an empty value")
    func failure() {
        let keychain = SecurityKeychain(run: { _, _ in (51, "") })
        #expect(throws: SecurityKeychainError.failed(51)) {
            _ = try keychain.read(service: "Svc", account: "a")
        }
    }

    @Test("A Codex login from an older version moves over once and is then read from security")
    func codexMigration() throws {
        let fake = FakeSecurity()
        let login = Data("{\"auth_mode\":\"chatgpt\"}".utf8)
        let vault = CodexSecurityVault(keychain: SecurityKeychain(run: fake.runner),
                                       legacy: FakeLegacyVault(data: ["work@example.com": login]))
        #expect(try vault.load(email: "Work@Example.com") == login)
        #expect(fake.stored(service: CodexSecurityVault.service, account: "work@example.com") == login.base64EncodedString())
        let newOnly = CodexSecurityVault(keychain: SecurityKeychain(run: fake.runner), legacy: nil)
        #expect(try newOnly.load(email: "work@example.com") == login)
        #expect(try newOnly.load(email: "other@example.com") == nil)
    }

    @Test("The Jev key moves from its old item on first read and reports existence without a read")
    func jevMigration() throws {
        let fake = FakeSecurity()
        let legacy = MemoryJevStorage()
        try legacy.write(Data("tsk-example".utf8), service: JevSecurityStorage.legacyService, account: JevKeyStore.account)
        let storage = JevSecurityStorage(keychain: SecurityKeychain(run: fake.runner), legacy: legacy)
        #expect(storage.exists(service: JevKeyStore.service, account: JevKeyStore.account))
        #expect(JevKeyStore.load(from: storage) == "tsk-example")
        #expect(fake.stored(service: JevKeyStore.service, account: JevKeyStore.account) == Data("tsk-example".utf8).base64EncodedString())
    }
}

private final class MemoryJevStorage: JevKeyStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]
    func read(service: String, account: String) throws -> Data? { lock.withLock { items["\(service)|\(account)"] } }
    func write(_ data: Data, service: String, account: String) throws { lock.withLock { items["\(service)|\(account)"] = data } }
    func delete(service: String, account: String) throws { _ = lock.withLock { items.removeValue(forKey: "\(service)|\(account)") } }
}
