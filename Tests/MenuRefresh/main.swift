import AppKit
import ClaudeSwitcherCore
import Darwin

@MainActor
private final class MenuRefreshHarness {
    private var failures: [String] = []

    private let now: Date
    private let midnightReset: Date
    private let calendar: Calendar
    /// Where `--preview` keeps the rendered gauge PNGs; `nil` renders into a temporary folder.
    private let previewDirectory: URL?

    init(previewDirectory: URL?) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        self.calendar = calendar
        self.previewDirectory = previewDirectory
        now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 28, hour: 23, minute: 50))!
        midnightReset = calendar.date(from: DateComponents(year: 2026, month: 9, day: 29, hour: 0, minute: 5))!
    }

    func run() -> [String] {
        let target = NSObject()
        let initial = makeInitialInput()
        let menu = MenuBuilder.build(initial, target: target, actions: actions())

        check(menu.minimumWidth == UsageBarView.preferredWidth, "menu keeps the fixed native minimum width")
        // Readings ten and fifteen minutes old are current: accounts refresh at different moments.
        expectRows(in: menu, id: "claude-switcher.live-usage.alpha", [0, 9], stale: false)
        expectRows(in: menu, id: "claude-switcher.live-usage.beta", [99, 100], stale: true)
        expectRows(in: menu, id: "claude-switcher.live-usage.gamma", [nil, nil], stale: false)
        expectRows(in: menu, id: "codex.usage.delta@example.test", [9, 99], stale: false)
        expectRows(in: menu, id: "codex.usage.echo@example.test", [100, 0], stale: true)
        check(item(in: menu, id: "codex.usage.foxtrot@example.test") == nil,
              "disconnected Codex account has no usage row initially")

        let initialAlphaLabel = accessibilityLabel(in: menu, id: "claude-switcher.live-usage.alpha")
        check(initialAlphaLabel?.contains("0%") == true && initialAlphaLabel?.contains("9%") == true,
              "initial accessibility label contains the live percentages")
        check(usageView(in: menu, id: "claude-switcher.live-usage.alpha")?.rows.first?.trailing == "↻ Tue 00:05",
              "reset just after midnight includes the next day and clock time")
        checkCustomViewTitles(in: menu)
        checkCompactStructure(menu, context: "initial menu")

        check(menu.size.width >= UsageBarView.preferredWidth && menu.size.height > 0,
              "AppKit measures a real nonzero menu, not an uninitialized size")
        let baseline = IdentitySnapshot(menu)
        var busy = makeUpdatedInput()
        busy.isBusy = true
        busy.codexBusy = true
        busy.switching = true
        MenuBuilder.updateVisible(in: menu, input: busy)

        expectUnchanged(menu, from: baseline, context: "busy refresh")
        // Alpha's five-hour window reset a second ago: its old 100% would describe a finished window.
        expectRows(in: menu, id: "claude-switcher.live-usage.alpha", [nil, 99], stale: false)
        check(usageView(in: menu, id: "claude-switcher.live-usage.alpha")?.rows.map(\.trailing) == ["↻ due", "↻ Tue 00:05"],
              "a passed reset shows as due instead of the previous window's value")
        expectRows(in: menu, id: "claude-switcher.live-usage.beta", [nil, nil], stale: false)
        check(usageView(in: menu, id: "claude-switcher.live-usage.beta")?.rows.allSatisfy { $0.trailing == "Sign in" } == true,
              "signed-out account hides its cached usage and asks for sign-in")
        expectRows(in: menu, id: "claude-switcher.live-usage.gamma", [9, 0], stale: false)
        expectRows(in: menu, id: "codex.usage.delta@example.test", [0, 9], stale: false)
        expectRows(in: menu, id: "codex.usage.echo@example.test", [99, 100], stale: true)
        check(item(in: menu, id: "claude-switcher.profile.alpha")?.isEnabled == false,
              "Claude account actions disable while switching")
        check(item(in: menu, id: "codex.account.delta@example.test")?.isEnabled == false,
              "Codex account actions disable while switching")
        expectSelected(menu, id: "claude-switcher.profile.gamma")
        expectSelected(menu, id: "codex.account.foxtrot@example.test")
        check(item(in: menu, id: "codex.usage.foxtrot@example.test") == nil,
              "visible refresh does not insert a newly connected usage row")
        check(!allTitles(in: menu).contains(busy.switchMessage!),
              "visible refresh defers a newly added Claude status row")
        check(!allTitles(in: menu).contains(busy.codexMessage!),
              "visible refresh defers a newly added Codex status row")

        let updatedAlphaLabel = accessibilityLabel(in: menu, id: "claude-switcher.live-usage.alpha")
        check(updatedAlphaLabel != initialAlphaLabel,
              "accessibility label changes with live usage")
        check(updatedAlphaLabel?.contains("99%") == true && updatedAlphaLabel?.contains("reset due") == true,
              "updated accessibility label contains the new percentage and the due reset")
        check(updatedAlphaLabel?.contains("100%") == false,
              "updated accessibility label does not repeat the finished window's value")
        let staleLabel = accessibilityLabel(in: menu, id: "codex.usage.echo@example.test")
        check(staleLabel?.contains("about 99% used") == true && staleLabel?.contains("Last updated") == true,
              "stale accessibility label says the value is approximate and when it was read")
        checkCustomViewTitles(in: menu)

        let settled = makeUpdatedInput()
        MenuBuilder.updateVisible(in: menu, input: settled)
        expectUnchanged(menu, from: baseline, context: "settled refresh")
        check(item(in: menu, id: "claude-switcher.profile.gamma")?.isEnabled == true,
              "Claude account actions re-enable after switching")
        check(item(in: menu, id: "codex.account.delta@example.test")?.isEnabled == true,
              "unchanged connected Codex account re-enables after switching")
        check(item(in: menu, id: "codex.account.foxtrot@example.test")?.isEnabled == false,
              "newly connected Codex row stays disabled until its Connect badge is rebuilt")

        let reopened = MenuBuilder.build(settled, target: target, actions: actions())
        check(item(in: reopened, id: "codex.usage.foxtrot@example.test") != nil,
              "next opening adds the newly connected Codex usage row")
        check(item(in: reopened, id: "codex.account.foxtrot@example.test")?.badge == nil,
              "next opening removes the stale Connect badge")
        check(item(in: reopened, id: "codex.account.foxtrot@example.test")?.isEnabled == true,
              "newly connected Codex account enables on next opening")
        check(detailText(in: reopened, id: "claude.status") == settled.switchMessage,
              "next opening includes the full Claude status message")
        check(detailText(in: reopened, id: "codex.status") == settled.codexMessage,
              "next opening includes the full Codex status message")
        check(reopened.numberOfItems > menu.numberOfItems,
              "next opening applies deferred structural additions")
        expectSelected(reopened, id: "claude-switcher.profile.gamma")
        expectSelected(reopened, id: "codex.account.foxtrot@example.test")
        checkCustomViewTitles(in: reopened)
        let reopenedBaseline = IdentitySnapshot(reopened)
        for iteration in 0..<12 {
            var live = settled
            live.codexMessage = iteration.isMultiple(of: 2) ? "Ready" : String(repeating: "A long status message. ", count: 20)
            live.switchMessage = iteration.isMultiple(of: 2) ? nil : "Switching…"
            live.now = now.addingTimeInterval(TimeInterval(iteration * 300))
            MenuBuilder.updateVisible(in: reopened, input: live)
            expectUnchanged(reopened, from: reopenedBaseline, context: "message/time refresh \(iteration)")
            check(detailText(in: reopened, id: "codex.status") == live.codexMessage,
                  "status text updates inside its existing fixed frame")
        }
        checkCompactStructure(reopened, context: "reopened menu")
        checkDesktopStates(target: target)
        checkPreview(target: target)

        return failures
    }

    /// Renders the menu's own usage rows for fictional accounts in both appearances.
    private func checkPreview(target: NSObject) {
        let menu = MenuBuilder.build(makePreviewInput(), target: target, actions: actions())
        var accounts: [(title: String, rows: [UsageBarView.Row])] = []
        for (item, next) in zip(menu.items, menu.items.dropFirst()) {
            guard item.view == nil, !item.isSeparatorItem, let gauges = next.view as? UsageBarView else { continue }
            accounts.append((item.title, gauges.rows))
        }
        check(accounts.count == 5, "preview pairs every account with its usage row")
        let directory = previewDirectory ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-switcher-preview-\(UUID().uuidString)", isDirectory: true)
        defer { if previewDirectory == nil { try? FileManager.default.removeItem(at: directory) } }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
                let url = directory.appendingPathComponent("usage-gauges-\(name).png")
                try UsageBarView.renderPreview(rowsPerAccount: accounts, appearance: appearance, to: url)
                let image = NSBitmapImageRep(data: try Data(contentsOf: url))
                check(image?.pixelsWide == Int(UsageBarView.preferredWidth) * 2, "\(name) preview is drawn at 2x")
                check(image?.size.width == UsageBarView.preferredWidth, "\(name) preview records its point size")
                if previewDirectory != nil { print("preview: \(url.path)") }
            }
        } catch {
            failures.append("preview could not be written: \(error)")
        }
    }

    /// Fictional accounts covering each gauge state: current, warning, a failed refresh, a
    /// passed reset beside an old limit reading, and Codex.
    private func makePreviewInput() -> MenuBuilder.Input {
        // Monday 28 September; days past 30 run on into October.
        let at = { (day: Int, hour: Int, minute: Int) in
            self.calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute))!
        }
        let previewNow = at(28, 13, 20)
        func reading(_ email: String, minutesOld: Double, _ five: Double, _ fiveReset: Date,
                     _ week: Double, _ weekReset: Date) -> LiveUsageSnapshot {
            LiveUsageSnapshot(email: email, fetchedAt: previewNow.addingTimeInterval(-minutesOld * 60),
                              fiveHour: LiveUsageWindow(percent: five, resetsAt: fiveReset),
                              sevenDay: LiveUsageWindow(percent: week, resetsAt: weekReset))
        }
        let emails = ["work@example.com", "studio@example.com", "team@example.com", "max@example.com"]
        let profiles = emails.map { Profile(id: String($0.prefix { $0 != "@" }), label: $0, expectedEmail: $0) }
        var codex = CodexAccount(email: "dev@example.com")
        codex.connected = true
        codex.active = true
        codex.usage = reading("dev@example.com", minutesOld: 3, 9, at(28, 16, 40), 31, at(32, 12, 0))
        return MenuBuilder.Input(
            config: Config(claudeAppPath: "/Applications/Fictional Claude.app", activeProfileId: "work", profiles: profiles),
            running: [],
            accountStatuses: Dictionary(uniqueKeysWithValues: profiles.map {
                ($0.id, AccountStatus.signedIn(email: $0.expectedEmail, plan: nil))
            }),
            liveUsage: [
                "work": reading("work@example.com", minutesOld: 2, 12, at(28, 15, 5), 40, at(31, 7, 0)),
                "studio": reading("studio@example.com", minutesOld: 7, 76, at(28, 17, 30), 88, at(33, 22, 0)),
                "team": reading("team@example.com", minutesOld: 12, 84, at(28, 14, 10), 93, at(30, 4, 44)),
                "max": reading("max@example.com", minutesOld: 25, 97, at(28, 13, 5), 100, at(29, 9, 0)),
            ],
            usageFailures: ["team"],
            isBusy: false,
            configError: nil,
            claudeAppExists: true,
            launchAtLogin: .enabled,
            now: previewNow,
            codexAccounts: [codex],
            coordinated: true,
            selectedEmail: "work@example.com"
        )
    }

    /// Settings moved to the command palette: the menu ends with it and Quit.
    private func checkCompactStructure(_ menu: NSMenu, context: String) {
        check(allItems(in: menu).allSatisfy { $0.submenu == nil }, "\(context) has no submenus")
        let tail = Array(menu.items.suffix(3))
        check(tail.count == 3 && tail[0].isSeparatorItem, "\(context) separates the palette and Quit from the accounts")
        let palette = item(in: menu, id: MenuBuilder.paletteItemID)
        check(palette === tail.dropFirst().first && palette?.title == "Command…"
              && palette?.action == NSSelectorFromString("openPalette:"),
              "\(context) opens the palette from Command…")
        check(palette?.keyEquivalent == " " && palette?.keyEquivalentModifierMask == [.option],
              "\(context) shows the palette shortcut ⌥Space")
        check(palette?.toolTip == "Switch, add or manage accounts by typing", "\(context) explains the palette")
        let quit = menu.items.last
        check(quit?.identifier?.rawValue == MenuBuilder.quitItemID && quit?.title == "Quit Claude Switcher"
              && quit?.keyEquivalent == "q" && quit?.keyEquivalentModifierMask == [.command],
              "\(context) ends with Quit ⌘Q")
    }

    /// A waiting update and Desktop results stay visible even though Desktop actions moved.
    private func checkDesktopStates(target: NSObject) {
        var input = makeUpdatedInput()
        input.blockedUpdate = StagedUpdate(installed: AppVersion(short: "1.4.0", build: "140"),
                                           staged: AppVersion(short: "1.5.0", build: "150"),
                                           updateBundlePath: "/tmp/fictional-update/Claude.app")
        input.running = [RunningInstance(pid: 4242, profile: .defaultProfile)]
        input.autoReopenNotice = "Reopened Beta after Claude updated to 1.5.0 at 09:00."
        input.historyMessage = "Code history synced for two fictional accounts."
        let menu = MenuBuilder.build(input, target: target, actions: actions())
        let install = item(in: menu, id: MenuBuilder.installItemID)
        check(install?.title == "Install Claude 1.5.0…" && install?.isEnabled == true
              && install?.action == NSSelectorFromString("noop:"),
              "a waiting Claude update is offered at the top level")
        check(detailText(in: menu, id: "desktop.reopen-notice") == input.autoReopenNotice,
              "the automatic reopen notice is visible")
        check(detailText(in: menu, id: "desktop.history-status") == input.historyMessage,
              "the history result is visible")
        check(item(in: menu, id: "desktop.update-progress") == nil, "no progress row before installing")
        checkCompactStructure(menu, context: "menu with Desktop states")
        checkCustomViewTitles(in: menu)

        let baseline = IdentitySnapshot(menu)
        var installing = input
        installing.isBusy = true
        installing.updateProgress = "Installing update…"
        installing.historyMessage = "Code history sync finished."
        MenuBuilder.updateVisible(in: menu, input: installing)
        expectUnchanged(menu, from: baseline, context: "update progress refresh")
        check(item(in: menu, id: MenuBuilder.installItemID)?.isEnabled == false,
              "the install offer disables once installing starts")
        check(item(in: menu, id: MenuBuilder.quitItemID)?.isEnabled == false, "Quit disables while an update installs")
        check(detailText(in: menu, id: "desktop.history-status") == installing.historyMessage,
              "the history result updates inside its fixed frame")

        let progress = MenuBuilder.build(installing, target: target, actions: actions())
        check(item(in: progress, id: MenuBuilder.installItemID) == nil, "progress replaces the install offer")
        check(detailText(in: progress, id: "desktop.update-progress") == installing.updateProgress,
              "update progress is visible")
        check(item(in: progress, id: MenuBuilder.quitItemID)?.isEnabled == false, "Quit stays disabled during the install")

        var noInstances = input
        noInstances.running = []
        noInstances.autoReopenNotice = nil
        noInstances.historyMessage = nil
        let quiet = MenuBuilder.build(noInstances, target: target, actions: actions())
        check(item(in: quiet, id: MenuBuilder.installItemID) == nil,
              "no install offer while no Claude instance keeps the installer waiting")
        check(!quiet.items.contains { $0.identifier?.rawValue.hasPrefix("desktop.") == true },
              "no empty Desktop rows")
        check(zip(quiet.items, quiet.items.dropFirst()).allSatisfy { !($0.isSeparatorItem && $1.isSeparatorItem) },
              "no doubled separators")
    }

    private func makeInitialInput() -> MenuBuilder.Input {
        let profiles = makeProfiles()
        let config = Config(claudeAppPath: "/Applications/Fictional Claude.app",
                            activeProfileId: "alpha", profiles: profiles)
        let statuses: [String: AccountStatus] = [
            "alpha": .signedIn(email: "alpha@example.test", plan: "max"),
            "beta": .signedIn(email: "beta@example.test", plan: "pro"),
        ]
        let live: [String: LiveUsageSnapshot] = [
            "alpha": snapshot("alpha@example.test", age: 600, five: 0, week: 9,
                              fiveReset: midnightReset, weekReset: now.addingTimeInterval(86_400)),
            "beta": snapshot("beta@example.test", age: 3_600, five: 99, week: 100,
                             fiveReset: now.addingTimeInterval(1_800), weekReset: now.addingTimeInterval(172_800)),
        ]

        return MenuBuilder.Input(
            config: config,
            running: [],
            accountStatuses: statuses,
            liveUsage: live,
            usageFailures: [],
            isBusy: false,
            configError: nil,
            claudeAppExists: true,
            launchAtLogin: .enabled,
            blockedUpdate: nil,
            updateProgress: nil,
            now: now,
            autoReopenNotice: nil,
            codexAccounts: initialCodexAccounts(),
            codexMessage: nil,
            codexBusy: false,
            codexConnecting: false,
            coordinated: true,
            selectedEmail: "alpha@example.test",
            browserEmail: "alpha@example.test",
            browserConnected: true,
            switching: false,
            switchMessage: nil
        )
    }

    private func makeUpdatedInput() -> MenuBuilder.Input {
        let profiles = makeProfiles()
        let config = Config(claudeAppPath: "/Applications/Fictional Claude.app",
                            activeProfileId: "gamma", profiles: profiles)
        let statuses: [String: AccountStatus] = [
            "alpha": .signedIn(email: "alpha@example.test", plan: "max"),
            "beta": .signedOut,
            "gamma": .signedIn(email: "gamma@example.test", plan: "pro"),
        ]
        let live: [String: LiveUsageSnapshot] = [
            "alpha": snapshot("alpha@example.test", age: 10, five: 100, week: 99,
                              fiveReset: now.addingTimeInterval(-1), weekReset: midnightReset),
            "beta": snapshot("beta@example.test", age: 3_600, five: 99, week: 100,
                             fiveReset: now.addingTimeInterval(1_800), weekReset: now.addingTimeInterval(172_800)),
            "gamma": snapshot("gamma@example.test", age: 20, five: 9, week: 0,
                              fiveReset: now.addingTimeInterval(600), weekReset: nil),
        ]
        let switchMessage = "Claude switch could not finish because the fictional browser session changed while the account handoff was being prepared; retry from this menu."
        let codexMessage = "Codex could not finish the fictional account change because active work prevented a safe reopen; finish that work and try again."

        return MenuBuilder.Input(
            config: config,
            running: [],
            accountStatuses: statuses,
            liveUsage: live,
            usageFailures: ["beta"],
            isBusy: false,
            configError: nil,
            claudeAppExists: true,
            launchAtLogin: .enabled,
            blockedUpdate: nil,
            updateProgress: nil,
            now: now,
            autoReopenNotice: nil,
            codexAccounts: updatedCodexAccounts(),
            codexMessage: codexMessage,
            codexBusy: false,
            codexConnecting: false,
            coordinated: true,
            selectedEmail: "gamma@example.test",
            browserEmail: "alpha@example.test",
            browserConnected: false,
            switching: false,
            switchMessage: switchMessage
        )
    }

    private func makeProfiles() -> [Profile] {
        [
            Profile(id: "alpha", label: "Alpha", expectedEmail: "alpha@example.test"),
            Profile(id: "beta", label: "Beta", userDataDir: "/tmp/fictional-beta-desktop",
                    credDir: "/tmp/fictional-beta-code", expectedEmail: "beta@example.test"),
            Profile(id: "gamma", label: "Gamma", userDataDir: "/tmp/fictional-gamma-desktop",
                    credDir: "/tmp/fictional-gamma-code", expectedEmail: "gamma@example.test"),
        ]
    }

    private func initialCodexAccounts() -> [CodexAccount] {
        [
            codex("delta@example.test", connected: true, active: true, five: 9, week: 99, age: 900),
            codex("echo@example.test", connected: true, active: false, five: 100, week: 0, age: 3_600,
                  failed: true),
            codex("foxtrot@example.test", connected: false, active: false, five: nil, week: nil, age: 0),
        ]
    }

    private func updatedCodexAccounts() -> [CodexAccount] {
        [
            codex("delta@example.test", connected: true, active: false, five: 0, week: 9, age: 10),
            codex("echo@example.test", connected: true, active: false, five: 99, week: 100, age: 3_600,
                  failed: true),
            codex("foxtrot@example.test", connected: true, active: true, five: 100, week: 0, age: 10),
        ]
    }

    private func codex(_ email: String, connected: Bool, active: Bool, five: Double?, week: Double?,
                       age: TimeInterval, failed: Bool = false) -> CodexAccount {
        var account = CodexAccount(email: email)
        account.connected = connected
        account.active = active
        account.usageFailed = failed
        if connected, five != nil || week != nil {
            account.usage = LiveUsageSnapshot(
                email: email,
                fetchedAt: now.addingTimeInterval(-age),
                fiveHour: five.map { LiveUsageWindow(percent: $0, resetsAt: midnightReset) },
                sevenDay: week.map { LiveUsageWindow(percent: $0, resetsAt: now.addingTimeInterval(172_800)) }
            )
        }
        return account
    }

    private func snapshot(_ email: String, age: TimeInterval, five: Double?, week: Double?,
                          fiveReset: Date?, weekReset: Date?) -> LiveUsageSnapshot {
        LiveUsageSnapshot(
            email: email,
            fetchedAt: now.addingTimeInterval(-age),
            fiveHour: five.map { LiveUsageWindow(percent: $0, resetsAt: fiveReset) },
            sevenDay: week.map { LiveUsageWindow(percent: $0, resetsAt: weekReset) }
        )
    }

    private func actions() -> MenuBuilder.Actions {
        let selector = NSSelectorFromString("noop:")
        return MenuBuilder.Actions(
            selectProfile: selector,
            copyTerminalCommand: selector,
            openTerminal: selector,
            selectCodexAccount: selector,
            cancelCodexLogin: selector,
            switchAccount: selector,
            setupSwitching: selector,
            addProfile: selector,
            renameProfile: selector,
            removeProfile: selector,
            chooseClaudeApp: selector,
            revealSharedDirectory: selector,
            showDiagnostics: selector,
            toggleLaunchAtLogin: selector,
            toggleReopenAfterUpdate: selector,
            toggleBlockUpdates: selector,
            installUpdate: selector,
            quit: selector
        )
    }

    private func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { failures.append(message) }
    }

    private func expectRows(in menu: NSMenu, id: String, _ expected: [Int?], stale: Bool) {
        guard let rows = usageView(in: menu, id: id)?.rows else {
            failures.append("missing usage view \(id)")
            return
        }
        check(rows.map(\.percent) == expected, "\(id) percentages are \(expected)")
        // Only a known value can be approximate; an unknown one is a plain dash.
        check(rows.allSatisfy { $0.isStale == (stale && $0.percent != nil) }, "\(id) stale state is \(stale)")
    }

    private func expectSelected(_ menu: NSMenu, id selectedID: String) {
        let family = selectedID.hasPrefix("codex.") ? "codex.account." : "claude-switcher.profile."
        let selected = allItems(in: menu).filter { $0.identifier?.rawValue.hasPrefix(family) == true && $0.state == .on }
        check(selected.count == 1 && selected.first?.identifier?.rawValue == selectedID,
              "\(selectedID) is the only active checkmark")
    }

    private func expectUnchanged(_ menu: NSMenu, from baseline: IdentitySnapshot, context: String) {
        let current = IdentitySnapshot(menu)
        check(current.itemCounts == baseline.itemCounts, "\(context) preserves every menu item count")
        check(current.itemIDs == baseline.itemIDs, "\(context) preserves every menu item identity")
        check(current.viewIDs == baseline.viewIDs, "\(context) preserves every custom view identity")
        check(current.sizes == baseline.sizes, "\(context) preserves every menu size")
        check(current.viewFrames == baseline.viewFrames, "\(context) preserves every custom row frame")
    }

    private func checkCustomViewTitles(in menu: NSMenu) {
        for item in menu.items where item.view != nil {
            check(item.title.count <= 16,
                  "top-level custom view title is short: \(String(reflecting: item.title))")
            if item.view is UsageBarView {
                check(item.view?.accessibilityLabel()?.isEmpty == false,
                      "usage custom view exposes a live accessibility label")
            }
        }
    }

    private func item(in menu: NSMenu, id: String) -> NSMenuItem? {
        allItems(in: menu).first { $0.identifier?.rawValue == id }
    }

    private func usageView(in menu: NSMenu, id: String) -> UsageBarView? {
        item(in: menu, id: id)?.view as? UsageBarView
    }

    private func accessibilityLabel(in menu: NSMenu, id: String) -> String? {
        item(in: menu, id: id)?.view?.accessibilityLabel()
    }

    private func detailText(in menu: NSMenu, id: String) -> String? {
        (item(in: menu, id: id)?.view as? MenuDetailView)?.accessibilityLabel()
    }

    private func allItems(in menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { item in
            [item] + (item.submenu.map(allItems(in:)) ?? [])
        }
    }

    private func allTitles(in menu: NSMenu) -> [String] {
        allItems(in: menu).flatMap { item -> [String] in
            [item.title, item.view?.accessibilityLabel()].compactMap { $0 }
        }
    }
}

@MainActor
private struct IdentitySnapshot {
    let itemCounts: [Int]
    let itemIDs: [ObjectIdentifier]
    let viewIDs: [ObjectIdentifier?]
    let sizes: [NSSize]
    let viewFrames: [NSRect?]

    init(_ menu: NSMenu) {
        let menus = Self.allMenus(menu)
        itemCounts = menus.map(\.numberOfItems)
        itemIDs = menus.flatMap { $0.items.map(ObjectIdentifier.init) }
        viewIDs = menus.flatMap { $0.items.map { $0.view.map(ObjectIdentifier.init) } }
        for menu in menus { menu.update() }
        sizes = menus.map(\.size)
        viewFrames = menus.flatMap { $0.items.map { $0.view?.frame } }
    }

    private static func allMenus(_ menu: NSMenu) -> [NSMenu] {
        [menu] + menu.items.compactMap(\.submenu).flatMap(allMenus)
    }
}

@main
private struct MenuRefreshMain {
    @MainActor
    static func main() {
        _ = NSApplication.shared
        // `--preview <directory>` keeps the rendered gauge PNGs, for example for the README.
        let arguments = CommandLine.arguments
        let preview = arguments.firstIndex(of: "--preview").flatMap { index in
            arguments.indices.contains(index + 1) ? URL(fileURLWithPath: arguments[index + 1], isDirectory: true) : nil
        }
        let failures = MenuRefreshHarness(previewDirectory: preview).run()
        guard failures.isEmpty else {
            for failure in failures { fputs("FAIL: \(failure)\n", stderr) }
            fputs("FAIL menu refresh regression (\(failures.count) assertions)\n", stderr)
            exit(1)
        }
        print("PASS menu refresh regression: identities, geometry, usage, states, accessibility, deferred structure, compact menu")
    }
}
