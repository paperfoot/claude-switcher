import Foundation
import Security

public struct CodexAccount: Codable, Equatable, Sendable {
    public var email: String
    public var credentialEmail: String?
    public var identityEmail: String { credentialEmail ?? email }
    public var connected: Bool = false
    public var active: Bool = false
    public var usage: LiveUsageSnapshot?
    public var usageFailed: Bool = false
    public init(email: String) { self.email = email.lowercased() }
}

public enum CodexSwitchError: Error, LocalizedError, Sendable {
    case busy, unavailable, signIn, wrongAccount, changed, keychain, unsupportedStore, quitBlocked, reopenFailed, restoreFailed
    case keychainStatus(Int32)
    public var errorDescription: String? {
        switch self {
        case .busy: return "Another account change is finishing"
        case .unavailable: return "Codex could not connect · try again"
        case .signIn: return "Connect this Codex account first"
        case .wrongAccount: return "A different account signed in · choose the requested email"
        case .changed: return "Codex changed accounts elsewhere · try again"
        case .keychain, .keychainStatus: return "Unlock Keychain to use saved accounts"
        case .unsupportedStore: return "This Codex credential store is not supported"
        case .quitBlocked: return "Finish active Codex work, then switch again"
        case .reopenFailed: return "Account selected · open Codex to continue"
        case .restoreFailed: return "Codex needs attention · previous login could not be restored"
        }
    }
}

/// A JWT is used only for matching a saved record. The official server verifies the login.
public struct CodexCredential: Sendable {
    public let data: Data
    public let email: String
    public let accountID: String
    public init(data: Data) throws {
        guard data.count < 1_048_576,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (object["auth_mode"] as? String).map({ $0 == "chatgpt" }) ?? true,
              (object["OPENAI_API_KEY"] as? String).map({ $0.isEmpty }) ?? true,
              let tokens = object["tokens"] as? [String: Any],
              let access = tokens["access_token"] as? String, !access.isEmpty,
              let idToken = tokens["id_token"] as? String,
              let payload = Self.payload(idToken),
              let email = payload["email"] as? String, email.contains("@"),
              let account = tokens["account_id"] as? String, !account.isEmpty else { throw CodexSwitchError.signIn }
        self.data = data
        self.email = email.lowercased()
        self.accountID = account
    }
    private static func payload(_ jwt: String) -> [String: Any]? {
        let parts = jwt.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var body = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        body += String(repeating: "=", count: (4 - body.count % 4) % 4)
        guard let data = Data(base64Encoded: body) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

public protocol CodexCredentialVault: Sendable {
    func load(email: String) throws -> Data?
    func save(_ data: Data, email: String) throws
}

public struct CodexKeychainVault: CodexCredentialVault {
    public init() {}
    private func query(_ email: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "tech.local.claude-switcher.codex",
         kSecAttrAccount as String: email.lowercased()]
    }
    public func load(email: String) throws -> Data? {
        var q = query(email)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw CodexSwitchError.keychainStatus(status) }
        return data
    }
    public func save(_ data: Data, email: String) throws {
        let q = query(email)
        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(q as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var item = q
            item[kSecValueData as String] = data
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw CodexSwitchError.keychainStatus(added) }
        } else if status != errSecSuccess { throw CodexSwitchError.keychainStatus(status) }
        guard try load(email: email) == data else { throw CodexSwitchError.keychain }
    }
}

public struct CodexAccountFiles: Sendable {
    public let home: URL
    public let directory: URL
    public var authURL: URL { home.appendingPathComponent("auth.json") }
    public var settingsURL: URL { directory.appendingPathComponent("codex-settings.json") }
    public var cacheURL: URL { directory.appendingPathComponent("codex-accounts.json") }
    public var lockURL: URL { directory.appendingPathComponent("codex.lock") }
    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex"),
                directory: URL = Config.configURL.deletingLastPathComponent()) {
        self.home = home; self.directory = directory
    }
    public func readActive() throws -> CodexCredential? {
        // Do not silently write an auth.json that a configured keyring client ignores.
        let config = (try? String(contentsOf: home.appendingPathComponent("config.toml"), encoding: .utf8)) ?? ""
        if let regex = try? NSRegularExpression(pattern: "(?m)^\\s*cli_auth_credentials_store\\s*=\\s*[\"'](keyring|auto|ephemeral)[\"']"),
           regex.firstMatch(in: config, range: NSRange(config.startIndex..., in: config)) != nil {
            throw CodexSwitchError.unsupportedStore
        }
        guard FileManager.default.fileExists(atPath: authURL.path) else { return nil }
        return try CodexCredential(data: Data(contentsOf: authURL))
    }
    public static func writePrivate(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".switch-\(UUID().uuidString)")
        guard fm.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { try? fm.removeItem(at: temporary) }
        guard rename(temporary.path, url.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
    public func saveCache(_ accounts: [CodexAccount]) throws {
        try Self.writePrivate(JSONEncoder().encode(accounts), to: cacheURL)
    }
    public func loadCache(emails: [String], aliases: [String: String] = [:], now: Date = Date()) -> [CodexAccount] {
        let stored = (try? JSONDecoder().decode([CodexAccount].self, from: Data(contentsOf: cacheURL))) ?? []
        return emails.map { email in
            var value = stored.first(where: { $0.email.caseInsensitiveCompare(email) == .orderedSame }) ?? CodexAccount(email: email)
            value.credentialEmail = aliases[email.lowercased()]?.lowercased()
            if let reading = value.usage,
               reading.email.caseInsensitiveCompare(value.identityEmail) != .orderedSame || now.timeIntervalSince(reading.fetchedAt) > LiveUsagePolicy.cacheLifetime {
                value.usage = nil
            }
            return value
        }
    }
}

public protocol CodexDesktopControlling: Sendable {
    func close() async throws -> Bool
    func open() async throws
}

/// The backend is injected for failure/rollback tests without touching real accounts.
public protocol CodexAccountVerifying: Sendable {
    func inspect(home: URL, usage: Bool) async throws -> (CodexCredential, LiveUsageSnapshot?)
    func login(home: URL, openURL: @escaping @Sendable (URL) async throws -> Void) async throws -> CodexCredential
}

public struct CodexRuntime: CodexAccountVerifying {
    public let executable: URL
    public init(executable: URL) { self.executable = executable }
    public static func installed() -> Self? {
        for app in ["/Applications/ChatGPT.app", "/Applications/Codex.app"] {
            for path in ["Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex", "Contents/Resources/codex"] {
                let url = URL(fileURLWithPath: app).appendingPathComponent(path)
                if FileManager.default.isExecutableFile(atPath: url.path) { return Self(executable: url) }
            }
        }
        return nil
    }
    private func session(home: URL) async throws -> CodexRPCSession {
        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("OPENAI_") || key.hasPrefix("CODEX_") { environment.removeValue(forKey: key) }
        let rpc = try CodexRPCSession(executableURL: executable, profileHome: home, environment: environment)
        do { try await rpc.initialize(timeout: .seconds(20), clientVersion: "0.8.0"); return rpc }
        catch { await rpc.stop(); throw error }
    }
    public func inspect(home: URL, usage: Bool) async throws -> (CodexCredential, LiveUsageSnapshot?) {
        let rpc = try await session(home: home)
        return try await withTaskCancellationHandler {
            do {
                let identity = try await rpc.request(method: "account/read", id: 1, params: ["refreshToken": false], timeout: .seconds(20))
                let credential = try CodexCredential(data: Data(contentsOf: home.appendingPathComponent("auth.json")))
                guard identity["account"]?["email"]?.stringValue?.lowercased() == credential.email else { throw CodexSwitchError.wrongAccount }
                var reading: LiveUsageSnapshot?
                if usage {
                    let limits = try await rpc.request(method: "account/rateLimits/read", id: 2, timeout: .seconds(20))
                    reading = try Self.decodeUsage(limits, email: credential.email)
                }
                await rpc.stop()
                let refreshed = try CodexCredential(data: Data(contentsOf: home.appendingPathComponent("auth.json")))
                guard refreshed.accountID == credential.accountID, refreshed.email == credential.email else { throw CodexSwitchError.changed }
                return (refreshed, reading)
            } catch { await rpc.stop(); throw error }
        } onCancel: { Task { await rpc.stop() } }
    }
    public func login(home: URL, openURL: @escaping @Sendable (URL) async throws -> Void) async throws -> CodexCredential {
        let rpc = try await session(home: home)
        return try await withTaskCancellationHandler {
            do {
                let start = try await rpc.request(method: "account/login/start", id: 1, params: ["type": "chatgpt"], timeout: .seconds(20))
                guard let raw = start["authUrl"]?.stringValue, let url = URL(string: raw), url.scheme == "https",
                      let host = url.host, host == "auth.openai.com" || host.hasSuffix(".openai.com") || host == "chatgpt.com" else { throw CodexSwitchError.unavailable }
                try await openURL(url)
                let done = try await rpc.notification(method: "account/login/completed", timeout: .seconds(600))
                guard done["success"]?.boolValue == true else { throw CodexSwitchError.signIn }
                await rpc.stop()
                return try await inspect(home: home, usage: false).0
            } catch { await rpc.stop(); throw error }
        } onCancel: { Task { await rpc.stop() } }
    }
    static func decodeUsage(_ value: CodexJSONValue, email: String, now: Date = Date()) throws -> LiveUsageSnapshot {
        guard let bucket = value["rateLimitsByLimitId"]?["codex"] ?? value["rateLimits"] else { throw CodexSwitchError.unavailable }
        var five: LiveUsageWindow?, week: LiveUsageWindow?
        for key in ["primary", "secondary"] {
            guard let v = bucket[key], let used = v["usedPercent"]?.doubleValue,
                  used.isFinite, (0...100).contains(used), let minutes = v["windowDurationMins"]?.intValue else { continue }
            let reset = v["resetsAt"]?.doubleValue.flatMap { $0.isFinite && $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
            let window = LiveUsageWindow(percent: used, resetsAt: reset)
            if minutes == 300 { five = window }
            if minutes == 10080 { week = window }
        }
        guard five != nil || week != nil else { throw CodexSwitchError.unavailable }
        return LiveUsageSnapshot(email: email, fetchedAt: now, fiveHour: five, sevenDay: week)
    }
}

public struct CodexAccountSettings: Codable, Sendable {
    public var emails: [String]
    public var aliases: [String: String]
    public init(emails: [String], aliases: [String: String] = [:]) { self.emails = emails; self.aliases = aliases }
    public static func load(fallbackEmails: [String], files: CodexAccountFiles = .init()) -> Self {
        (try? JSONDecoder().decode(Self.self, from: Data(contentsOf: files.settingsURL))) ?? Self(emails: fallbackEmails)
    }
    public func save(files: CodexAccountFiles = .init()) throws {
        try CodexAccountFiles.writePrivate(JSONEncoder().encode(self), to: files.settingsURL)
    }
}
