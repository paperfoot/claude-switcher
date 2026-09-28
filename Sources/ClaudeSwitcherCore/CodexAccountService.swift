import Foundation
import Darwin

public actor CodexAccountService {
    private let files: CodexAccountFiles
    private let vault: any CodexCredentialVault
    private let runtime: any CodexAccountVerifying
    private var accounts: [CodexAccount]
    private var busy = false
    public init(emails: [String], aliases: [String: String] = [:], files: CodexAccountFiles = .init(),
                vault: any CodexCredentialVault = CodexKeychainVault(), runtime: any CodexAccountVerifying) {
        self.files = files; self.vault = vault; self.runtime = runtime
        accounts = files.loadCache(emails: emails, aliases: aliases)
    }
    public func snapshot() -> [CodexAccount] { accounts }

    private func begin() throws -> Int32 {
        guard !busy, let lock = AutomationLock.acquire(at: files.lockURL) else { throw CodexSwitchError.busy }
        busy = true
        return lock
    }
    private func finish(_ lock: Int32) { busy = false; AutomationLock.release(lock) }
    private func persist() { try? files.saveCache(accounts) }
    private func markActive(_ email: String?) {
        for index in accounts.indices { accounts[index].active = accounts[index].identityEmail == email }
    }
    private func record(_ credential: CodexCredential, reading: LiveUsageSnapshot? = nil) throws {
        try vault.save(credential.data, email: credential.email)
        if let index = accounts.firstIndex(where: { $0.identityEmail == credential.email }) {
            accounts[index].connected = true
            if let reading { accounts[index].usage = reading; accounts[index].usageFailed = false }
        }
    }
    private func isolatedHome(credential: CodexCredential? = nil) throws -> URL {
        let home = files.directory.appendingPathComponent("codex-temporary-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do {
            try CodexAccountFiles.writePrivate(Data("cli_auth_credentials_store = \"file\"\n".utf8), to: home.appendingPathComponent("config.toml"))
            if let credential { try CodexAccountFiles.writePrivate(credential.data, to: home.appendingPathComponent("auth.json")) }
        } catch { try? FileManager.default.removeItem(at: home); throw error }
        return home
    }
    private func saved(_ email: String) throws -> CodexCredential {
        guard let data = try vault.load(email: email) else { throw CodexSwitchError.signIn }
        let credential = try CodexCredential(data: data)
        guard credential.email == email else { throw CodexSwitchError.wrongAccount }
        return credential
    }
    private func inspectSaved(_ email: String, usage: Bool) async throws -> (CodexCredential, LiveUsageSnapshot?) {
        let original = try saved(email)
        let home = try isolatedHome(credential: original)
        defer { try? FileManager.default.removeItem(at: home) }
        do {
            let result = try await runtime.inspect(home: home, usage: usage)
            guard result.0.email == email, result.0.accountID == original.accountID else { throw CodexSwitchError.wrongAccount }
            try record(result.0, reading: result.1)
            return result
        } catch {
            // Refresh can succeed before a usage request fails. Keep rotated credentials.
            if let data = try? Data(contentsOf: home.appendingPathComponent("auth.json")),
               let refreshed = try? CodexCredential(data: data), refreshed.email == email, refreshed.accountID == original.accountID {
                try record(refreshed)
            }
            throw error
        }
    }

    /// Cache the live credential and inspect saved records. Network work is optional and bounded.
    public func refresh(usage: Bool = true) async throws -> [CodexAccount] {
        let lock = try begin(); defer { finish(lock); persist() }
        let active = try files.readActive()
        if let active { try record(active) }
        markActive(active?.email)
        for index in accounts.indices {
            try Task.checkCancellation()
            let email = accounts[index].identityEmail
            accounts[index].connected = try vault.load(email: email) != nil
            guard usage, accounts[index].connected else { continue }
            let old = accounts[index].usage
            if let old, !accounts[index].usageFailed, Date() < LiveUsagePolicy.nextRefresh(for: old, now: Date()) { continue }
            do {
                if email == active?.email {
                    // The live home shares Codex's own refresh state; never refresh a copied active token.
                    let value = try await runtime.inspect(home: files.home, usage: true)
                    guard value.0.email == email, value.0.accountID == active?.accountID else { throw CodexSwitchError.changed }
                    try record(value.0, reading: value.1)
                } else { _ = try await inspectSaved(email, usage: true) }
                accounts[index].usageFailed = false
            } catch { accounts[index].usageFailed = true }
        }
        let latest = try files.readActive()
        markActive(latest?.email)
        if let latest { try record(latest) }
        return accounts
    }

    public func connect(email: String, openURL: @escaping @Sendable (URL) async throws -> Void) async throws -> [CodexAccount] {
        guard let account = accounts.first(where: { $0.email == email.lowercased() }) else { throw CodexSwitchError.wrongAccount }
        let email = account.identityEmail
        let lock = try begin(); defer { finish(lock); persist() }
        let home = try isolatedHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let credential = try await runtime.login(home: home, openURL: openURL)
        try Task.checkCancellation()
        guard credential.email == email else { throw CodexSwitchError.wrongAccount }
        try record(credential)
        do {
            let value = try await runtime.inspect(home: home, usage: true)
            guard value.0.email == email, value.0.accountID == credential.accountID else { throw CodexSwitchError.wrongAccount }
            try record(value.0, reading: value.1)
        } catch {
            if let data = try? Data(contentsOf: home.appendingPathComponent("auth.json")),
               let rotated = try? CodexCredential(data: data), rotated.email == email, rotated.accountID == credential.accountID {
                try record(rotated)
            }
        }
        return accounts
    }

    public func select(email: String, desktop: any CodexDesktopControlling) async throws -> [CodexAccount] {
        guard let account = accounts.first(where: { $0.email == email.lowercased() }) else { throw CodexSwitchError.wrongAccount }
        let email = account.identityEmail
        let lock = try begin(); defer { finish(lock); persist() }
        let before = try files.readActive()
        if let before { try record(before) }
        if before?.email == email {
            markActive(email)
            return accounts
        }
        // An invalid or expired target must never close a working desktop.
        let target = try await inspectSaved(email, usage: true).0
        try Task.checkCancellation()
        let wasRunning = try await desktop.close()
        var installed = false
        var original: CodexCredential?
        do {
            original = try files.readActive()
            guard original?.email == before?.email, original?.accountID == before?.accountID else { throw CodexSwitchError.changed }
            if let original { try record(original) }
            try Task.checkCancellation()
            // Refuse to overwrite a login changed by another process after the snapshot.
            guard try files.readActive()?.data == original?.data else { throw CodexSwitchError.changed }
            try CodexAccountFiles.writePrivate(target.data, to: files.authURL)
            installed = true
            let verified = try await runtime.inspect(home: files.home, usage: true)
            guard verified.0.email == email, verified.0.accountID == target.accountID else { throw CodexSwitchError.wrongAccount }
            try record(verified.0, reading: verified.1)
            markActive(email)
        } catch {
            if installed {
                do {
                    let current = try files.readActive()
                    guard current?.email == target.email, current?.accountID == target.accountID else { throw CodexSwitchError.changed }
                    if let original { try CodexAccountFiles.writePrivate(original.data, to: files.authURL) }
                    else if FileManager.default.fileExists(atPath: files.authURL.path) { try FileManager.default.removeItem(at: files.authURL) }
                    markActive(original?.email)
                } catch {
                    if wasRunning { try? await desktop.open() }
                    throw CodexSwitchError.restoreFailed
                }
            }
            if wasRunning { try? await desktop.open() }
            throw error
        }
        // Once committed, a launch failure must leave the truthful selected-account marker.
        do { try await desktop.open() }
        catch { throw CodexSwitchError.reopenFailed }
        return accounts
    }
}
