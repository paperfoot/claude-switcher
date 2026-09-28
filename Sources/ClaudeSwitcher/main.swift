import AppKit
import ClaudeSwitcherCore

private let usageText = """
claude-switcher — open Claude accounts from the menu bar.

USAGE
  claude-switcher             Run the menu bar app.
  claude-switcher --accounts  Print verified Claude Code account summaries as JSON.
  claude-switcher --switch EMAIL  Select an account for Chrome and ordinary Claude Code.
  claude-switcher --switch-status Print coordinated account state as JSON.
  claude-switcher --usage     Fetch verified usage percentages and reset times as JSON.
  claude-switcher --codex-accounts Print saved Codex account status and usage.
  claude-switcher --codex-connect EMAIL  Save a Codex login through the browser.
  claude-switcher --codex-switch EMAIL  Select an account and reopen Codex.
  claude-switcher --dry-run   Print Desktop launch plans without launching anything.
  claude-switcher --help      Show this message.

After coordinated setup, click an email to select it for Chrome and the next Claude Code launch.
Tiny gauges show usage consumed, with exact reset times from Anthropic.
Desktop profiles and their local usage history are available in the Desktop submenu.
Desktop and terminal sign-ins are separate.

CONFIG
  \(Config.configURL.path)
"""

private func readAccounts(_ config: Config) -> [String: AccountStatus] {
    let executable = Diagnostics.locateOnSearchPath("claude")
    return Dictionary(uniqueKeysWithValues: config.profiles.map {
        ($0.id, AccountStatusReader.read(profile: $0, executable: executable))
    })
}

/// Emit only identity fields from the official CLI, never its raw output.
private func runAccounts() -> Int32 {
    do {
        let config = try Config.load()
        if let setup = CoordinatedSetup.load(), setup.enabled {
            let snapshot = try CoordinatedSwitching.snapshot(setup: setup)
            let rows: [[String: Any]] = snapshot.accounts.map { account in
                ["email": account.email, "state": "saved", "active": account.email == snapshot.codeEmail,
                 "usageStatus": account.usageStatus, "chromeActive": account.email == snapshot.browser.email]
            }
            FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]))
            print(); return 0
        }
        let statuses = readAccounts(config)
        let rows: [[String: Any]] = config.profiles.map { profile in
            let status = statuses[profile.id] ?? .unavailable
            let presentation = AccountPresentation(profile: profile, status: status)
            var row: [String: Any] = ["id": profile.id, "title": presentation.title,
                                       "matchesExpectedAccount": status.matches(profile.expectedEmail)]
            row["expectedEmail"] = profile.expectedEmail
            row["email"] = status.email
            row["badge"] = presentation.badge
            switch status {
            case .signedIn(_, let plan): row["state"] = "signedIn"; row["plan"] = plan
            case .signedOut: row["state"] = "signedOut"
            case .unavailable: row["state"] = "unavailable"
            }
            return row
        }
        let data = try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
        FileHandle.standardOutput.write(data)
        print()
        return 0
    } catch {
        FileHandle.standardError.write(Data("Could not read accounts: \(error.localizedDescription)\n".utf8))
        return 1
    }
}

private func runUsage() async -> Int32 {
    do {
        let config = try Config.load()
        let statuses = readAccounts(config)
        var rows: [[String: Any]] = []
        var succeeded = true
        for profile in config.profiles {
            guard let status = statuses[profile.id], status.matches(profile.expectedEmail), let email = status.email else {
                rows.append(["id": profile.id, "state": "signInRequired"])
                succeeded = false
                continue
            }
            do {
                let snapshot = try LiveUsageReader.read(profile: profile, email: email, executable: Diagnostics.locateOnSearchPath("claude"))
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                var row = try JSONSerialization.jsonObject(with: encoder.encode(snapshot)) as! [String: Any]
                row["id"] = profile.id
                row["state"] = "available"
                rows.append(row)
            } catch {
                rows.append(["id": profile.id, "email": email, "state": "unavailable"])
                succeeded = false
            }
        }
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]))
        print()
        return succeeded ? 0 : 1
    } catch {
        FileHandle.standardError.write(Data("Could not read usage settings.\n".utf8))
        return 1
    }
}

/// Prints the launch plan without touching anything. Returns the process exit code.
private func runDryRun() -> Int32 {
    let config: Config
    do {
        config = try Config.load()
    } catch {
        FileHandle.standardError.write(Data("""
        claude-switcher: cannot read \(Config.configURL.path)
          \(error.localizedDescription)

        """.utf8))
        return 1
    }
    // Read-only: enumerates running processes so the plan can say what is already up.
    let running = InstanceManager.runningInstances(appPath: config.claudeAppPath)
    let update = UpdateProbe.status(appPath: config.claudeAppPath)
    let now = Date()
    var usage: [String: UsageReading] = [:]
    var updateAttempts: [String: UpdateAttempt] = [:]
    var updateBlocks: [String: UpdateBlock.State] = [:]
    for profile in config.profiles {
        updateAttempts[profile.id] = UpdateAttemptMarker.read(userDataDir: profile.userDataDir)
        updateBlocks[profile.id] = UpdateBlock.state(userDataDir: profile.userDataDir)
        if let samples = UsageHistory.read(userDataDir: profile.userDataDir),
           let reading = UsageReading.make(samples: samples, now: now) {
            usage[profile.id] = reading
        }
    }
    print(Diagnostics.launchPlan(config: config, running: running, update: update, usage: usage,
                                 updateAttempts: updateAttempts, updateBlocks: updateBlocks, now: now))
    return 0
}

let commandLineArguments = CommandLine.arguments.dropFirst()

if commandLineArguments.contains("--help") || commandLineArguments.contains("-h") {
    print(usageText)
    exit(0)
}

if let index = commandLineArguments.firstIndex(of: "--switch"),
   commandLineArguments.index(after: index) < commandLineArguments.endIndex {
    guard let setup = CoordinatedSetup.load(), setup.enabled else {
        FileHandle.standardError.write(Data("Set up coordinated switching first.\n".utf8)); exit(1)
    }
    let email = commandLineArguments[commandLineArguments.index(after: index)]
    do {
        let result = try CoordinatedSwitching.select(email: email, setup: setup)
        let output: [String: Any] = ["ok": result.ok, "codeEmail": result.codeEmail ?? "",
                                     "browserReady": result.browserReady ?? false, "message": result.summary]
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted]))
        print(); exit(result.ok ? 0 : 1)
    } catch { FileHandle.standardError.write(Data("Switch failed.\n".utf8)); exit(1) }
}

if commandLineArguments.contains("--switch-status"), let setup = CoordinatedSetup.load() {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: setup.python)
    process.arguments = [setup.helper, "snapshot"]
    do { try process.run(); process.waitUntilExit(); exit(process.terminationStatus) }
    catch { exit(1) }
}

if commandLineArguments.contains("--accounts") {
    exit(runAccounts())
}

if commandLineArguments.contains("--usage") {
    Task { exit(await runUsage()) }
    dispatchMain()
}

if commandLineArguments.contains("--dry-run") {
    exit(runDryRun())
}

if commandLineArguments.contains("--codex-accounts") || commandLineArguments.contains("--codex-connect") || commandLineArguments.contains("--codex-switch") {
    Task { @MainActor in
        do {
            guard let runtime = CodexRuntime.installed() else { throw CodexSwitchError.unavailable }
            let config = try Config.load()
            let settings = CodexAccountSettings.load(fallbackEmails: config.profiles.compactMap(\.expectedEmail))
            let service = CodexAccountService(emails: settings.emails, aliases: settings.aliases, runtime: runtime)
            let result: [CodexAccount]
            if let index = commandLineArguments.firstIndex(of: "--codex-connect"), commandLineArguments.index(after: index) < commandLineArguments.endIndex {
                result = try await service.connect(email: commandLineArguments[commandLineArguments.index(after: index)]) { url in
                    guard await MainActor.run(body: { NSWorkspace.shared.open(url) }) else { throw CodexSwitchError.unavailable }
                }
            } else if let index = commandLineArguments.firstIndex(of: "--codex-switch"), commandLineArguments.index(after: index) < commandLineArguments.endIndex {
                result = try await service.select(email: commandLineArguments[commandLineArguments.index(after: index)], desktop: CodexDesktop())
            } else {
                result = try await service.refresh(usage: !commandLineArguments.contains("--cached"))
            }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
            FileHandle.standardOutput.write(try encoder.encode(result)); print(); exit(0)
        } catch {
            if case let CodexSwitchError.keychainStatus(status) = error {
                FileHandle.standardError.write(Data("Keychain status: \(status)\n".utf8))
            }
            let text = (error as? CodexSwitchError)?.errorDescription ?? "Codex could not connect."
            FileHandle.standardError.write(Data((text + "\n").utf8)); exit(1)
        }
    }
    dispatchMain()
}

// AppDelegate is @MainActor-isolated. Top-level code in main.swift is a synchronous
// *nonisolated* context, so constructing it directly is a compile error. The process is
// single-threaded at this point and this is by definition the main thread, so asserting
// the isolation we already have is both correct and the narrowest fix.
MainActor.assumeIsolated {
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)   // menu bar only: no Dock tile, no main window
    let appDelegate = AppDelegate()
    application.delegate = appDelegate
    application.run()
}
