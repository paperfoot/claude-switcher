// Portions adapted from Codex Account Switcher.
// Copyright (c) 2026 liuzhao1225. Licensed under the MIT License.
// See ThirdParty/CodexAccountSwitcher-LICENSE.

import Foundation
import Darwin

public enum CodexJSONValue: Decodable, Sendable {
    case object([String: CodexJSONValue])
    case array([CodexJSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([CodexJSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: CodexJSONValue].self))
        }
    }

    public var objectValue: [String: CodexJSONValue]? {
        guard case let .object(value) = self else { return nil }
        return value
    }

    public var stringValue: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }

    public var doubleValue: Double? {
        guard case let .number(value) = self else { return nil }
        return value
    }

    public var intValue: Int? { doubleValue.flatMap(Int.init(exactly:)) }

    public var boolValue: Bool? {
        guard case let .bool(value) = self else { return nil }
        return value
    }

    subscript(key: String) -> CodexJSONValue? { objectValue?[key] }
}

internal enum CodexRPCError: Error, Sendable {
    case malformedResponse
    case remoteError(code: Int?, message: String)
    case connectionClosedWithDetails(String)
    case connectionClosed
    case timeout
    case processLaunchFailed(String)
}

private struct RPCRemoteError: Decodable, Sendable {
    public let code: Int?
    public let message: String
}

private struct RPCEnvelope: Decodable, Sendable {
    public let id: Int?
    public let method: String?
    public let params: CodexJSONValue?
    public let result: CodexJSONValue?
    public let error: RPCRemoteError?
}

private final class LinePump: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var lines: [Data] = []
    private var waiters: [CheckedContinuation<Data?, Never>] = []
    private var isFinished = false

    public init(handle: FileHandle) {
        handle.readabilityHandler = { [weak self] readable in
            guard let self else { return }
            let data = readable.availableData
            guard !data.isEmpty else {
                self.finish()
                return
            }
            self.consume(data)
        }
    }

    private func consume(_ data: Data) {
        lock.lock()
        buffer.append(data)
        var parsedLines: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            if !line.isEmpty { parsedLines.append(line) }
        }
        lock.unlock()
        for line in parsedLines {
            deliver(line)
        }
    }

    public func next() async -> Data? {
        await withCheckedContinuation { continuation in
            lock.lock()
            if !lines.isEmpty {
                let line = lines.removeFirst()
                lock.unlock()
                continuation.resume(returning: line)
            } else if isFinished {
                lock.unlock()
                continuation.resume(returning: nil)
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    private func deliver(_ line: Data) {
        lock.lock()
        if !waiters.isEmpty {
            let waiter = waiters.removeFirst()
            lock.unlock()
            waiter.resume(returning: line)
        } else {
            lines.append(line)
            lock.unlock()
        }
    }

    public func finish() {
        lock.lock()
        guard !isFinished else { lock.unlock(); return }
        isFinished = true
        if !buffer.isEmpty {
            lines.append(buffer)
            buffer.removeAll()
        }
        let pending = waiters
        waiters.removeAll()
        let deliveries = pending.map { _ in lines.isEmpty ? nil : lines.removeFirst() }
        lock.unlock()
        for (waiter, data) in zip(pending, deliveries) { waiter.resume(returning: data) }
    }
}

private final class StderrDrain: @unchecked Sendable {
    private let lock = NSLock()
    private var tail = Data()
    private let maximumBytes = 4_096

    private var isFinished = false
    private var waiters: [CheckedContinuation<String, Never>] = []

    public func finishedMessage() async -> String {
        await withCheckedContinuation { continuation in
            lock.lock()
            if isFinished {
                let message = String(decoding: tail, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                lock.unlock()
                continuation.resume(returning: message)
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    public func finish() {
        lock.lock()
        guard !isFinished else { lock.unlock(); return }
        isFinished = true
        let message = String(decoding: tail, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        pending.forEach { $0.resume(returning: message) }
    }

    public init(handle: FileHandle) {
        handle.readabilityHandler = { [weak self] readable in
            guard let self else { return }
            let data = readable.availableData
            guard !data.isEmpty else {
                readable.readabilityHandler = nil
                self.finish()
                return
            }
            self.lock.lock()
            self.tail.append(data)
            if self.tail.count > self.maximumBytes {
                self.tail.removeFirst(self.tail.count - self.maximumBytes)
            }
            self.lock.unlock()
        }
    }
}

internal actor CodexRPCSession {
    private let process: Process
    private let input: FileHandle
    private let output: FileHandle
    private let errorOutput: FileHandle
    private let pump: LinePump
    private let stderrDrain: StderrDrain
    private let decoder = JSONDecoder()
    private var didTimeout = false
    private var pendingNotifications: [RPCEnvelope] = []

    public init(executableURL: URL, profileHome: URL, environment inheritedEnvironment: [String: String]) throws {
        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = executableURL
        process.arguments = ["app-server", "--stdio"]
        var environment = inheritedEnvironment
        environment["CODEX_HOME"] = profileHome.path
        process.environment = environment
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let pump = LinePump(handle: outputPipe.fileHandleForReading)
        let stderrDrain = StderrDrain(handle: errorPipe.fileHandleForReading)
        self.process = process
        input = inputPipe.fileHandleForWriting
        output = outputPipe.fileHandleForReading
        errorOutput = errorPipe.fileHandleForReading
        self.pump = pump
        self.stderrDrain = stderrDrain

        do {
            try process.run()
        } catch {
            throw CodexRPCError.processLaunchFailed(error.localizedDescription)
        }
    }

    public func initialize(timeout: Duration, clientVersion: String) async throws {
        try send([
            "method": "initialize",
            "id": 0,
            "params": [
                "clientInfo": [
                    "name": "paperfoot_account_switcher",
                    "title": "Claude and Codex Switcher",
                    "version": clientVersion,
                ],
            ],
        ])
        _ = try await response(id: 0, timeout: timeout)
        try send(["method": "initialized", "params": [:]])
    }

    public func request(
        method: String,
        id: Int,
        params: [String: Any] = [:],
        timeout: Duration
    ) async throws -> CodexJSONValue {
        try send(["method": method, "id": id, "params": params])
        let envelope = try await response(id: id, timeout: timeout)
        guard let result = envelope.result else { throw CodexRPCError.malformedResponse }
        return result
    }

    public func notification(method: String, timeout: Duration) async throws -> CodexJSONValue {
        let envelope = try await receive(
            where: { $0.method == method && $0.id == nil },
            timeout: timeout
        )
        return envelope.params ?? .object([:])
    }

    public func stop() async {
        output.readabilityHandler = nil
        errorOutput.readabilityHandler = nil
        try? input.close()
        if process.isRunning {
            process.terminate()
        }
        pump.finish()
        stderrDrain.finish()
        // Only this short-lived helper process is stopped. Never signal the desktop.
        let child = process
        await Task.detached {
            let exited = DispatchSemaphore(value: 0)
            child.terminationHandler = { _ in exited.signal() }
            if child.isRunning && exited.wait(timeout: .now() + 2) == .timedOut && child.isRunning {
                kill(child.processIdentifier, SIGKILL)
            }
            child.waitUntilExit()
        }.value
    }

    private func response(id: Int, timeout: Duration) async throws -> RPCEnvelope {
        try await receive(where: { $0.id == id }, timeout: timeout)
    }

    private func receive(
        where predicate: @escaping @Sendable (RPCEnvelope) -> Bool,
        timeout: Duration
    ) async throws -> RPCEnvelope {
        if let index = pendingNotifications.firstIndex(where: predicate) {
            return pendingNotifications.remove(at: index)
        }
        didTimeout = false
        let timeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(for: timeout)
                await self?.triggerTimeout()
            } catch {
                // Cancellation means a response arrived before the deadline.
            }
        }
        defer { timeoutTask.cancel() }

        while let line = await pump.next() {
            let message: RPCEnvelope
            do {
                message = try decoder.decode(RPCEnvelope.self, from: line)
            } catch {
                throw CodexRPCError.malformedResponse
            }
            if predicate(message) {
                if let error = message.error {
                    throw CodexRPCError.remoteError(code: error.code, message: error.message)
                }
                return message
            }
            // Login completion can arrive before the login/start response.
            if message.method == "account/login/completed", message.id == nil {
                pendingNotifications.append(message)
                if pendingNotifications.count > 16 { pendingNotifications.removeFirst() }
            }
        }
        if didTimeout { throw CodexRPCError.timeout }
        let details = await stderrDrain.finishedMessage()
        if didTimeout { throw CodexRPCError.timeout }
        if !details.isEmpty { throw CodexRPCError.connectionClosedWithDetails(details) }
        throw CodexRPCError.connectionClosed
    }

    private func triggerTimeout() async {
        didTimeout = true
        await stop()
    }

    private func send(_ object: [String: Any]) throws {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw CodexRPCError.malformedResponse
        }
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        try input.write(contentsOf: data)
    }
}
