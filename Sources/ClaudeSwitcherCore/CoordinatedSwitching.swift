import Foundation
import Darwin

public struct CoordinatedSetup: Codable, Sendable {
    public let enabled: Bool
    public let python: String
    public let helper: String
    public let cswap: String

    public static var url: URL { Config.configURL.deletingLastPathComponent().appendingPathComponent("coordinated.json") }
    public static func load() -> Self? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
}

public struct CoordinatedSnapshot: Decodable, Sendable {
    public struct Window: Decodable, Sendable { public let pct: Double; public let resetsAt: String? }
    public struct Usage: Decodable, Sendable { public let fiveHour: Window?; public let sevenDay: Window? }
    public struct Account: Decodable, Sendable {
        public let email: String
        public let active: Bool
        public let usageStatus: String
        public let usage: Usage?
        public let usageFetchedAt: String?
        public let lastGoodUsage: Usage?
        public let lastGoodFetchedAt: String?
    }
    public struct Browser: Decodable, Sendable {
        public let ok: Bool
        public let email: String?
        public let accounts: [String]?
    }
    public let accounts: [Account]
    public let codeEmail: String?
    public let browser: Browser

    public func reading(email: String, now: Date = Date()) -> LiveUsageSnapshot? {
        guard let account = accounts.first(where: { $0.email.caseInsensitiveCompare(email) == .orderedSame }),
              let usage = account.usage ?? account.lastGoodUsage else { return nil }
        let dateString = account.usage != nil ? account.usageFetchedAt : account.lastGoodFetchedAt
        // Never promote an undated backend cache entry into a fresh reading.
        guard let fetchedAt = Self.date(dateString) else { return nil }
        func window(_ value: Window?) -> LiveUsageWindow? {
            guard let value, value.pct.isFinite, (0...100).contains(value.pct) else { return nil }
            return LiveUsageWindow(percent: value.pct, resetsAt: Self.date(value.resetsAt))
        }
        return LiveUsageSnapshot(email: email, fetchedAt: fetchedAt,
                                 fiveHour: window(usage.fiveHour), sevenDay: window(usage.sevenDay))
    }
    private static func date(_ text: String?) -> Date? {
        guard let text else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}

public struct CoordinatedResult: Decodable, Sendable {
    public let ok: Bool
    public let codeEmail: String?
    public let webEmail: String?
    public let browserReady: Bool?
    public let error: String?
    public let message: String?

    public var summary: String {
        if ok { return browserReady == true ? "Chrome and Code switched" : "Code switched · Chrome needs setup" }
        switch error {
        case "web_login_needed", "web_login_expired": return "Save this account in the Chrome companion first"
        case "web_switch_failed": return "Chrome could not switch · previous account restored"
        case "switch_in_progress": return "Another switch is finishing"
        case "code_restore_failed", "web_restore_failed": return "Account needs attention · check Chrome and Code"
        default: return "Could not switch accounts · try again"
        }
    }
}

/// Bounded subprocess calls. The helper emits only identity/usage/result metadata here;
/// Chrome's native-messaging channel is separate and never enters app diagnostics.
public enum CoordinatedSwitching {
    public static func snapshot(setup: CoordinatedSetup) throws -> CoordinatedSnapshot {
        try JSONDecoder().decode(CoordinatedSnapshot.self, from: run(setup: setup, arguments: ["snapshot"]))
    }
    public static func select(email: String, setup: CoordinatedSetup) throws -> CoordinatedResult {
        try JSONDecoder().decode(CoordinatedResult.self, from: run(setup: setup, arguments: ["switch", email]))
    }
    private static func run(setup: CoordinatedSetup, arguments: [String]) throws -> Data {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("claude-switch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("result.json")
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
        let output = try FileHandle(forWritingTo: url)
        defer { try? output.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: setup.python)
        process.arguments = [setup.helper] + arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        process.environment = LaunchPlanning.terminalEnvironment(for: Profile(id: "global", label: "Global"), inheriting: ProcessInfo.processInfo.environment)
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        try process.run()
        if done.wait(timeout: .now() + 350) == .timedOut {
            process.terminate()
            if done.wait(timeout: .now() + 1) == .timedOut { kill(process.processIdentifier, SIGKILL) }
            throw CocoaError(.executableRuntimeMismatch)
        }
        let data = try Data(contentsOf: url)
        guard data.count <= 2_097_152 else { throw CocoaError(.fileReadTooLarge) }
        return data
    }
}
