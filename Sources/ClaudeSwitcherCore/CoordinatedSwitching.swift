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
        /// When each saved Chrome login expires, in Unix seconds, keyed by email.
        public let expiries: [String: Double]?

        /// When the saved Chrome login for `email` stops working, if known.
        public func loginExpiry(email: String) -> Date? {
            guard let seconds = expiries?.first(where: { $0.key.caseInsensitiveCompare(email) == .orderedSame })?.value,
                  seconds.isFinite else { return nil }
            return Date(timeIntervalSince1970: seconds)
        }
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
    /// Code switched but a Chrome profile did not; `ok` is false on the wire.
    public let partial: Bool?
    public let codeEmail: String?
    public let webEmail: String?
    public let browserReady: Bool?
    /// Always a snake_case code when `ok` is false; `message` is optional text.
    public let error: String?
    public let message: String?
    public let browserError: String?

    /// Code now uses the selected account. True for a full success and for a partial
    /// result where only Chrome failed, which deserves amber rather than red.
    public var codeSwitched: Bool { ok || (partial == true && codeEmail != nil) }

    public var summary: String {
        if ok { return browserReady == true ? "Chrome and Code switched" : "Code switched · Chrome needs setup" }
        switch error {
        case "web_login_needed", "web_login_expired": return "Save this account in the Chrome companion first"
        case "web_switch_failed": return "Chrome could not switch · previous account restored"
        case "switch_in_progress": return "Another switch is finishing"
        case "code_only_after_web_failure":
            switch browserError {
            case "web_login_needed", "web_login_expired": return "Code switched · sign in to Claude.ai once"
            case "host_timeout", "host_disconnected", "host_unavailable", "web_unavailable": return "Code switched · Chrome is not responding"
            case "browser_timeout": return "Code switched · Chrome took too long"
            case "switch_in_progress": return "Code switched · Chrome is busy"
            case "web_restore_failed": return "Code switched · Chrome needs attention"
            default: return "Code switched · Chrome could not switch"
            }
        case "code_restore_failed", "web_restore_failed": return "Account needs attention · check Chrome and Code"
        case "keychain_unavailable": return "Keychain is locked · unlock it and try again"
        case "backend_unavailable": return "Switching needs setup · open Settings"
        case "unknown_account": return "This account is not set up for switching"
        default: return "Could not switch accounts · try again"
        }
    }
}

/// The outcome of one automatic-switch decision.
public struct AutoSwitchResult: Decodable, Sendable {
    public let ok: Bool
    /// claude-swap moved Claude Code to `codeEmail`.
    public let switched: Bool?
    /// Why nothing changed, e.g. "below-threshold" or "all_exhausted".
    public let reason: String?
    public let codeEmail: String?
    public let previousEmail: String?
    /// claude-swap's trigger: "proactive", "at-limit" or "failover".
    public let trigger: String?
    public let browserReady: Bool?
    public let browserError: String?
}

/// A coordinator run that produced no usable result. `description` may end with the
/// helper's stderr for diagnostics; it is never meant for menu text.
public struct CoordinatedHelperError: Error, CustomStringConvertible {
    public let reason: String
    public let stderrTail: String

    public var description: String {
        stderrTail.isEmpty ? "Coordinated helper \(reason)" : "Coordinated helper \(reason). stderr: \(stderrTail)"
    }
}

/// Bounded subprocess calls. The helper emits only identity/usage/result metadata here;
/// Chrome's native-messaging channel is separate and never enters app diagnostics.
public enum CoordinatedSwitching {
    /// Outer bound of the deadline ladder in bridge/deadlines.py. The helper finishes a
    /// switch, including any rollback, within its 300 s budget; this only stops a hung helper.
    public static let helperTimeout: TimeInterval = 350
    /// The helper prints no secrets, but only this much of its stderr is kept.
    static let stderrTailLimit = 4096

    struct HelperOutput {
        let data: Data
        let status: Int32
        let stderrTail: String
    }

    public static func snapshot(setup: CoordinatedSetup) throws -> CoordinatedSnapshot {
        try decode(CoordinatedSnapshot.self, from: run(setup: setup, arguments: ["snapshot"]))
    }
    public static func select(email: String, setup: CoordinatedSetup) throws -> CoordinatedResult {
        try decode(CoordinatedResult.self, from: run(setup: setup, arguments: ["switch", email]))
    }
    /// One claude-swap auto-switch decision. When it moves Claude Code to another account,
    /// the helper moves the connected Chrome profiles to the same account before returning.
    public static func autoTick(setup: CoordinatedSetup, threshold: Double) throws -> AutoSwitchResult {
        try decode(AutoSwitchResult.self, from: run(setup: setup, arguments: ["auto-tick", String(threshold)]))
    }
    static func decode<T: Decodable>(_ type: T.Type, from output: HelperOutput) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: output.data)
        } catch {
            throw CoordinatedHelperError(reason: "returned unreadable output (exit \(output.status))", stderrTail: output.stderrTail)
        }
    }
    static func run(setup: CoordinatedSetup, arguments: [String], timeout: TimeInterval = helperTimeout) throws -> HelperOutput {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("claude-switch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("result.json")
        let errorURL = directory.appendingPathComponent("stderr.log")
        for path in [url.path, errorURL.path] {
            guard FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
        }
        let output = try FileHandle(forWritingTo: url)
        defer { try? output.close() }
        // A file, unlike a pipe, never fills up and stalls the helper.
        let errors = try FileHandle(forWritingTo: errorURL)
        defer { try? errors.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: setup.python)
        process.arguments = [setup.helper] + arguments
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        process.environment = LaunchPlanning.terminalEnvironment(for: Profile(id: "global", label: "Global"), inheriting: ProcessInfo.processInfo.environment)
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        try process.run()
        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if done.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = done.wait(timeout: .now() + 1)
            }
            throw CoordinatedHelperError(reason: "timed out after \(Int(timeout)) s", stderrTail: tail(of: errorURL))
        }
        let data = try Data(contentsOf: url)
        guard data.count <= 2_097_152 else {
            throw CoordinatedHelperError(reason: "printed too much output", stderrTail: tail(of: errorURL))
        }
        return HelperOutput(data: data, status: process.terminationStatus, stderrTail: tail(of: errorURL))
    }
    static func tail(of url: URL, limit: Int = stderrTailLimit) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return "" }
        try? handle.seek(toOffset: end > UInt64(limit) ? end - UInt64(limit) : 0)
        let data = (try? handle.readToEnd()) ?? Data()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
