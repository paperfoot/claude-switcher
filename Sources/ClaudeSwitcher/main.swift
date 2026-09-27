import AppKit
import ClaudeSwitcherCore

private let usageText = """
claude-switcher — open Claude accounts from the menu bar.

USAGE
  claude-switcher             Run the menu bar app.
  claude-switcher --accounts  Print verified Claude Code account summaries as JSON.
  claude-switcher --usage     Fetch verified usage percentages and reset times as JSON.
  claude-switcher --dry-run   Print Desktop launch plans without launching anything.
  claude-switcher --help      Show this message.

Click an email to open Claude Code. A Sign in badge means that account needs a login.
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
