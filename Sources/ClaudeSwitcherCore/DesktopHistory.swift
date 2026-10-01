import Foundation
import Darwin

public struct DesktopHistoryResult: Codable, Sendable {
    public struct Identity: Codable, Sendable, Equatable {
        public let account: String
        public let org: String
        public let email: String
        public let root: String
        public let pid: Int32
        public let startedAt: Double
        public let proof: String
        public let at: Double
        public var key: String { root + "/" + account + "/" + org }
    }
    public let ok: Bool
    public let email: String?
    public let count: Int?
    public let moved: Int?
    public let unavailable: Int?
    public let remoteLinks: Int?
    public let token: String?
    public let error: String?
    public let identity: Identity?

    public var message: String {
        if ok {
            if let moved { return "\(moved) Code sessions ready" }
            return "Code history is up to date"
        }
        switch error {
        case "desktop_signed_out": return "Sign in to Claude Desktop to share history"
        case "desktop_not_ready": return "Open one Claude Desktop profile to share history"
        case "unknown_account": return "Add this Desktop account to the switcher first"
        case "scheduled_sessions": return "Scheduled sessions need a separate transfer"
        case "sessions_busy_or_conflicted": return "History waiting · finish active Code sessions"
        case "desktop_busy": return "History waiting · close open Code sessions"
        case "desktop_running": return "Claude is still closing · try again"
        case "sessions_changed", "identity_changed", "plan_expired": return "Claude changed · try history sync again"
        case "project_missing": return "A session’s project folder is missing"
        case "undo_changed": return "History changed since the move · undo stopped"
        default: return "History needs attention · try again"
        }
    }
}

public struct DesktopHistoryRuntime: Sendable {
    public let node: String
    public let helper: String

    public init(node: String, helper: String) { self.node = node; self.helper = helper }

    public static func installed(bundle: Bundle = .main) -> Self? {
        guard let helper = bundle.url(forResource: "history", withExtension: "mjs", subdirectory: "History") else { return nil }
        let candidates = [NSHomeDirectory() + "/.local/bin/node", "/opt/homebrew/bin/node", "/usr/local/bin/node"]
        guard let node = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
        return Self(node: node, helper: helper.path)
    }

    public func request(_ command: String, arguments: [String] = []) throws -> DesktopHistoryResult {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("claude-history-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let outputURL = folder.appendingPathComponent("result.json")
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
        let output = try FileHandle(forWritingTo: outputURL)
        defer { try? output.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: node)
        process.arguments = [helper, command] + arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        process.environment = LaunchPlanning.terminalEnvironment(for: Profile(id: "history", label: "History"), inheriting: ProcessInfo.processInfo.environment)
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        if finished.wait(timeout: .now() + 90) == .timedOut {
            // Only this helper is terminated. Its journal permits a later recovery.
            process.terminate()
            if finished.wait(timeout: .now() + 2) == .timedOut { kill(process.processIdentifier, SIGKILL) }
            throw CocoaError(.executableRuntimeMismatch)
        }
        let data = try Data(contentsOf: outputURL)
        guard data.count < 1_048_576 else { throw CocoaError(.fileReadTooLarge) }
        return try JSONDecoder().decode(DesktopHistoryResult.self, from: data)
    }
}
