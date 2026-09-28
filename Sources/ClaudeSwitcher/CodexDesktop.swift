import AppKit
import ClaudeSwitcherCore

struct CodexDesktop: CodexDesktopControlling {
    @MainActor private var applications: [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex")
    }
    @MainActor func close() async throws -> Bool {
        let running = applications
        guard !running.isEmpty else { return false }
        // Let Codex flush history and present its own active-work dialog. Never force quit.
        for application in running where !application.isTerminated {
            guard application.terminate() || application.isTerminated else { throw CodexSwitchError.quitBlocked }
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while applications.contains(where: { !$0.isTerminated }) {
            guard ContinuousClock.now < deadline else { throw CodexSwitchError.quitBlocked }
            try await Task.sleep(for: .milliseconds(100))
        }
        return true
    }
    @MainActor func open() async throws {
        let workspace = NSWorkspace.shared
        guard let url = workspace.urlForApplication(withBundleIdentifier: "com.openai.codex") else { throw CodexSwitchError.reopenFailed }
        let options = NSWorkspace.OpenConfiguration()
        options.activates = true
        do { _ = try await workspace.openApplication(at: url, configuration: options) }
        catch { throw CodexSwitchError.reopenFailed }
    }
}
