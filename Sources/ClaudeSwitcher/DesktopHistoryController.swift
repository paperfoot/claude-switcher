import AppKit
import ClaudeSwitcherCore

@MainActor
final class DesktopHistoryController {
    private var timer: Timer?
    private var handledIdentity: String?
    private var failedIdentity: String?
    private var checking = false
    private var lastFailure: Date = .distantPast
    private let changed: @MainActor () -> Void
    private let isAvailable: @MainActor () -> Bool
    private let configuration: @MainActor () -> Config
    private(set) var busy = false
    private(set) var message: String?
    var enabled: Bool { UserDefaults.standard.bool(forKey: "shareClaudeCodeHistory") }

    init(configuration: @escaping @MainActor () -> Config,
         isAvailable: @escaping @MainActor () -> Bool, changed: @escaping @MainActor () -> Void) {
        self.configuration = configuration; self.isAvailable = isAvailable; self.changed = changed
    }

    func start() {
        timer?.invalidate()
        let timer = Timer(timeInterval: 12, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer.tolerance = 3
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        refresh()
    }

    func toggle() {
        UserDefaults.standard.set(!enabled, forKey: "shareClaudeCodeHistory")
        handledIdentity = nil
        failedIdentity = nil
        message = nil
        changed()
        if enabled { refresh(force: true) }
    }

    func refresh(force: Bool = false) {
        guard (enabled || force), !busy, !checking, isAvailable(),
              force || Date().timeIntervalSince(lastFailure) > 30 else { return }
        guard let runtime = DesktopHistoryRuntime.installed() else {
            message = "Install Node.js 22 to share Code history"; changed(); return
        }
        let config = configuration()
        let instances = InstanceManager.runningInstances(appPath: config.claudeAppPath)
        guard instances.count == 1, let instance = instances.first,
              instance.profile != .unknown,
              let app = NSRunningApplication(processIdentifier: instance.pid),
              let started = app.launchDate else { return }
        let root = instance.userDataDir ?? NSHomeDirectory() + "/Library/Application Support/Claude"
        let arguments = [root, String(instance.pid), String(started.timeIntervalSince1970 * 1000)]
        checking = true
        Task {
            defer { checking = false; busy = false; changed() }
            do {
                let probe = try await Task.detached { try runtime.request("probe", arguments: arguments) }.value
                guard probe.ok, let identity = probe.identity else { fail(probe.message); return }
                guard isAvailable(), force || (identity.key != handledIdentity && identity.key != failedIdentity) else { return }
                busy = true
                let prepared = try await Task.detached { try runtime.request("prepare", arguments: arguments) }.value
                guard prepared.ok, let token = prepared.token else { fail(prepared.message); return }
                guard (prepared.count ?? 0) > 0 else {
                    handledIdentity = identity.key
                    message = (prepared.unavailable ?? 0) > 0 ? "Code history ready · \(prepared.unavailable!) unavailable" : nil
                    return
                }
                // New activity after planning invalidates the helper's final inventory.
                // Normal quit lets Claude flush its own records and veto the restart.
                message = "Updating Code history…"; changed()
                failedIdentity = identity.key
                guard let bundleID = InstanceManager.bundleIdentifier(appPath: config.claudeAppPath),
                      InstanceManager.terminate(pid: instance.pid, expecting: bundleID) else {
                    fail("Claude could not close · history unchanged"); return
                }
                let deadline = ContinuousClock.now.advanced(by: .seconds(20))
                while !app.isTerminated && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(150)) }
                guard app.isTerminated else { fail("Claude is still open · history unchanged"); return }
                let profile = config.profiles.first(where: { InstanceManager.binding(for: $0) == instance.profile })
                    ?? Profile(id: "history-current", label: "Claude", userDataDir: instance.userDataDir)
                do {
                    let applied = try await Task.detached { try runtime.request("apply", arguments: [token]) }.value
                    if applied.ok { handledIdentity = identity.key; failedIdentity = nil; message = applied.message }
                    else { fail(applied.message) }
                } catch { fail("History sync stopped · previous records kept") }
                await reopen(profile, appPath: config.claudeAppPath)
            } catch { fail("History could not be checked · try again") }
        }
    }

    func undoLastMove() {
        guard !busy, isAvailable(), let runtime = DesktopHistoryRuntime.installed() else { return }
        let config = configuration()
        guard InstanceManager.runningInstances(appPath: config.claudeAppPath).isEmpty else {
            message = "Quit Claude Desktop before undoing history"; changed(); return
        }
        busy = true
        Task {
            defer { busy = false; changed() }
            do {
                let result = try await Task.detached { try runtime.request("undo") }.value
                if result.ok {
                    UserDefaults.standard.set(false, forKey: "shareClaudeCodeHistory")
                    handledIdentity = nil; message = "History restored · automatic sharing off"
                } else { fail(result.message) }
            } catch { fail("History could not be restored") }
        }
    }

    private func fail(_ text: String) { message = text; lastFailure = Date() }

    private func reopen(_ profile: Profile, appPath: String) async {
        await withCheckedContinuation { continuation in
            InstanceManager.launch(profile: profile, appPath: appPath) { result in
                Task { @MainActor in
                    if case .failure = result { self.message = "History saved · open Claude Desktop" }
                    continuation.resume()
                }
            }
        }
    }
}
