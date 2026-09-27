import Foundation
import Testing
@testable import ClaudeSwitcherCore

private func makeTemporaryDirectory(_ suffix: String = "") throws -> URL {
    let name = "claude-switcher-account-status-\(UUID().uuidString)\(suffix)"
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func makeExecutable(in directory: URL, name: String = "fake-claude", body: String) throws -> URL {
    let executable = directory.appendingPathComponent(name, isDirectory: false)
    let script = "#!/bin/sh\n\(body)\n"
    try Data(script.utf8).write(to: executable, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    return executable
}

private func shellLiteral(_ value: String) -> String {
    "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
}

struct AccountStatusTests {
    @Test("Official Claude Code account JSON preserves email and plan")
    func decodesSignedInAccount() {
        let json = Data(#"{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","email":"person@example.com","orgName":"Example","orgId":"org_123","subscriptionType":"max"}"#.utf8)

        #expect(AccountStatus.decode(json) == .signedIn(email: "person@example.com", plan: "max"))
    }

    @Test("Signed-out JSON is a valid account result")
    func decodesSignedOutAccount() {
        let json = Data(#"{"loggedIn":false,"authMethod":"none","apiProvider":"firstParty"}"#.utf8)

        #expect(AccountStatus.decode(json) == .signedOut)
    }

    @Test("Malformed account JSON is unavailable")
    func rejectsMalformedJSON() {
        #expect(AccountStatus.decode(Data(#"{"loggedIn":"yes"}"#.utf8)) == .unavailable)
        #expect(AccountStatus.decode(Data("not-json".utf8)) == .unavailable)
    }

    @Test("API authentication cannot reuse a stale Claude subscription email")
    func removesEmailForAPIAuthentication() {
        let json = Data(#"{"loggedIn":true,"authMethod":"apiKey","email":"stale@example.com","subscriptionType":"api"}"#.utf8)

        #expect(AccountStatus.decode(json) == .signedIn(email: nil, plan: "api"))
    }

    @Test("Blank subscription email is normalized to nil")
    func normalizesBlankEmail() {
        let json = Data(#"{"loggedIn":true,"authMethod":"claude.ai","email":"  \n ","subscriptionType":"max"}"#.utf8)

        #expect(AccountStatus.decode(json) == .signedIn(email: nil, plan: "max"))
    }

    @Test("Expected email matching ignores letter case")
    func matchesExpectedEmailCaseInsensitively() {
        let status = AccountStatus.signedIn(email: "Person@Example.COM", plan: "max")

        #expect(status.matches("person@example.com"))
        #expect(status.matches("other@example.com") == false)
    }

    @Test("Mismatched identity asks for sign-in and explains the reported account")
    func presentsMismatchClearly() {
        let profile = Profile(id: "work", label: "Work", expectedEmail: "wanted@example.com")
        let presentation = AccountPresentation(
            profile: profile,
            status: .signedIn(email: "reported@example.com", plan: "max")
        )

        #expect(presentation.title == "wanted@example.com")
        #expect(presentation.badge == "Sign in")
        #expect(presentation.help.contains("reported@example.com"))
        #expect(presentation.help.contains("wanted@example.com"))
    }

    @Test("Loading and failed checks remain visibly distinct")
    func distinguishesLoadingFromUnavailable() {
        let profile = Profile(id: "work", label: "Work", expectedEmail: "person@example.com")
        let loading = AccountPresentation(profile: profile, status: nil)
        let unavailable = AccountPresentation(profile: profile, status: .unavailable)

        #expect(loading.badge == "Checking…")
        #expect(unavailable.badge == "Check failed")
        #expect(loading.badge != unavailable.badge)
        #expect(loading.help != unavailable.help)
    }

    @Test("Reader accepts the CLI's exit-one signed-out response")
    func readerAcceptsSignedOutExitCode() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = try makeExecutable(
            in: directory,
            body: #"/usr/bin/printf '%s' '{"loggedIn":false,"authMethod":"none"}'; exit 1"#
        )

        let status = AccountStatusReader.read(
            profile: Profile(id: "signed-out", label: "Signed out", credDir: directory.path),
            executable: executable.path,
            timeout: 1,
            baseEnvironment: [:]
        )

        #expect(status == .signedOut)
    }

    @Test("Reader rejects error exits even if they print plausible JSON")
    func readerRejectsOtherNonzeroExit() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = try makeExecutable(
            in: directory,
            body: #"/usr/bin/printf '%s' '{"loggedIn":true,"authMethod":"claude.ai","email":"wrong@example.com"}'; exit 2"#
        )

        let status = AccountStatusReader.read(
            profile: Profile(id: "error", label: "Error", credDir: directory.path),
            executable: executable.path,
            timeout: 1,
            baseEnvironment: [:]
        )

        #expect(status == .unavailable)
    }

    @Test("Reader timeout is bounded and terminates only its own executable")
    func readerTimeoutIsBounded() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = try makeExecutable(in: directory, body: "exec /bin/sleep 2")
        let started = Date()

        let status = AccountStatusReader.read(
            profile: Profile(id: "slow", label: "Slow", credDir: directory.path),
            executable: executable.path,
            timeout: 0.05,
            baseEnvironment: [:]
        )
        let elapsed = Date().timeIntervalSince(started)

        #expect(status == .unavailable)
        #expect(elapsed >= 0.04)
        #expect(elapsed < 1.5, "The timeout path should not wait for the two-second fake executable.")
    }

    @Test("Reader binds both profile directories and clears inherited account selectors")
    func readerUsesIsolatedEnvironment() throws {
        let directory = try makeTemporaryDirectory(" environment")
        defer { try? FileManager.default.removeItem(at: directory) }
        let credentialDirectory = directory.appendingPathComponent("credential profile", isDirectory: true).path
        let clearedChecks = LaunchPlanning.accountEnvironmentKeys
            .filter { $0 != "CLAUDE_CONFIG_DIR" && $0 != "CLAUDE_SECURESTORAGE_CONFIG_DIR" }
            .map { "test -z \"${\($0)+x}\" || exit 9" }
            .joined(separator: "\n")
        let body = """
        test "$CLAUDE_CONFIG_DIR" = \(shellLiteral(credentialDirectory)) || exit 7
        test "$CLAUDE_SECURESTORAGE_CONFIG_DIR" = \(shellLiteral(credentialDirectory)) || exit 8
        \(clearedChecks)
        test "$KEEP_ME" = "preserved" || exit 10
        /usr/bin/printf '%s' '{"loggedIn":true,"authMethod":"claude.ai","email":"isolated@example.com","subscriptionType":"max"}'
        """
        let executable = try makeExecutable(in: directory, body: body)
        var inherited = Dictionary(
            uniqueKeysWithValues: LaunchPlanning.accountEnvironmentKeys.map { ($0, "inherited") }
        )
        inherited["KEEP_ME"] = "preserved"

        let status = AccountStatusReader.read(
            profile: Profile(id: "isolated", label: "Isolated", credDir: credentialDirectory),
            executable: executable.path,
            timeout: 1,
            baseEnvironment: inherited
        )

        #expect(status == .signedIn(email: "isolated@example.com", plan: "max"))
    }

    @Test("Sign-in document passes the email literally and performs no Code launch")
    func signInDocumentRunsOnlyLogin() throws {
        let directory = try makeTemporaryDirectory(" launcher")
        defer { try? FileManager.default.removeItem(at: directory) }
        let capture = directory.appendingPathComponent("captured arguments.txt", isDirectory: false)
        let executable = try makeExecutable(
            in: directory,
            name: "fake claude",
            body: """
            {
              /usr/bin/printf '%s\n' "$#"
              /usr/bin/printf '%s\n' "$@"
            } >> \(shellLiteral(capture.path))
            """
        )
        let expectedEmail = #"literal+$HOME;`touch BAD`;$(touch BAD);*?&"quote"@example.com"#
        let profile = Profile(
            id: "sign-in",
            label: "Sign in",
            credDir: directory.appendingPathComponent("credentials", isDirectory: true).path,
            expectedEmail: expectedEmail
        )
        let commandFile = try TerminalLauncher.write(
            profile: profile,
            executable: executable.path,
            directory: directory.appendingPathComponent("commands", isDirectory: true),
            signIn: true
        )
        let process = Process()
        process.executableURL = commandFile
        process.environment = ["HOME": directory.path, "PATH": "/usr/bin:/bin"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()

        #expect(process.terminationStatus == 0)
        let arguments = try String(contentsOf: capture, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .dropLast()
            .map(String.init)
        #expect(arguments == ["5", "auth", "login", "--claudeai", "--email", expectedEmail])
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("BAD").path) == false)
    }
}
