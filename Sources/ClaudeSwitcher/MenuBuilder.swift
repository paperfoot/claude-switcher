import AppKit
import ClaudeSwitcherCore

/// Builds the status-item menu from a snapshot of state. Side-effect free: it reads the
/// values handed to it (including cached account identities) and never
/// performs I/O, so opening the menu can never block on a `security` call or a subprocess.
@MainActor
enum MenuBuilder {

    // MARK: - Inputs

    /// The menu shows accounts, usage, the palette and Quit. Selectors for actions that moved
    /// to the command palette stay, so the app's wiring is unchanged.
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
        var toggleHistory: Selector = NSSelectorFromString("toggleHistory:")
        var syncHistory: Selector = NSSelectorFromString("syncHistory:")
        var undoHistory: Selector = NSSelectorFromString("undoHistory:")
        var openPalette: Selector = NSSelectorFromString("openPalette:")
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
        /// A saved Chrome login that has expired or expires within days.
        var loginWarning: String?
        /// Lowercased emails whose saved Chrome login needs a fresh sign-in.
        var chromeSignInEmails: Set<String> = []
        var historyEnabled = false
        var historyBusy = false
        var historyMessage: String?
    }

    // MARK: - Build

    static func build(_ input: Input, target: AnyObject, actions: Actions) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.minimumWidth = UsageBarView.preferredWidth
        menu.showsStateColumn = true
        menu.addItem(sectionItem(input.coordinated ? "Claude" : "Claude Code"))
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
                if item.badge == nil, let email = profile.expectedEmail,
                   input.chromeSignInEmails.contains(email.lowercased()) {
                    item.badge = NSMenuItemBadge(string: "Chrome sign-in")
                    item.toolTip = "Chrome's saved login for this account has expired. Choose it to sign in to claude.ai once; the switch then finishes by itself."
                }
            }
            menu.addItem(item)
            menu.addItem(liveUsageItem(profile: profile, status: input.accountStatuses[profile.id],
                                       snapshot: input.liveUsage[profile.id], failed: input.usageFailures.contains(profile.id),
                                       now: input.now))
        }
        if input.coordinated {
            if let message = input.switchMessage { menu.addItem(detailItem(message, id: "claude.status")) }
            if let warning = input.loginWarning { menu.addItem(detailItem(warning, id: "claude.login-warning")) }
        }
        if !input.codexAccounts.isEmpty {
            menu.addItem(.separator())
            menu.addItem(sectionItem("Codex"))
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
            if let message = input.codexMessage { menu.addItem(detailItem(message, id: "codex.status")) }
            if input.codexConnecting {
                let cancel = actionItem("Cancel sign-in", action: actions.cancelCodexLogin, target: target)
                cancel.identifier = NSUserInterfaceItemIdentifier("codex.cancel-login")
                menu.addItem(cancel)
            }
        }
        // Settings and Desktop actions live in the command palette. A waiting update and
        // background Desktop results stay here, so nothing important becomes invisible.
        var desktop: [NSMenuItem] = []
        if let update = input.blockedUpdate, !input.running.isEmpty, input.updateProgress == nil {
            let install = actionItem("Install Claude \(update.staged)…", action: actions.installUpdate, target: target)
            install.identifier = NSUserInterfaceItemIdentifier(installItemID)
            install.isEnabled = !input.isBusy
            desktop.append(install)
        }
        for (id, text) in desktopDetails(input) {
            if let text { desktop.append(detailItem(text, id: id)) }
        }
        if !desktop.isEmpty {
            menu.addItem(.separator())
            for item in desktop { menu.addItem(item) }
        }

        menu.addItem(.separator())
        let palette = actionItem("Command…", action: actions.openPalette, target: target)
        palette.identifier = NSUserInterfaceItemIdentifier(paletteItemID)
        palette.keyEquivalent = " "
        palette.keyEquivalentModifierMask = [.option]
        palette.toolTip = "Switch, add or manage accounts by typing"
        menu.addItem(palette)
        let quit = actionItem("Quit Claude Switcher", action: actions.quit, target: target)
        quit.identifier = NSUserInterfaceItemIdentifier(quitItemID)
        quit.keyEquivalent = "q"
        quit.isEnabled = input.updateProgress == nil
        menu.addItem(quit)
        return menu
    }

    static let installItemID = "claude-switcher.install-update"
    static let paletteItemID = "claude-switcher.palette"
    static let quitItemID = "claude-switcher.quit"

    /// Results of Desktop work that can finish while the palette is closed.
    private static func desktopDetails(_ input: Input) -> [(id: String, text: String?)] {
        [("desktop.update-progress", input.updateProgress),
         ("desktop.reopen-notice", input.autoReopenNotice),
         ("desktop.history-status", input.historyMessage)]
    }

    /// Tracking menus retain their exact item/view instances and dimensions. Structural
    /// changes, titles and badges are applied on the next opening, never under the pointer.
    static func updateVisible(in menu: NSMenu, input: Input) {
        for profile in input.config.profiles {
            guard let item = menu.items.first(where: { $0.identifier == profileItemIdentifier(profile.id) }) else { continue }
            if input.coordinated {
                item.state = profile.expectedEmail?.caseInsensitiveCompare(input.selectedEmail ?? "") == .orderedSame ? .on : .off
                item.isEnabled = !input.switching && !input.codexBusy
            } else {
                item.isEnabled = input.accountStatuses[profile.id] != nil
                item.toolTip = AccountPresentation(profile: profile, status: input.accountStatuses[profile.id]).help
            }
            refreshUsage(in: menu, from: liveUsageItem(profile: profile, status: input.accountStatuses[profile.id],
                                                       snapshot: input.liveUsage[profile.id],
                                                       failed: input.usageFailures.contains(profile.id), now: input.now))
        }
        for account in input.codexAccounts {
            let id = NSUserInterfaceItemIdentifier("codex.account.\(account.email)")
            if let item = menu.items.first(where: { $0.identifier == id }) {
                item.state = account.active ? .on : .off
                // Keep the displayed Connect badge and its click behavior consistent until reopening.
                let connectionUnchanged = (item.badge == nil) == account.connected
                item.isEnabled = connectionUnchanged && !input.codexBusy && !input.switching
            }
            refreshUsage(in: menu, from: codexUsageItem(account, now: input.now))
        }
        menu.items.first { $0.identifier?.rawValue == "codex.cancel-login" }?.isEnabled = input.codexConnecting
        menu.items.first { $0.identifier?.rawValue == installItemID }?.isEnabled = !input.isBusy && input.updateProgress == nil
        menu.items.first { $0.identifier?.rawValue == quitItemID }?.isEnabled = input.updateProgress == nil
        let details = [(id: "claude.status", text: input.switchMessage), (id: "claude.login-warning", text: input.loginWarning),
                       (id: "codex.status", text: input.codexMessage)]
        for (id, text) in details + desktopDetails(input) {
            let item = menu.items.first { $0.identifier?.rawValue == id }
            (item?.view as? MenuDetailView)?.update(text: text ?? "")
        }
    }

    private static func sectionItem(_ text: String) -> NSMenuItem {
        let item = informationalItem(text)
        item.view = MenuDetailView(text: text, section: true)
        return item
    }

    private static func detailItem(_ text: String, id: String) -> NSMenuItem {
        let item = informationalItem("")
        item.identifier = NSUserInterfaceItemIdentifier(id)
        item.view = MenuDetailView(text: text)
        return item
    }

    private static func actionItem(_ title: String, action: Selector, target: AnyObject,
                                   profile: Profile? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = target
        item.representedObject = profile?.id
        return item
    }

    // MARK: - Usage

    private static func liveUsageItem(profile: Profile, status: AccountStatus?, snapshot: LiveUsageSnapshot?,
                                      failed: Bool, now: Date) -> NSMenuItem {
        let presentation = LiveUsagePresentation(profile: profile, status: status, snapshot: snapshot, failed: failed, now: now)
        let matches = status?.matches(profile.expectedEmail) == true
        let waiting = status == .signedOut ? "Sign in" : (failed ? "Retrying" : (matches || status == nil ? "Loading" : "Checking"))
        let item = gaugeItem(presentation.snapshot, stale: presentation.isStale, failed: failed, waiting: waiting,
                             subject: profile.expectedEmail ?? status?.email ?? profile.label, now: now)
        item.identifier = NSUserInterfaceItemIdentifier("claude-switcher.live-usage.\(profile.id)")
        return item
    }

    private static func codexUsageItem(_ account: CodexAccount, now: Date) -> NSMenuItem {
        let stale = LiveUsagePolicy.isStale(account.usage, failed: account.usageFailed, now: now)
        let item = gaugeItem(account.usage, stale: stale, failed: account.usageFailed,
                             waiting: account.usageFailed ? "Retrying" : "Loading", subject: account.email, now: now)
        item.identifier = NSUserInterfaceItemIdentifier("codex.usage.\(account.email)")
        return item
    }

    /// Claude and Codex rows share one rule: colour follows the level, a stale reading is shown
    /// as approximate, and a window whose reset has passed is unknown until the next reading.
    /// `waiting` stands in for both windows while there is no reading at all.
    private static func gaugeItem(_ snapshot: LiveUsageSnapshot?, stale: Bool, failed: Bool, waiting: String,
                                  subject: String, now: Date) -> NSMenuItem {
        var rows: [UsageBarView.Row] = []
        var lines: [String] = []
        for (label, name, window) in [("5h", "5-hour", snapshot?.fiveHour), ("Week", "Weekly", snapshot?.sevenDay)] {
            let reset = window?.resetsAt
            let expired = reset.map { $0 <= now } ?? false
            let percent = window.flatMap { $0.percent.isFinite ? $0.displayedPercent(at: now) : nil }
            let trailing: String?
            if snapshot == nil {
                trailing = waiting
            } else if expired {
                trailing = "↻ due"
            } else {
                trailing = reset.map { "↻ \(compactClock($0, now: now))" }
            }
            rows.append(UsageBarView.Row(label: label, percent: percent, level: UsageLevel.of(percent ?? 0),
                                         trailing: trailing, isStale: stale && percent != nil))
            if expired {
                lines.append("\(name): reset due, waiting for a new reading")
            } else if let percent {
                lines.append("\(name): \(stale ? "about " : "")\(percent)% used" + (reset.map { ", resets \(clock($0, now: now))" } ?? ""))
            } else if snapshot != nil {
                lines.append("\(name): unavailable")
            }
        }
        if let snapshot {
            lines.append("Last updated \(clock(snapshot.fetchedAt, now: now))" + (failed ? ", latest refresh failed" : ""))
        } else {
            lines.append("Usage: \(waiting.lowercased())")
        }
        let view = UsageBarView(rows: rows)
        view.toolTip = lines.joined(separator: "\n")
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.staticText)
        view.setAccessibilityLabel(([subject] + lines).joined(separator: ". ") + ".")
        let item = informationalItem("Usage")
        item.view = view
        return item
    }

    /// Copies new rows and descriptions into the usage view already on screen, keeping its
    /// identity and frame.
    private static func refreshUsage(in menu: NSMenu, from updated: NSMenuItem) {
        guard let current = menu.items.first(where: { $0.identifier == updated.identifier })?.view as? UsageBarView,
              let replacement = updated.view as? UsageBarView else { return }
        current.update(rows: replacement.rows)
        current.toolTip = replacement.toolTip
        current.setAccessibilityLabel(replacement.accessibilityLabel())
    }

    private static func compactClock(_ date: Date, now: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = Calendar.current.isDate(date, inSameDayAs: now) ? "HH:mm" : "EEE HH:mm"
        return formatter.string(from: date)
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

    static func informationalItem(_ text: String) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }
}
