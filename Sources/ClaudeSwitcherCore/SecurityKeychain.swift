import Foundation
import Darwin

public enum SecurityKeychainError: Error, Equatable, Sendable {
    case failed(Int32)
    case unreadable
    case timedOut
}

/// Generic passwords kept through `/usr/bin/security`, the way claude-swap keeps its own.
///
/// macOS ties a Keychain item to the program that created it. This app is built and signed
/// locally, so every rebuild looked like a new program, and each item it had created asked
/// for the login password again, even after "Always Allow". Items created and read by
/// Apple's own `security` tool belong to a program that never changes, so they never ask.
/// Values are stored as base64 text, which `security -w` prints back unchanged.
public struct SecurityKeychain: Sendable {
    /// Runs `security` with `arguments`, feeding `input` on stdin, and returns its exit
    /// status and stdout.
    public typealias Runner = @Sendable (_ arguments: [String], _ input: String?) throws -> (status: Int32, output: String)

    /// errSecItemNotFound, as `security` reports it.
    public static let notFound: Int32 = 44
    /// `security -i` reads each stdin line through a 4096-byte buffer.
    static let stdinLimit = 4096 - 64

    private let run: Runner

    public init(run: @escaping Runner = SecurityKeychain.process) {
        self.run = run
    }

    /// The stored value, or `nil` when there is no such item.
    public func read(service: String, account: String) throws -> Data? {
        let result = try run(["find-generic-password", "-a", account, "-s", service, "-w"], nil)
        if result.status == Self.notFound { return nil }
        guard result.status == 0 else { throw SecurityKeychainError.failed(result.status) }
        let text = result.output.hasSuffix("\n") ? String(result.output.dropLast()) : result.output
        guard let data = Data(base64Encoded: text) else { throw SecurityKeychainError.unreadable }
        return data
    }

    /// Whether the item exists. Nothing is decrypted, so this never prompts.
    public func exists(service: String, account: String) -> Bool {
        (try? run(["find-generic-password", "-a", account, "-s", service], nil).status) == 0
    }

    public func write(_ data: Data, service: String, account: String, label: String) throws {
        let value = data.base64EncodedString()
        let line = "add-generic-password -U -a \(Self.quote(account)) -s \(Self.quote(service)) "
            + "-l \(Self.quote(label)) -w \(value)\n"
        let result: (status: Int32, output: String)
        if line.utf8.count <= Self.stdinLimit {
            // On stdin, the value never appears in the process list.
            result = try run(["-i"], line)
        } else {
            // Too long for that buffer. The value is briefly visible to this user's own
            // processes, which can read the item through `security` anyway.
            result = try run(["add-generic-password", "-U", "-a", account, "-s", service, "-l", label, "-w", value], nil)
        }
        guard result.status == 0 else { throw SecurityKeychainError.failed(result.status) }
    }

    /// Removes the item; a missing one counts as removed.
    public func delete(service: String, account: String) throws {
        let result = try run(["delete-generic-password", "-a", account, "-s", service], nil)
        guard result.status == 0 || result.status == Self.notFound else { throw SecurityKeychainError.failed(result.status) }
    }

    /// Quotes a value for a `security -i` command line, which is parsed shell-style.
    static func quote(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Runs the real `/usr/bin/security`, bounded so a locked or wedged Keychain cannot hang
    /// the caller.
    public static let process: Runner = { arguments, input in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments
        let output = Pipe()
        let stdin = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = input == nil ? FileHandle.nullDevice : stdin
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        if let input {
            try? stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8))
            try? stdin.fileHandleForWriting.close()
        }
        // Values are a few kilobytes, well inside a pipe's buffer, so reading after the
        // exit cannot deadlock.
        guard finished.wait(timeout: .now() + 20) == .success else {
            process.terminate()
            if finished.wait(timeout: .now() + 1) == .timedOut { kill(process.processIdentifier, SIGKILL) }
            throw SecurityKeychainError.timedOut
        }
        let data = (try? output.fileHandleForReading.readToEnd()) ?? Data()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
