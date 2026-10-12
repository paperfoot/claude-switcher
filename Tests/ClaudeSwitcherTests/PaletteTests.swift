import Foundation
import Testing
@testable import ClaudeSwitcherCore

/// Example accounts only; nothing here reads the Mac's real accounts.
private enum Fixture {
    static let claude = [
        PaletteAccount(product: .claude, id: "work", email: "work@example.com", isSelected: true, fiveHourUsed: 40, weekUsed: 30),
        PaletteAccount(product: .claude, id: "personal", email: "personal@example.com", fiveHourUsed: 28, weekUsed: 26),
        PaletteAccount(product: .claude, id: "team199", email: "team199@example.org", fiveHourUsed: 5, weekUsed: 10),
        PaletteAccount(product: .claude, id: "lab-alpha", email: "lab-alpha@example.net", needsSignIn: true),
        PaletteAccount(product: .claude, id: "idle", email: "idle@example.net"),
    ]
    static let codex = [
        PaletteAccount(product: .codex, id: "work@example.com", email: "work@example.com", isSelected: true, fiveHourUsed: 12, weekUsed: 50),
        PaletteAccount(product: .codex, id: "team199@example.org", email: "team199@example.org", fiveHourUsed: 0, weekUsed: 3),
        PaletteAccount(product: .codex, id: "lab-alpha@example.net", email: "lab-alpha@example.net", needsSignIn: true),
    ]
    static let desktop = [
        PaletteDesktopProfile(id: "work", label: "work@example.com", isRunning: true),
        PaletteDesktopProfile(id: "personal", label: "Personal"),
    ]
    static let toggles: [PaletteToggle: Bool] = [
        .launchAtLogin: false, .shareHistory: true, .reopenAfterUpdate: true, .pauseDesktopUpdates: false, .autoSwitch: false,
    ]

    static func context(accounts: [PaletteAccount] = claude + codex, toggles: [PaletteToggle: Bool] = toggles,
                        staged: String? = "1.5.0", coordinated: Bool = true, jev: Bool = false) -> PaletteContext {
        PaletteContext(accounts: accounts, desktopProfiles: desktop, toggles: toggles,
                       stagedUpdateVersion: staged, coordinated: coordinated, jevAvailable: jev)
    }
}

private func rows(_ query: String, _ context: PaletteContext = Fixture.context(), limit: Int = 8) -> [PaletteSuggestion] {
    PaletteEngine.suggestions(for: query, context: context, limit: limit)
}

private func top(_ query: String, _ context: PaletteContext = Fixture.context()) -> PaletteAction? {
    rows(query, context).first?.action
}

struct PaletteEmptyQueryTests {
    @Test func listsFreestAccountsFirstThenPendingWorkThenSelected() {
        let titles = rows("", limit: 20).map(\.title)
        #expect(titles == [
            "Switch to team199@example.org",
            "Switch to personal@example.com",
            "Switch to idle@example.net",
            "Switch to lab-alpha@example.net",
            "Switch Codex to team199@example.org",
            "Reconnect Codex lab-alpha@example.net",
            "Install Claude Desktop update 1.5.0",
            "Add Claude account\u{2026}",
            "Turn on Auto-switch at limit",
            "Switch to work@example.com",
            "Switch Codex to work@example.com",
        ])
    }

    @Test func blankAndFillerOnlyQueriesShowTheSameList() {
        #expect(rows("   ").map(\.id) == rows("").map(\.id))
        #expect(rows("please").map(\.id) == rows("").map(\.id))
    }

    @Test func leavesOutWhatTheContextDoesNotOffer() {
        let titles = rows("", Fixture.context(toggles: [:], staged: nil), limit: 20).map(\.title)
        #expect(!titles.contains { $0.hasPrefix("Install") })
        #expect(!titles.contains { $0.contains("Auto-switch") })
        #expect(titles.contains("Add Claude account\u{2026}"))
    }

    @Test func subtitlesShowCompactUsageAndState() {
        let list = rows("", limit: 20)
        #expect(list.first { $0.id == "switchClaude:team199" }?.subtitle == "5h 5% \u{00B7} Week 10%")
        #expect(list.first { $0.id == "switchClaude:work" }?.subtitle == "5h 40% \u{00B7} Week 30% \u{00B7} selected")
        #expect(list.first { $0.id == "switchClaude:idle" }?.subtitle == "5h \u{2014} \u{00B7} Week \u{2014}")
        #expect(list.first { $0.id == "switchClaude:lab-alpha" }?.subtitle == "sign in needed")
    }

    @Test func idsAreStable() {
        let ids = Set(rows("", limit: 20).map(\.id))
        #expect(ids.isSuperset(of: ["switchClaude:team199", "switchCodex:team199@example.org",
                                    "connectCodex:lab-alpha@example.net", "command:installUpdate", "addClaude",
                                    "toggle:autoSwitch"]))
        #expect(rows("").map(\.id) == rows("").map(\.id))
    }

    @Test func outsideCoordinatedModeClaudeRowsOpenClaudeCode() {
        let first = rows("", Fixture.context(coordinated: false)).first
        #expect(first?.title == "Open Claude Code as team199@example.org")
        #expect(first?.action == .switchClaude(profileID: "team199"))
    }
}

struct PaletteHeadroomTests {
    @Test func ordersByWeekThenFiveHourThenUnknownThenAtLimitThenSignIn() {
        let accounts = [
            PaletteAccount(product: .claude, id: "signin", email: "signin@example.com", needsSignIn: true, fiveHourUsed: 0, weekUsed: 0),
            PaletteAccount(product: .claude, id: "full", email: "full@example.com", fiveHourUsed: 99, weekUsed: 5),
            PaletteAccount(product: .claude, id: "unknown", email: "unknown@example.com"),
            PaletteAccount(product: .claude, id: "b", email: "b@example.com", fiveHourUsed: 30, weekUsed: 20),
            PaletteAccount(product: .claude, id: "a", email: "a@example.com", fiveHourUsed: 10, weekUsed: 20),
            PaletteAccount(product: .claude, id: "low", email: "low@example.com", fiveHourUsed: 90, weekUsed: 1),
        ]
        #expect(PaletteEngine.headroomOrder(accounts).map(\.id) == ["low", "a", "b", "unknown", "full", "signin"])
    }

    @Test func mostHeadroomSkipsSelectedSignInAndExhaustedAccounts() {
        let accounts = [
            PaletteAccount(product: .claude, id: "selected", email: "selected@example.com", isSelected: true, fiveHourUsed: 0, weekUsed: 0),
            PaletteAccount(product: .claude, id: "signin", email: "signin@example.com", needsSignIn: true),
            PaletteAccount(product: .claude, id: "full", email: "full@example.com", fiveHourUsed: 98, weekUsed: 2),
            PaletteAccount(product: .claude, id: "spare", email: "spare@example.com", fiveHourUsed: 50, weekUsed: 60),
            PaletteAccount(product: .codex, id: "codex@example.com", email: "codex@example.com", fiveHourUsed: 0, weekUsed: 0),
        ]
        #expect(PaletteEngine.mostHeadroom(in: accounts, product: .claude)?.id == "spare")
        #expect(PaletteEngine.mostHeadroom(in: accounts, product: .codex)?.id == "codex@example.com")
        #expect(PaletteEngine.mostHeadroom(in: Array(accounts.prefix(3)), product: .claude) == nil)
    }

    @Test func bestPicksTheFreestOtherClaudeAccount() {
        let first = rows("best").first
        #expect(first?.action == .switchClaude(profileID: "team199"))
        #expect(first?.title == "Switch to team199@example.org")
        #expect(first?.subtitle?.hasSuffix("most headroom") == true)
        for word in ["free", "freest", "most", "least", "available", "quota", "headroom", "lowest", "unused"] {
            #expect(top(word) == .switchClaude(profileID: "team199"), "\(word)")
        }
        #expect(top("use the freest one") == .switchClaude(profileID: "team199"))
    }

    @Test func bestWithACodexWordPicksCodex() {
        #expect(top("best codex") == .switchCodex(email: "team199@example.org"))
        #expect(top("most quota openai") == .switchCodex(email: "team199@example.org"))
    }

    @Test func bestNeverOffersTheSelectedOrSignedOutAccount() {
        let accounts = [
            PaletteAccount(product: .claude, id: "work", email: "work@example.com", isSelected: true, fiveHourUsed: 1, weekUsed: 1),
            PaletteAccount(product: .claude, id: "lab", email: "lab@example.com", needsSignIn: true),
            PaletteAccount(product: .claude, id: "busy", email: "busy@example.com", fiveHourUsed: 70, weekUsed: 80),
        ]
        let first = rows("best", Fixture.context(accounts: accounts)).first
        #expect(first?.action == .switchClaude(profileID: "busy"))
        #expect(first?.subtitle?.contains("most headroom") == true)
    }
}

struct PaletteAccountMatchingTests {
    @Test func prefixesOfTheLocalPartMatch() {
        #expect(top("per") == .switchClaude(profileID: "personal"))
        #expect(top("p") == .switchClaude(profileID: "personal"))
        #expect(top("tea") == .switchClaude(profileID: "team199"))
    }

    @Test func lettersAndDigitsAreFoundSeparately() {
        #expect(top("199") == .switchClaude(profileID: "team199"))
        #expect(top("alpha") == .switchClaude(profileID: "lab-alpha"))
        #expect(top("lab alpha") == .switchClaude(profileID: "lab-alpha"))
        #expect(top("labalpha") == .switchClaude(profileID: "lab-alpha"))
    }

    @Test func domainsMatchWithAndWithoutTheTopLevelDomain() {
        #expect(top("example.org") == .switchClaude(profileID: "team199"))
        #expect(top("@example.org") == .switchClaude(profileID: "team199"))
        let net = rows("example.net").prefix(2).map(\.action)
        #expect(Set(net) == [.switchClaude(profileID: "lab-alpha"), .switchClaude(profileID: "idle")])
    }

    @Test func smallTyposStillFindTheAccount() {
        #expect(top("persnal") == .switchClaude(profileID: "personal"))
        #expect(top("peronsal") == .switchClaude(profileID: "personal"))
        #expect(top("teem199") == .switchClaude(profileID: "team199"))
        #expect(top("persn") == .switchClaude(profileID: "personal"))
        // Two typos are allowed from eight characters.
        #expect(top("lab-alhpa@exampel.net") == .switchClaude(profileID: "lab-alpha"))
    }

    @Test func shortWordsAreNotGuessed() {
        #expect(!rows("wrk").contains { $0.action == .switchClaude(profileID: "work") })
    }

    @Test func emailsAreRecognisedAnywhere() {
        #expect(top("please switch me to team199@example.org now") == .switchClaude(profileID: "team199"))
        #expect(top("PERSONAL@EXAMPLE.COM") == .switchClaude(profileID: "personal"))
        #expect(top("work@") == .switchClaude(profileID: "work"))
    }

    @Test func fillerWordsAreIgnored() {
        #expect(top("switch to the work account please") == .switchClaude(profileID: "work"))
        #expect(top("go to my personal one now") == .switchClaude(profileID: "personal"))
    }

    @Test func switchVerbsAndATypoInOneStillSwitch() {
        for verb in ["switch", "use", "select", "change", "go", "swap", "pick", "choose", "set", "swich", "slect"] {
            #expect(top("\(verb) personal") == .switchClaude(profileID: "personal"), "\(verb)")
        }
    }

    @Test func aWordThatNamesAnAccountIsNotReadAsAVerb() {
        let accounts = [PaletteAccount(product: .claude, id: "swatch", email: "swatch@example.com", fiveHourUsed: 1, weekUsed: 1),
                        PaletteAccount(product: .claude, id: "other", email: "other@example.com", fiveHourUsed: 1, weekUsed: 1)]
        #expect(top("swatch", Fixture.context(accounts: accounts)) == .switchClaude(profileID: "swatch"))
    }

    @Test func claudeRanksFirstWhenNoProductIsNamedButCodexStays() {
        let actions = rows("team").map(\.action)
        #expect(actions.first == .switchClaude(profileID: "team199"))
        #expect(actions.dropFirst().first == .switchCodex(email: "team199@example.org"))
    }

    @Test func aProductWordKeepsOnlyThatProduct() {
        let codex = rows("codex team")
        #expect(codex.first?.action == .switchCodex(email: "team199@example.org"))
        #expect(!codex.contains { if case .switchClaude = $0.action { return true }; return false })
        let claude = rows("claude team")
        #expect(claude.first?.action == .switchClaude(profileID: "team199"))
        #expect(!claude.contains { if case .switchCodex = $0.action { return true }; return false })
        #expect(rows("chatgpt").allSatisfy { $0.title.contains("Codex") })
    }

    @Test func codexAccountsThatNeedSignInOfferReconnecting() {
        let first = rows("codex lab").first
        #expect(first?.action == .connectCodex(email: "lab-alpha@example.net"))
        #expect(first?.title == "Reconnect Codex lab-alpha@example.net")
        #expect(first?.subtitle == "sign in needed")
    }

    @Test func signInWordsWithCodexReconnect() {
        #expect(top("reconnect codex team") == .connectCodex(email: "team199@example.org"))
        #expect(top("log in codex team199") == .connectCodex(email: "team199@example.org"))
        #expect(top("sign in to codex team") == .connectCodex(email: "team199@example.org"))
        // Without a name, the account that needs it comes first.
        #expect(top("connect codex") == .connectCodex(email: "lab-alpha@example.net"))
        #expect(top("login codex") == .connectCodex(email: "lab-alpha@example.net"))
    }

    @Test func signedOutAccountsComeLastUnlessSigningIn() {
        #expect(top("alpha") == .switchClaude(profileID: "lab-alpha"))
        let listed = rows("switch").map(\.action)
        let signedOut = listed.firstIndex(of: .switchClaude(profileID: "lab-alpha"))
        for id in ["team199", "personal", "idle"] {
            let index = listed.firstIndex(of: .switchClaude(profileID: id))
            #expect(index != nil && signedOut != nil && index! < signedOut!, "\(id)")
        }
        #expect(rows("login").contains { $0.action == .switchClaude(profileID: "lab-alpha") })
        let claude = rows("log in claude").filter { if case .switchClaude = $0.action { return true }; return false }
        #expect(claude.first?.action == .switchClaude(profileID: "lab-alpha"))
    }

    @Test func otherAccountActionsNeedTheirVerb() {
        #expect(top("open personal") == .openDesktop(profileID: "personal"))
        #expect(top("desktop work") == .openDesktop(profileID: "work"))
        #expect(top("copy team") == .copyTerminalCommand(profileID: "team199"))
        #expect(top("terminal command for personal") == .copyTerminalCommand(profileID: "personal"))
        #expect(top("rename per") == .renameClaude(profileID: "personal"))
        let row = rows("open personal").first
        #expect(row?.title == "Open Claude Desktop: Personal")
    }
}

struct PaletteAddAndRemoveTests {
    @Test func addingANewEmail() {
        let first = rows("add new@example.com").first
        #expect(first?.action == .addClaude(email: "new@example.com"))
        #expect(first?.title == "Add Claude account new@example.com")
        #expect(top("create someone@example.org") == .addClaude(email: "someone@example.org"))
        #expect(top("connect new@example.com") == .addClaude(email: "new@example.com"))
    }

    @Test func aTypedNewEmailOffersToAddItEvenWithoutAVerb() {
        #expect(top("new.person@example.com") == .addClaude(email: "new.person@example.com"))
    }

    @Test func addingAnExistingEmailSwitchesToItInstead() {
        let first = rows("add personal@example.com").first
        #expect(first?.action == .switchClaude(profileID: "personal"))
        #expect(first?.subtitle?.contains("already added") == true)
        #expect(!rows("add personal@example.com").contains { if case .addClaude = $0.action { return true }; return false })
    }

    @Test func addWithoutAnEmailAsksForOne() {
        let first = rows("add").first
        #expect(first?.action == .addClaude(email: nil))
        #expect(first?.title == "Add Claude account\u{2026}")
        #expect(top("new account") == .addClaude(email: nil))
    }

    @Test func removeIsDestructiveAndNeedsItsVerb() {
        let first = rows("remove lab").first
        #expect(first?.action == .removeClaude(profileID: "lab-alpha"))
        #expect(first?.title == "Remove lab-alpha@example.net")
        #expect(first?.isDestructive == true)
        #expect(top("delete personal") == .removeClaude(profileID: "personal"))
        #expect(top("forget team199") == .removeClaude(profileID: "team199"))
        #expect(!rows("lab").contains { $0.isDestructive })
        #expect(!rows("personal").contains { $0.isDestructive })
    }

    @Test func aMisspeltRemoveIsNotGuessed() {
        #expect(!rows("remvoe lab").contains { $0.isDestructive })
    }

    @Test func onlyRemoveRowsAreDestructive() {
        for query in ["", "work", "best", "history", "codex", "quit", "add new@example.com"] {
            #expect(!rows(query, limit: 20).contains { $0.isDestructive }, "\(query)")
        }
    }
}

struct PaletteSettingsAndCommandsTests {
    @Test func togglesSayWhatTheyWillDo() {
        let context = Fixture.context()
        #expect(rows("startup", context).first?.title == "Turn on Open at login")
        #expect(rows("share history", context).first?.title == "Turn off Share Desktop Code history")
        #expect(rows("pause updates", context).first?.title == "Turn on Pause Desktop updates")
        #expect(rows("reopen", context).first?.title == "Turn off Reopen Desktop after updates")
        let flipped = Fixture.context(toggles: [.launchAtLogin: true, .pauseDesktopUpdates: true])
        #expect(rows("startup", flipped).first?.title == "Turn off Open at login")
        #expect(rows("pause updates", flipped).first?.title == "Turn off Pause Desktop updates")
    }

    @Test func unavailableTogglesAreLeftOut() {
        let context = Fixture.context(toggles: [:])
        #expect(!rows("startup", context).contains { if case .toggle = $0.action { return true }; return false })
    }

    @Test func askingForTheCurrentStateSaysSoAndStaysOffTheTop() {
        let rows = rows("turn on history")
        let toggle = rows.first { $0.action == .toggle(.shareHistory) }
        #expect(toggle?.subtitle == "Already on")
        #expect(rows.first?.action != .toggle(.shareHistory))
        #expect(top("turn off history") == .toggle(.shareHistory))
        #expect(top("resume updates", Fixture.context(toggles: [.pauseDesktopUpdates: true])) == .toggle(.pauseDesktopUpdates))
    }

    @Test func aBareKeywordDoesNotPutTurningOffUnderReturn() {
        #expect(top("history") == .command(.syncHistory))
        #expect(top("history", Fixture.context(toggles: [.shareHistory: false])) == .toggle(.shareHistory))
    }

    @Test func commandsAreFoundByKeyword() {
        let expected: [(String, PaletteAction)] = [
            ("diag", .command(.diagnostics)), ("diagnostics", .command(.diagnostics)), ("debug", .command(.diagnostics)),
            ("log", .command(.openSwitchLog)), ("logs", .command(.openSwitchLog)), ("open log", .command(.openSwitchLog)),
            ("login item", .toggle(.launchAtLogin)), ("open at login", .toggle(.launchAtLogin)), ("startup", .toggle(.launchAtLogin)),
            ("sync", .command(.syncHistory)), ("undo", .command(.undoHistory)),
            ("update", .command(.installUpdate)), ("updates", .command(.installUpdate)),
            ("chrome", .command(.connectChrome)), ("extension", .command(.connectChrome)), ("companion", .command(.connectChrome)),
            ("connect", .command(.connectChrome)), ("set up chrome", .command(.connectChrome)),
            ("refresh", .command(.refreshUsage)), ("quit", .command(.quit)), ("exit", .command(.quit)), ("q", .command(.quit)),
            ("app", .command(.chooseClaudeApp)), ("claude.app", .command(.chooseClaudeApp)),
        ]
        for (query, action) in expected {
            #expect(top(query) == action, "\(query)")
        }
    }

    @Test func installUpdateNamesTheVersionAndOnlyAppearsWhenStaged() {
        #expect(rows("update").first?.title == "Install Claude Desktop update 1.5.0")
        let unstaged = rows("update", Fixture.context(staged: nil))
        #expect(!unstaged.contains { $0.action == .command(.installUpdate) })
        #expect(unstaged.first?.action == .toggle(.pauseDesktopUpdates))
    }

    @Test func commandTitlesArePlain() {
        let titles = Set(PaletteEngine.allCandidates(context: Fixture.context()).map(\.title))
        #expect(titles.isSuperset(of: ["Connect Chrome\u{2026}", "Diagnostics\u{2026}", "Open switch log",
                                       "Sync Desktop history now", "Undo last history sync", "Choose Claude.app\u{2026}",
                                       "Install Claude Desktop update 1.5.0", "Refresh usage", "Quit Claude Switcher"]))
    }

    @Test func listingWordsListTheirRows() {
        #expect(rows("codex").allSatisfy { $0.title.contains("Codex") })
        #expect(rows("remove").allSatisfy { $0.isDestructive })
        #expect(rows("desktop").first?.action == .openDesktop(profileID: "work"))
        #expect(rows("toggle").allSatisfy { if case .toggle = $0.action { return true }; return false })
    }
}

struct PaletteAutoSwitchTests {
    @Test func autoSwitchIsASettingNearTheEndOfTheEmptyList() {
        let list = rows("", limit: 20)
        let index = list.firstIndex { $0.action == .toggle(.autoSwitch) }
        let add = list.firstIndex { $0.action == .addClaude(email: nil) }
        #expect(index != nil && add != nil && index! == add! + 1)
        #expect(list[index!].title == "Turn on Auto-switch at limit")
        let on = rows("", Fixture.context(toggles: [.autoSwitch: true]), limit: 20)
        #expect(on.contains { $0.title == "Turn off Auto-switch at limit" })
    }

    @Test func autoSwitchKeywordsFindIt() {
        for word in ["auto", "automatic", "limit", "seamless", "rotate", "auto switch", "auto-switch"] {
            #expect(top(word) == .toggle(.autoSwitch), "\(word)")
        }
        #expect(top("turn off auto switch", Fixture.context(toggles: [.autoSwitch: true])) == .toggle(.autoSwitch))
    }

    @Test func autoSwitchIsACandidateForJev() {
        let candidates = PaletteEngine.allCandidates(context: Fixture.context())
        #expect(candidates.contains { $0.id == "toggle:autoSwitch" && $0.title == "Turn on Auto-switch at limit" })
        let without = PaletteEngine.allCandidates(context: Fixture.context(toggles: [:]))
        #expect(!without.contains { $0.action == .toggle(.autoSwitch) })
    }
}

struct PaletteJevAndLimitTests {
    @Test func unmatchedRequestsOfferJevLast() {
        let list = rows("make personal the default for chrome", Fixture.context(jev: true))
        let last = list.last
        #expect(last?.action == .askJev("make personal the default for chrome"))
        #expect(last?.title == "Ask: \u{201C}make personal the default for chrome\u{201D}")
        #expect(last?.symbol == "sparkles")
        #expect(rows("what is the weather", Fixture.context(jev: true)).map(\.action) == [.askJev("what is the weather")])
    }

    @Test func withoutJevAnUnmatchedRequestIsEmpty() {
        #expect(rows("what is the weather").isEmpty)
    }

    @Test func jevIsNotOfferedForGoodMatchesOrTinyQueries() {
        let context = Fixture.context(jev: true)
        #expect(!rows("personal", context).contains { if case .askJev = $0.action { return true }; return false })
        #expect(!rows("switch to the work account please", context).contains { if case .askJev = $0.action { return true }; return false })
        #expect(rows("zzq", context).isEmpty)
    }

    @Test func theJevRowKeepsAStableIdWhileTyping() {
        let context = Fixture.context(jev: true)
        #expect(rows("what is the", context).last?.id == "askJev")
        #expect(rows("what is the weather", context).last?.id == "askJev")
    }

    @Test func neverMoreThanTheLimit() {
        for limit in [1, 3, 8] {
            #expect(rows("", limit: limit).count == limit)
            #expect(rows("e", limit: limit).count <= limit)
            #expect(rows("example", limit: limit).count <= limit)
        }
        #expect(rows("", limit: 0).isEmpty)
        let jev = rows("make personal the default for chrome", Fixture.context(jev: true), limit: 1)
        #expect(jev.map(\.action) == [.askJev("make personal the default for chrome")])
    }

    @Test func rankingIsDeterministic() {
        for query in ["", "e", "example", "best", "remove", "team", "update"] {
            #expect(rows(query, limit: 20) == rows(query, limit: 20), "\(query)")
        }
    }

    @Test func allCandidatesCoversEveryActionTheContextAllows() {
        let candidates = PaletteEngine.allCandidates(context: Fixture.context(), query: "add someone@example.org please")
        let actions = Set(candidates.map(\.action))
        for account in Fixture.claude {
            #expect(actions.isSuperset(of: [.switchClaude(profileID: account.id), .removeClaude(profileID: account.id),
                                            .renameClaude(profileID: account.id), .copyTerminalCommand(profileID: account.id)]))
        }
        #expect(actions.isSuperset(of: [.switchCodex(email: "team199@example.org"), .connectCodex(email: "team199@example.org"),
                                        .connectCodex(email: "lab-alpha@example.net"), .openDesktop(profileID: "personal"),
                                        .addClaude(email: nil), .addClaude(email: "someone@example.org")]))
        #expect(!actions.contains(.switchCodex(email: "lab-alpha@example.net")))
        #expect(actions.isSuperset(of: Set(PaletteToggle.allCases.map(PaletteAction.toggle))))
        #expect(actions.isSuperset(of: Set(PaletteCommand.allCases.map(PaletteAction.command))))
        #expect(Set(candidates.map(\.id)).count == candidates.count)
        let unstaged = Set(PaletteEngine.allCandidates(context: Fixture.context(staged: nil)).map(\.action))
        #expect(!unstaged.contains(.command(.installUpdate)))
    }
}

@Suite("Destructive defaults")
struct PaletteDestructiveDefaultTests {
    @Test("A remove verb that starts an account name is read as the name")
    func removePrefixIsAName() {
        let accounts = [
            PaletteAccount(product: .claude, id: "delta", email: "delta@example.com", fiveHourUsed: 10, weekUsed: 10),
            PaletteAccount(product: .claude, id: "team", email: "team@example.com", fiveHourUsed: 20, weekUsed: 20),
        ]
        let context = PaletteContext(accounts: accounts, coordinated: true)
        for query in ["del", "delt"] {
            let first = PaletteEngine.suggestions(for: query, context: context).first
            #expect(first?.isDestructive == false, "\(query) must not default to Remove")
            #expect(first?.action == .switchClaude(profileID: "delta"))
        }
    }
}
