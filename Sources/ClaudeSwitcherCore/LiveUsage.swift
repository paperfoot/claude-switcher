import Foundation
import Darwin

public struct LiveUsageWindow: Codable, Equatable, Sendable {
    public let percent: Double
    public let resetsAt: Date?

    public init(percent: Double, resetsAt: Date?) {
        self.percent = percent
        self.resetsAt = resetsAt
    }

    /// An elapsed window is unknown until the server returns a new reading.
    public func displayedPercent(at now: Date) -> Int? {
        guard resetsAt.map({ $0 > now }) ?? true else { return nil }
        return Int(min(100, max(0, percent)).rounded())
    }
}

public struct LiveUsageSnapshot: Codable, Equatable, Sendable {
    public let email: String
    public let fetchedAt: Date
    public let fiveHour: LiveUsageWindow?
    public let sevenDay: LiveUsageWindow?

    public init(email: String, fetchedAt: Date, fiveHour: LiveUsageWindow?, sevenDay: LiveUsageWindow?) {
        self.email = email
        self.fetchedAt = fetchedAt
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
    }

    public static func decode(_ data: Data, email: String, now: Date) throws -> Self {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root.keys.contains("five_hour") || root.keys.contains("seven_day") else {
            throw LiveUsageError.unavailable
        }
        func window(_ key: String) -> LiveUsageWindow? {
            guard let value = root[key] as? [String: Any],
                  let percent = value["utilization"] as? NSNumber,
                  CFGetTypeID(percent) != CFBooleanGetTypeID(), percent.doubleValue.isFinite,
                  (0...100).contains(percent.doubleValue) else { return nil }
            var reset: Date?
            if let text = value["resets_at"] as? String {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                reset = formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
                guard reset != nil else { return nil }
            } else if value["resets_at"] != nil, !(value["resets_at"] is NSNull) { return nil }
            return LiveUsageWindow(percent: percent.doubleValue, resetsAt: reset)
        }
        return Self(email: email, fetchedAt: now, fiveHour: window("five_hour"), sevenDay: window("seven_day"))
    }
}

public enum LiveUsageError: Error, Equatable, Sendable {
    case accountMismatch
    case unavailable
}

public enum LiveUsagePolicy {
    public static let refreshInterval: TimeInterval = 300
    public static let cacheLifetime: TimeInterval = 7 * 24 * 60 * 60
    public static let failureBackoff: TimeInterval = 900

    public static func nextRefresh(for snapshot: LiveUsageSnapshot, now: Date) -> Date {
        let reset = [snapshot.fiveHour?.resetsAt, snapshot.sevenDay?.resetsAt]
            .compactMap { $0 }.filter { $0 > now }.min() ?? .distantFuture
        return min(snapshot.fetchedAt.addingTimeInterval(refreshInterval), reset)
    }
}

/// Uses Claude Code's structured /usage control request. No model prompt, token access,
/// hooks, tools, MCP servers, or transcript scan. The CLI owns authentication and refresh.
public enum LiveUsageReader {
    public static let requestID = "claude-switcher-usage"

    public static func decodeResponse(_ data: Data, email: String, now: Date) throws -> LiveUsageSnapshot {
        guard data.count <= 2_097_152 else { throw LiveUsageError.unavailable }
        for line in data.split(separator: 10) {
            guard let message = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  message["type"] as? String == "control_response",
                  let response = message["response"] as? [String: Any],
                  response["request_id"] as? String == requestID else { continue }
            guard response["subtype"] as? String == "success",
                  let payload = response["response"] as? [String: Any],
                  payload["rate_limits_available"] as? Bool == true,
                  let limits = payload["rate_limits"] as? [String: Any] else { throw LiveUsageError.unavailable }
            return try LiveUsageSnapshot.decode(JSONSerialization.data(withJSONObject: limits), email: email, now: now)
        }
        throw LiveUsageError.unavailable
    }

    public static func read(profile: Profile, email: String, executable: String?, timeout: TimeInterval = 15,
                            baseEnvironment: [String: String] = ProcessInfo.processInfo.environment) throws -> LiveUsageSnapshot {
        guard let executable else { throw LiveUsageError.unavailable }
        let before = AccountStatusReader.read(profile: profile, executable: executable, baseEnvironment: baseEnvironment)
        guard before != .unavailable else { throw LiveUsageError.unavailable }
        guard before.matches(email) else { throw LiveUsageError.accountMismatch }
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent("claude-usage-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: directory) }
        let inputURL = directory.appendingPathComponent("input.jsonl")
        let outputURL = directory.appendingPathComponent("output.jsonl")
        let requests: [[String: Any]] = [
            ["type": "control_request", "request_id": "claude-switcher-init", "request": ["subtype": "initialize"]],
            ["type": "control_request", "request_id": requestID, "request": ["subtype": "get_usage", "skip_behaviors": true]],
        ]
        var inputData = Data()
        for request in requests {
            inputData.append(try JSONSerialization.data(withJSONObject: request))
            inputData.append(10)
        }
        guard fm.createFile(atPath: inputURL.path, contents: inputData, attributes: [.posixPermissions: 0o600]),
              fm.createFile(atPath: outputURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw LiveUsageError.unavailable
        }
        let input = try FileHandle(forReadingFrom: inputURL)
        defer { try? input.close() }
        let output = try FileHandle(forWritingTo: outputURL)
        defer { try? output.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.currentDirectoryURL = directory
        process.arguments = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                             "--tools", "", "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}",
                             "--setting-sources", "", "--settings", "{\"disableAllHooks\":true}",
                             "--no-session-persistence", "--no-chrome", "--disable-slash-commands"]
        var environment = LaunchPlanning.terminalEnvironment(for: profile, inheriting: baseEnvironment)
        // The broad traffic switch disables /usage itself; keep telemetry separately disabled.
        environment.removeValue(forKey: "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC")
        environment.removeValue(forKey: "CLAUDE_CODE_ENABLE_TELEMETRY")
        environment["DISABLE_TELEMETRY"] = "1"
        environment["DISABLE_ERROR_REPORTING"] = "1"
        environment["DISABLE_AUTOUPDATER"] = "1"
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        guard finished.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            if finished.wait(timeout: .now() + 0.5) == .timedOut, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 0.5)
            }
            throw LiveUsageError.unavailable
        }
        guard process.terminationStatus == 0 else { throw LiveUsageError.unavailable }
        let after = AccountStatusReader.read(profile: profile, executable: executable, baseEnvironment: baseEnvironment)
        guard after != .unavailable else { throw LiveUsageError.unavailable }
        guard after.matches(email) else { throw LiveUsageError.accountMismatch }
        return try decodeResponse(Data(contentsOf: outputURL), email: email, now: Date())
    }
}
