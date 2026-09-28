import AppKit
import ClaudeSwitcherCore

/// Builds the status-item menu from a snapshot of state. Side-effect free: it reads the
/// values handed to it (including cached account identities) and never
/// performs I/O, so opening the menu can never block on a `security` call or a subprocess.
@MainActor
enum MenuBuilder {

    // MARK: - Inputs

    struct Actions: Sendable {
        var selectProfile: Selector
        var copyTerminalCommand: Selector
        var openTerminal: Selector
        var selectCodexAccount: Selector
        var cancelCodexLogin: Selector
        var switchAccount: Selector
        var setupSwitching: Selector
        var addProfile: Selector
        var renameProfile: Selector
        var removeProfile: Selector
        var chooseClaudeApp: Selector
        var revealSharedDirectory: Selector
        var showDiagnostics: Selector
        var toggleLaunchAtLogin: Selector
        var toggleReopenAfterUpdate: Selector
        var toggleBlockUpdates: Selector
        var installUpdate: Selector
        var quit: Selector
    }

    struct Input {
        var config: Config
        var running: [RunningInstance]
        /// Claude Code identities from the official CLI, never Desktop credentials.
        var accountStatuses: [String: AccountStatus]
        var liveUsage: [String: LiveUsageSnapshot] = [:]
        var usageFailures: Set<String> = []
        var isBusy: Bool
        var configError: String?
        var claudeAppExists: Bool
        var launchAtLogin: LoginItemState
        /// A downloaded Claude update whose installer is waiting for every instance to quit.
        /// `nil` when nothing is staged, or when no installer is alive to install it.
        var blockedUpdate: StagedUpdate?
        /// Set for the duration of "Quit All & Install Update…"; replaces the offer with progress.
        var updateProgress: String?
        /// profile id -> the usage Claude Desktop last recorded for it (read before the build).
        var usage: [String: UsageReading] = [:]
        /// The moment the menu is built; readings are judged against it.
        var now: Date = Date()
        /// Set after profiles were reopened automatically; shown once so it is never silent.
        var autoReopenNotice: String?
        var codexAccounts: [CodexAccount] = []
        var codexMessage: String?
        var codexBusy = false
        var codexConnecting = false
        var coordinated = false
        var selectedEmail: String?
        var browserEmail: String?
        var browserConnected = false
        var switching = false
        var switchMessage: String?
    }

    // MARK: - Build

    static func build(_ input: Input, target: AnyObject, actions: Actions) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(informationalItem(input.coordinated ? "Claude" : "Claude Code"))
        if input.configError != nil {
            menu.addItem(informationalItem("Settings could not be loaded"))
        }
        for profile in input.config.profiles {
            let item = actionItem(profile.label, action: input.coordinated ? actions.switchAccount : actions.openTerminal, target: target, profile: profile)
            item.identifier = profileItemIdentifier(profile.id)
            applyAccount(to: item, profile: profile, status: input.accountStatuses[profile.id])
            if input.coordinated {
                item.state = profile.expectedEmail?.caseInsensitiveCompare(input.selectedEmail ?? "") == .orderedSame ? .on : .off
                item.isEnabled = !input.switching && !input.codexBusy
                item.toolTip = "Use this account in Chrome and the next Claude Code session."
            }
            menu.addItem(item)
            menu.addItem(liveUsageItem(profile: profile, status: input.accountStatuses[profile.id],
                                       snapshot: input.liveUsage[profile.id], failed: input.usageFailures.contains(profile.id),
                                       now: input.now))
        }
        if input.coordinated {
            if let message = input.switchMessage { menu.addItem(informationalItem(message)) }
            else if !input.browserConnected || input.browserEmail?.caseInsensitiveCompare(input.selectedEmail ?? "") != .orderedSame {
                menu.addItem(actionItem(input.browserConnected ? "Connect this Chrome account…" : "Connect Chrome…", action: actions.setupSwitching, target: target))
            }
        }
        if !input.codexAccounts.isEmpty {
            menu.addItem(.separator())
            menu.addItem(informationalItem("Codex"))
            for account in input.codexAccounts {
                let item = actionItem(account.email, action: actions.selectCodexAccount, target: target)
                item.representedObject = account.email
                item.identifier = NSUserInterfaceItemIdentifier("codex.account.\(account.email)")
                item.state = account.active ? .on : .off
                item.badge = account.connected ? nil : NSMenuItemBadge(string: "Connect")
                item.isEnabled = !input.codexBusy && !input.switching
                item.toolTip = account.connected ? "Select this Codex account and reopen Codex. New CLI sessions use it too." : "Sign in once to save this Codex account."
                if account.identityEmail != account.email { item.toolTip! += " Codex email: \(account.identityEmail)." }
                menu.addItem(item)
                if account.connected { menu.addItem(codexUsageItem(account, now: input.now)) }
            }
            if let message = input.codexMessage { menu.addItem(informationalItem(message)) }
            if input.codexConnecting {
                menu.addItem(actionItem("Cancel sign-in", action: actions.cancelCodexLogin, target: target))
            }
        }
        menu.addItem(.separator())
        menu.addItem(actionItem(input.coordinated ? "Connect accounts…" : "Add account…", action: input.coordinated ? actions.setupSwitching : actions.addProfile, target: target))

        let desktop = NSMenu()
        desktop.autoenablesItems = false
        desktop.addItem(informationalItem("Desktop has its own sign-ins"))
        if !input.claudeAppExists {
            desktop.addItem(actionItem("Choose Claude.app…", action: actions.chooseClaudeApp, target: target))
        }
        if let progress = input.updateProgress {
            desktop.addItem(informationalItem(progress))
        } else if input.isBusy {
            desktop.addItem(informationalItem("Opening Claude…"))
        }
        for profile in input.config.profiles {
            // Code identity is not evidence of a Desktop login, even for the same profile.
            let title = profile.isDefaultProfile ? "Default desktop" : profile.label
            let item = actionItem(title, action: actions.selectProfile, target: target, profile: profile)
            item.state = ProfileMatching.isRunning(profile, in: input.running) ? .on : .off
            item.isEnabled = !input.isBusy && input.claudeAppExists
            item.toolTip = "Open this Desktop profile. Its account is shown inside Claude."
            desktop.addItem(item)
            if let reading = input.usage[profile.id], !reading.rows.isEmpty {
                desktop.addItem(usageItem(for: profile, reading: reading, now: input.now))
            }
        }
        if let notice = input.autoReopenNotice { desktop.addItem(informationalItem(notice)) }
        if let update = input.blockedUpdate, !input.running.isEmpty, input.updateProgress == nil {
            desktop.addItem(.separator())
            desktop.addItem(actionItem("Install Claude \(update.staged)…", action: actions.installUpdate, target: target))
        }
        menu.addItem(submenuItem("Desktop", menu: desktop))

        let settings = NSMenu()
        settings.autoenablesItems = false
        let login = actionItem("Open at login", action: actions.toggleLaunchAtLogin, target: target)
        switch input.launchAtLogin {
        case .enabled: login.state = .on
        case .disabled: login.state = .off
        case .requiresApproval:
            login.state = .mixed
            login.toolTip = "Allow Claude Switcher in System Settings → General → Login Items."
        case .unavailable: login.isEnabled = false
        }
        settings.addItem(login)

        let commands = NSMenu()
        let rename = NSMenu()
        let remove = NSMenu()
        for submenu in [commands, rename, remove] { submenu.autoenablesItems = false }
        for profile in input.config.profiles {
            let title = input.accountStatuses[profile.id]?.email ?? profile.expectedEmail ?? profile.label
            commands.addItem(actionItem(title, action: actions.copyTerminalCommand, target: target, profile: profile))
            rename.addItem(actionItem(profile.label, action: actions.renameProfile, target: target, profile: profile))
            let item = actionItem(title, action: actions.removeProfile, target: target, profile: profile)
            item.isEnabled = !profile.isDefaultProfile && profile.id != input.config.activeProfileId && !input.isBusy
            item.toolTip = "Remove from this menu. Account data stays on this Mac."
            remove.addItem(item)
        }
        settings.addItem(actionItem("Set up switching…", action: actions.setupSwitching, target: target))
        settings.addItem(submenuItem("Copy terminal command", menu: commands))
        settings.addItem(submenuItem("Rename desktop profile", menu: rename))
        settings.addItem(submenuItem("Remove account", menu: remove))
        if !input.codexAccounts.isEmpty {
            let reconnect = NSMenu()
            reconnect.autoenablesItems = false
            for account in input.codexAccounts {
                let item = actionItem(account.email, action: actions.selectCodexAccount, target: target)
                item.representedObject = account.email
                item.tag = 1
                item.isEnabled = !input.codexBusy && !input.switching
                reconnect.addItem(item)
            }
            settings.addItem(submenuItem("Reconnect Codex account", menu: reconnect))
        }
        settings.addItem(.separator())
        let reopen = actionItem("Reopen desktops after updates", action: actions.toggleReopenAfterUpdate, target: target)
        reopen.state = input.config.reopenAfterUpdate ? .on : .off
        settings.addItem(reopen)
        let block = actionItem("Pause desktop updates…", action: actions.toggleBlockUpdates, target: target)
        block.state = input.config.blockClaudeUpdates ? .on : .off
        settings.addItem(block)
        settings.addItem(actionItem("Choose Claude.app…", action: actions.chooseClaudeApp, target: target))
        settings.addItem(actionItem("Diagnostics…", action: actions.showDiagnostics, target: target))
        settings.addItem(.separator())
        let quit = actionItem("Quit Claude Switcher", action: actions.quit, target: target)
        quit.keyEquivalent = "q"
        quit.isEnabled = input.updateProgress == nil
        settings.addItem(quit)
        menu.addItem(submenuItem("Settings", menu: settings))
        return menu
    }

    private static func actionItem(_ title: String, action: Selector, target: AnyObject,
                                   profile: Profile? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = target
        item.representedObject = profile?.id
        return item
    }

    private static func submenuItem(_ title: String, menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    // MARK: - Usage

    private static func liveUsageItem(profile: Profile, status: AccountStatus?, snapshot: LiveUsageSnapshot?,
                                      failed: Bool, now: Date) -> NSMenuItem {
        let matches = status?.matches(profile.expectedEmail) == true
        let presentation = LiveUsagePresentation(profile: profile, status: status, snapshot: snapshot, failed: failed, now: now)
        let valid = presentation.snapshot
        let rows = [("5h", valid?.fiveHour), ("Week", valid?.sevenDay)].map { label, window in
            let expired = window?.resetsAt.map { $0 <= now } ?? false
            // Keep a passed window's last value, explicitly marked as previous usage.
            let percent = window.flatMap { $0.percent.isFinite ? Int(min(100, max(0, $0.percent)).rounded()) : nil }
            var trailing: String
            if expired {
                trailing = "↻ due"
            } else if let reset = window?.resetsAt {
                trailing = "↻ \(compactClock(reset, now: now))"
            } else if window?.percent == 0 {
                trailing = "—"
            } else if window != nil {
                trailing = "—"
            } else {
                trailing = status == .signedOut ? "Sign in" : (failed ? "Retrying" : (matches || status == nil ? "Loading" : "Checking"))
            }
            return UsageBarView.Row(label: label, percent: percent, level: UsageLevel.of(percent ?? 0),
                                    trailing: trailing, isCached: presentation.isCached || expired)
        }
        let view = UsageBarView(rows: rows)
        let details = rows.map { "\($0.label): \($0.percent.map { "\($0)% used" } ?? "unavailable"), \($0.trailing ?? "sign in first")" }.joined(separator: ". ")
        let checked = snapshot.map { " Last checked \(clock($0.fetchedAt, now: now))." } ?? ""
        view.toolTip = details + checked
        view.setAccessibilityElement(false)
        let item = informationalItem("\(profile.expectedEmail ?? status?.email ?? profile.label). \(details)\(checked)")
        item.view = view
        item.identifier = NSUserInterfaceItemIdentifier("claude-switcher.live-usage.\(profile.id)")
        return item
    }

    private static func codexUsageItem(_ account: CodexAccount, now: Date) -> NSMenuItem {
        let snapshot = account.usage
        let cached = account.usageFailed || snapshot.map { now.timeIntervalSince($0.fetchedAt) > 300 } ?? true
        let rows = [("5h", snapshot?.fiveHour), ("Week", snapshot?.sevenDay)].map { label, window in
            let expired = window?.resetsAt.map { $0 <= now } ?? false
            let percent = window.map { Int(min(100, max(0, $0.percent)).rounded()) }
            let reset = expired ? "↻ due" : window?.resetsAt.map { "↻ \(compactClock($0, now: now))" }
            return UsageBarView.Row(label: label, percent: percent, level: UsageLevel.of(percent ?? 0),
                                    trailing: reset, isCached: cached || expired)
        }
        let view = UsageBarView(rows: rows)
        let details = [("5-hour", snapshot?.fiveHour), ("Weekly", snapshot?.sevenDay)].map { label, value in
            "\(label): \(value.map { "\(Int($0.percent.rounded()))% used" } ?? "unavailable")" +
            (value?.resetsAt.map { ", resets \(clock($0, now: now))" } ?? "")
        }.joined(separator: ". ")
        view.toolTip = details + (snapshot.map { ". Updated \(clock($0.fetchedAt, now: now))" } ?? ". Refreshing…") + (cached ? ". Cached" : "")
        view.setAccessibilityElement(false)
        let item = informationalItem("\(account.email). \(view.toolTip ?? "")")
        item.view = view
        item.identifier = NSUserInterfaceItemIdentifier("codex.usage.\(account.email)")
        return item
    }

    private static func compactClock(_ date: Date, now: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = Calendar.current.isDate(date, inSameDayAs: now) ? "HH:mm" : "EEE HH:mm"
        return formatter.string(from: date)
    }

    static func updateLiveUsage(in menu: NSMenu, config: Config, statuses: [String: AccountStatus],
                                snapshots: [String: LiveUsageSnapshot], failures: Set<String>) {
        for profile in config.profiles {
            let updated = liveUsageItem(profile: profile, status: statuses[profile.id], snapshot: snapshots[profile.id],
                                        failed: failures.contains(profile.id), now: Date())
            guard let existing = menu.items.first(where: { $0.identifier == updated.identifier }) else { continue }
            existing.title = updated.title
            if let current = existing.view as? UsageBarView, let replacement = updated.view as? UsageBarView {
                current.update(rows: replacement.rows)
                current.toolTip = replacement.toolTip
            } else {
                existing.view = updated.view
            }
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    /// "Sat 10:09 PM" — for moments on another day, such as the weekly reset.
    private static let dayTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEE jmm")
        return formatter
    }()

    /// A clock time, with the weekday when it is not today.
    static func clock(_ date: Date, now: Date) -> String {
        Calendar.current.isDate(date, inSameDayAs: now)
            ? timeFormatter.string(from: date)
            : dayTimeFormatter.string(from: date)
    }

    static func usageItemIdentifier(_ profileID: String) -> NSUserInterfaceItemIdentifier {
        NSUserInterfaceItemIdentifier("claude-switcher.usage.\(profileID)")
    }

    /// The drawn usage rows under a profile. A view item never draws its title, so the title
    /// carries the sentence VoiceOver reads; the view itself is not an accessibility element.
    static func usageItem(for profile: Profile, reading: UsageReading, now: Date) -> NSMenuItem {
        let time: (Date) -> String = { clock($0, now: now) }
        let rows = reading.rows.map { row in
            UsageBarView.Row(
                label: row.label,
                percent: row.percent,
                level: UsageLevel.of(row.percent ?? 0),
                trailing: UsageText.trailing(for: row, in: reading, time: time)
            )
        }
        let view = UsageBarView(rows: rows)
        view.toolTip = UsageText.tooltip(reading, time: time)
        view.setAccessibilityElement(false)

        let item = NSMenuItem(title: UsageText.accessibilityText(reading, profileLabel: profile.label, time: time),
                              action: nil, keyEquivalent: "")
        item.view = view
        item.isEnabled = false
        item.identifier = usageItemIdentifier(profile.id)
        return item
    }

    // MARK: - Hints

    static func profileItemIdentifier(_ profileID: String) -> NSUserInterfaceItemIdentifier {
        NSUserInterfaceItemIdentifier("claude-switcher.profile.\(profileID)")
    }

    static func applyAccount(to item: NSMenuItem, profile: Profile, status: AccountStatus?) {
        let presentation = AccountPresentation(profile: profile, status: status)
        item.title = presentation.title
        item.badge = presentation.badge.map { NSMenuItemBadge(string: $0) }
        item.toolTip = presentation.help
        item.isEnabled = status != nil
    }

    /// Update existing rows without moving anything under the pointer.
    static func updateAccounts(in menu: NSMenu, config: Config, statuses: [String: AccountStatus]) {
        for profile in config.profiles {
            guard let item = menu.items.first(where: { $0.identifier == profileItemIdentifier(profile.id) }) else { continue }
            applyAccount(to: item, profile: profile, status: statuses[profile.id])
        }
    }

    static func informationalItem(_ text: String) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }
}
