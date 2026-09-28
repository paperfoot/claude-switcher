import AppKit
import ClaudeSwitcherCore
import Darwin

@MainActor
private final class MenuRefreshHarness {
    private var failures: [String] = []

    private let now: Date
    private let midnightReset: Date

    init() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 28, hour: 23, minute: 50))!
        midnightReset = calendar.date(from: DateComponents(year: 2026, month: 9, day: 29, hour: 0, minute: 5))!
    }

    func run() -> [String] {
        let target = NSObject()
        let initial = makeInitialInput()
        let menu = MenuBuilder.build(initial, target: target, actions: actions())

        check(menu.minimumWidth == UsageBarView.preferredWidth, "menu keeps the fixed native minimum width")
        expectRows(in: menu, id: "claude-switcher.live-usage.alpha", [0, 9])
        expectRows(in: menu, id: "claude-switcher.live-usage.beta", [99, 100], cached: true)
        expectRows(in: menu, id: "claude-switcher.live-usage.gamma", [nil, nil])
        expectRows(in: menu, id: "codex.usage.delta@example.test", [9, 99])
        expectRows(in: menu, id: "codex.usage.echo@example.test", [100, 0], cached: true)
        check(item(in: menu, id: "codex.usage.foxtrot@example.test") == nil,
              "disconnected Codex account has no usage row initially")

        let initialAlphaLabel = accessibilityLabel(in: menu, id: "claude-switcher.live-usage.alpha")
        check(initialAlphaLabel?.contains("0%") == true && initialAlphaLabel?.contains("9%") == true,
              "initial accessibility label contains the live percentages")
        check(usageView(in: menu, id: "claude-switcher.live-usage.alpha")?.rows.first?.trailing == "↻ Tue 00:05",
              "reset just after midnight includes the next day and clock time")
        checkCustomViewTitles(in: menu)

        check(menu.size.width >= UsageBarView.preferredWidth && menu.size.height > 0,
              "AppKit measures a real nonzero menu, not an uninitialized size")
        let baseline = IdentitySnapshot(menu)
        var busy = makeUpdatedInput()
        busy.isBusy = true
        busy.codexBusy = true
        busy.switching = true
        MenuBuilder.updateVisible(in: menu, input: busy)

        expectUnchanged(menu, from: baseline, context: "busy refresh")
        expectRows(in: menu, id: "claude-switcher.live-usage.alpha", [100, 99])
        expectRows(in: menu, id: "claude-switcher.live-usage.beta", [nil, nil], cached: true)
        expectRows(in: menu, id: "claude-switcher.live-usage.gamma", [9, 0])
        expectRows(in: menu, id: "codex.usage.delta@example.test", [0, 9])
        expectRows(in: menu, id: "codex.usage.echo@example.test", [99, 100], cached: true)
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
        check(updatedAlphaLabel?.contains("100%") == true && updatedAlphaLabel?.contains("99%") == true,
              "updated accessibility label contains the new percentages")
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

        return failures
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
            "alpha": snapshot("alpha@example.test", age: 30, five: 0, week: 9,
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
            usage: desktopUsage(profiles: profiles),
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
            usage: desktopUsage(profiles: profiles),
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
            codex("delta@example.test", connected: true, active: true, five: 9, week: 99, age: 20),
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

    private func desktopUsage(profiles: [Profile]) -> [String: UsageReading] {
        Dictionary(uniqueKeysWithValues: profiles.enumerated().compactMap { index, profile in
            let sample = UsageSample(sampledAt: now.addingTimeInterval(-120), org: "fictional-org-\(index)",
                                     utilization: ["fh": index * 9, "sd": 99 - index * 9])
            return UsageReading.make(samples: [sample], now: now).map { (profile.id, $0) }
        })
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

    private func expectRows(in menu: NSMenu, id: String, _ expected: [Int?], cached: Bool? = nil) {
        guard let rows = usageView(in: menu, id: id)?.rows else {
            failures.append("missing usage view \(id)")
            return
        }
        check(rows.map(\.percent) == expected, "\(id) percentages are \(expected)")
        if let cached {
            check(rows.allSatisfy { $0.isCached == cached }, "\(id) cached state is \(cached)")
        }
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
        let failures = MenuRefreshHarness().run()
        guard failures.isEmpty else {
            for failure in failures { fputs("FAIL: \(failure)\n", stderr) }
            fputs("FAIL menu refresh regression (\(failures.count) assertions)\n", stderr)
            exit(1)
        }
        print("PASS menu refresh regression: identities, geometry, usage, states, accessibility, deferred structure")
    }
}
