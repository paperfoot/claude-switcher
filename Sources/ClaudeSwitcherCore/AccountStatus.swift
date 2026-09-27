import Darwin
import Foundation

public enum AccountStatus: Equatable, Sendable {
    case signedIn(email: String?, plan: String?)
    case signedOut
    case unavailable

    public var email: String? {
        if case .signedIn(let email, _) = self { return email }
        return nil
    }

    public func matches(_ expectedEmail: String?) -> Bool {
        guard case .signedIn(let email, _) = self else { return false }
        guard let expectedEmail else { return true }
        return email?.caseInsensitiveCompare(expectedEmail) == .orderedSame
    }

    public static func decode(_ data: Data) -> AccountStatus {
        struct Response: Decodable {
            let loggedIn: Bool
            let email: String?
            let subscriptionType: String?
            let authMethod: String?
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else { return .unavailable }
        guard response.loggedIn else { return .signedOut }
        // API-key authentication must not inherit a stale subscription-account email.
        let email = (response.authMethod == "claude.ai" ? response.email : nil)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return .signedIn(email: email?.isEmpty == false ? email : nil,
                         plan: response.subscriptionType)
    }
}

/// Reads the official CLI's account summary. No tokens or Keychain output enter the app.
public enum AccountStatusReader {
    public static func read(profile: Profile, executable: String?, timeout: TimeInterval = 6,
                            baseEnvironment: [String: String] = ProcessInfo.processInfo.environment) -> AccountStatus {
        guard let executable else { return .unavailable }
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("claude-account-\(UUID().uuidString).json")
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil,
                                            attributes: [.posixPermissions: 0o600]) else { return .unavailable }
        defer { try? FileManager.default.removeItem(at: outputURL) }
        guard let output = try? FileHandle(forWritingTo: outputURL) else { return .unavailable }
        defer { try? output.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["auth", "status", "--json"]
        var environment = LaunchPlanning.terminalEnvironment(for: profile, inheriting: baseEnvironment)
        environment["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] = "1"
        environment["DISABLE_AUTOUPDATER"] = "1"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() } catch { return .unavailable }
        guard finished.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            if finished.wait(timeout: .now() + 0.5) == .timedOut, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 0.5)
            }
            return .unavailable
        }
        // `auth status` exits 1 for signed-out profiles but still returns valid JSON.
        guard process.terminationStatus == 0 || process.terminationStatus == 1,
              let data = try? Data(contentsOf: outputURL), data.count <= 65_536 else { return .unavailable }
        return AccountStatus.decode(data)
    }
}

/// The main menu always distinguishes a verified identity from a requested login.
public struct AccountPresentation: Equatable, Sendable {
    public let title: String
    public let badge: String?
    public let help: String

    public init(profile: Profile, status: AccountStatus?) {
        let expected = profile.expectedEmail
        title = expected ?? status?.email ?? profile.label
        switch status {
        case nil:
            badge = "Checking…"
            help = "Reading the account from Claude Code."
        case .unavailable:
            badge = "Check failed"
            help = "Could not read this account. Click to try again."
        case .signedOut:
            badge = "Sign in"
            help = "Sign in to this Claude Code account."
        case .signedIn(let email, let plan):
            if let expected, status?.matches(expected) != true {
                badge = "Sign in"
                help = "Claude Code reports \(email ?? "an unknown account"). Sign in as \(expected)."
            } else if email == nil {
                badge = "Email unavailable"
                help = "Claude Code is authenticated but did not report an email. Click to open."
            } else {
                badge = plan?.isEmpty == false ? plan?.capitalized : nil
                help = "Open Claude Code as \(email!)."
            }
        }
    }
}
