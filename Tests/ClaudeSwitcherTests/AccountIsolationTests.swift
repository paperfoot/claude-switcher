import Foundation
import XCTest
@testable import ClaudeSwitcherCore

final class AccountIsolationTests: XCTestCase {
    private func environment(from command: String) throws -> [String: String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = Dictionary(uniqueKeysWithValues:
            LaunchPlanning.accountEnvironmentKeys.map { ($0, "DUMMY-INHERITED") })
        process.environment?["PATH"] = "/usr/bin:/bin"
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return Dictionary(uniqueKeysWithValues: String(decoding: data, as: UTF8.self)
            .split(separator: "\n").compactMap { line in
                let pair = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                return pair.count == 2 ? (String(pair[0]), String(pair[1])) : nil
            })
    }

    func testDefaultLaunchActuallyClearsEveryInheritedAccountSelector() throws {
        let profile = Profile(id: "default", label: "Current")
        let result = try environment(from: LaunchPlanning.terminalCommand(for: profile, executable: "/usr/bin/env"))
        for key in LaunchPlanning.accountEnvironmentKeys { XCTAssertNil(result[key], key) }
    }

    func testNamedLaunchKeepsCredentialsAndMetadataTogether() throws {
        let directory = "/tmp/Account $HOME `echo BAD` $(echo BAD) \"quoted\""
        let profile = Profile(id: "second", label: "Second", credDir: directory)
        let result = try environment(from: LaunchPlanning.terminalCommand(for: profile, executable: "/usr/bin/env"))
        XCTAssertEqual(result["CLAUDE_CONFIG_DIR"], directory)
        XCTAssertEqual(result["CLAUDE_SECURESTORAGE_CONFIG_DIR"], directory)
        for key in LaunchPlanning.accountEnvironmentKeys where !key.hasSuffix("CONFIG_DIR") {
            XCTAssertNil(result[key], key)
        }
    }

    func testDesktopDirectoryAliasesCannotCreateAnotherAccount() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("real"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("alias"), withDestinationURL: root.appendingPathComponent("real"))
        var config = Config.defaultConfig()
        try config.addProfile(Profile(id: "one", label: "One", userDataDir: root.appendingPathComponent("real").path))
        for suffix in ["real/.", "alias", "real/../real"] {
            let profile = Profile(id: "two", label: "Two", userDataDir: root.appendingPathComponent(suffix).path)
            XCTAssertThrowsError(try config.addProfile(profile), suffix)
            var handEdited = config
            handEdited.profiles.append(profile)
            XCTAssertThrowsError(try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(handEdited)), suffix)
        }
    }

    func testReservedDirectoryAliasesAreRejected() {
        for directory in ["~/.claude/.", "~/Library/Application Support/Claude/../Claude", "~/."] {
            var config = Config.defaultConfig()
            XCTAssertThrowsError(try config.addProfile(Profile(id: "bad", label: "Bad", userDataDir: directory)))
        }
    }

    func testTerminalDirectoryAliasesCannotShareAccountMetadata() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("one"), withIntermediateDirectories: true)
        var config = Config.defaultConfig()
        try config.addProfile(Profile(id: "one", label: "One", userDataDir: root.appendingPathComponent("desktop-one").path,
                                      credDir: root.appendingPathComponent("one").path))
        XCTAssertThrowsError(try config.addProfile(Profile(id: "two", label: "Two", userDataDir: root.appendingPathComponent("desktop-two").path,
                                                          credDir: root.appendingPathComponent("one/.").path)))
        XCTAssertThrowsError(try config.addProfile(Profile(id: "three", label: "Three", userDataDir: root.appendingPathComponent("desktop-three").path,
                                                          credDir: "~/.claude/.")))
    }

    func testTerminalDocumentHasPrivatePermissionsAndSafeFilename() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = Profile(id: "../../escape", label: "A\n$(echo bad)", credDir: root.appendingPathComponent("account").path)
        let file = try TerminalLauncher.write(profile: profile, executable: "/usr/bin/env", directory: root)
        XCTAssertEqual(file.deletingLastPathComponent().path, root.path)
        XCTAssertEqual(file.pathExtension, "command")
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o700)
        XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).hasPrefix("#!/bin/zsh\n"))
    }
}
