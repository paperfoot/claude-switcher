import Foundation

// MARK: - Palette inputs

/// One account the command palette can act on, as the app last verified it.
public struct PaletteAccount: Sendable, Equatable {
    public enum Product: String, Sendable { case claude, codex }

    public let product: Product
    /// Claude: the profile id. Codex: the configured account email.
    public let id: String
    public let email: String
    /// The account currently selected for this product.
    public let isSelected: Bool
    /// Signed out, never connected, or its saved login expired.
    public let needsSignIn: Bool
    /// Percentage of the five-hour and weekly limits used, when known.
    public let fiveHourUsed: Int?
    public let weekUsed: Int?

    public init(product: Product, id: String, email: String, isSelected: Bool = false,
                needsSignIn: Bool = false, fiveHourUsed: Int? = nil, weekUsed: Int? = nil) {
        self.product = product
        self.id = id
        self.email = email
        self.isSelected = isSelected
        self.needsSignIn = needsSignIn
        self.fiveHourUsed = fiveHourUsed
        self.weekUsed = weekUsed
    }
}

/// A Claude Desktop profile the palette can open.
public struct PaletteDesktopProfile: Sendable, Equatable {
    public let id: String
    public let label: String
    public let isRunning: Bool

    public init(id: String, label: String, isRunning: Bool = false) {
        self.id = id
        self.label = label
        self.isRunning = isRunning
    }
}

/// Settings that flip between on and off.
public enum PaletteToggle: String, Sendable, CaseIterable, Hashable {
    case launchAtLogin, shareHistory, reopenAfterUpdate, pauseDesktopUpdates
    /// Move the active Claude account to the one with the most headroom when it nears a limit.
    case autoSwitch
}

/// One-shot commands without an account argument.
public enum PaletteCommand: String, Sendable, CaseIterable, Hashable {
    case connectChrome, diagnostics, openSwitchLog, syncHistory, undoHistory,
         chooseClaudeApp, installUpdate, refreshUsage, quit
}

/// Everything the palette knows when it ranks suggestions. Built by the app; never does I/O.
public struct PaletteContext: Sendable {
    public var accounts: [PaletteAccount]
    public var desktopProfiles: [PaletteDesktopProfile]
    /// Current state of each toggle; a missing entry means the toggle is unavailable.
    public var toggles: [PaletteToggle: Bool]
    /// Set when Claude Desktop has downloaded an update that waits for its profiles to quit.
    public var stagedUpdateVersion: String?
    /// Coordinated mode: selecting a Claude account switches Chrome and Claude Code together.
    public var coordinated: Bool
    /// A TypeSafe key is stored, so free-form requests can be interpreted by Jev.
    public var jevAvailable: Bool
    /// Usage percentage at which automatic switching moves on, for the setting's description.
    public var autoSwitchThreshold: Int

    public init(accounts: [PaletteAccount] = [], desktopProfiles: [PaletteDesktopProfile] = [],
                toggles: [PaletteToggle: Bool] = [:], stagedUpdateVersion: String? = nil,
                coordinated: Bool = true, jevAvailable: Bool = false, autoSwitchThreshold: Int = 95) {
        self.autoSwitchThreshold = autoSwitchThreshold
        self.accounts = accounts
        self.desktopProfiles = desktopProfiles
        self.toggles = toggles
        self.stagedUpdateVersion = stagedUpdateVersion
        self.coordinated = coordinated
        self.jevAvailable = jevAvailable
    }
}

// MARK: - Palette outputs

/// What happens when a suggestion is chosen. The app performs it; destructive actions
/// still confirm in the app before anything changes.
public enum PaletteAction: Sendable, Equatable, Hashable {
    case switchClaude(profileID: String)
    case switchCodex(email: String)
    case connectCodex(email: String)
    /// `nil` asks for the email first.
    case addClaude(email: String?)
    case removeClaude(profileID: String)
    case renameClaude(profileID: String)
    case openDesktop(profileID: String)
    case copyTerminalCommand(profileID: String)
    case toggle(PaletteToggle)
    case command(PaletteCommand)
    /// Send the typed request to Jev and offer its interpretation.
    case askJev(String)
}

/// One row in the palette.
public struct PaletteSuggestion: Sendable, Equatable, Identifiable {
    /// Stable across keystrokes, so the selection survives re-ranking.
    public let id: String
    public let action: PaletteAction
    public let title: String
    public let subtitle: String?
    /// SF Symbol name.
    public let symbol: String
    public let isDestructive: Bool
    /// Higher is better; only meaningful within one result list.
    public let score: Double

    public init(id: String, action: PaletteAction, title: String, subtitle: String? = nil,
                symbol: String, isDestructive: Bool = false, score: Double) {
        self.id = id
        self.action = action
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.isDestructive = isDestructive
        self.score = score
    }

    /// The same row with a different score, for example a probability from Jev.
    public func with(score: Double) -> PaletteSuggestion {
        PaletteSuggestion(id: id, action: action, title: title, subtitle: subtitle,
                          symbol: symbol, isDestructive: isDestructive, score: score)
    }
}

// MARK: - Engine

/// Turns what the user typed into ranked suggestions. Pure and synchronous, cheap enough to
/// run on every keystroke.
///
/// A row's score says how well the typed words fit it, roughly 0…1.2. Account rows match the
/// words against the email: the whole address, the local part, its letter and digit runs
/// ("team199" → "team", "199") and the domain, by prefix, substring or a small typo.
/// Settings and commands match keywords and the words of their title. Verbs ("switch",
/// "remove", "open"…) and product words ("codex", "claude") do not need to match any text:
/// they decide which kind of row wins.
public enum PaletteEngine {
    /// Below this top score nothing matched well, and longer requests are offered to Jev.
    public static let confidentScore = 0.5
    /// At or above this share of either window an account has no headroom left.
    public static let limitPercent = 98

    public static func suggestions(for query: String, context: PaletteContext, limit: Int = 8) -> [PaletteSuggestion] {
        guard limit > 0 else { return [] }
        let ranker = PaletteRanker(text: query, context: context)
        if ranker.query.isBlank { return Array(emptyQuery(context).prefix(limit)) }
        let ranked = ranker.ranked()
        guard context.jevAvailable, ranker.query.isSubstantial,
              (ranked.first?.score ?? 0) < confidentScore else { return Array(ranked.prefix(limit)) }
        return Array(ranked.prefix(limit - 1)) + [PaletteRows.askJev(ranker.query.text)]
    }

    /// Every action the context allows, for Jev to choose from. Emails in `query` that are not
    /// saved yet are offered as "Add Claude account <email>". Scores are not meaningful here.
    public static func allCandidates(context: PaletteContext, query: String = "") -> [PaletteSuggestion] {
        let claude = selectedLast(headroomOrder(context.accounts.filter { $0.product == .claude }))
        let codex = selectedLast(headroomOrder(context.accounts.filter { $0.product == .codex }))
        var rows = claude.map { PaletteRows.switchClaude($0, context: context, score: 0) }
        for account in codex {
            rows.append(PaletteRows.codexDefault(account, score: 0))
            if !account.needsSignIn { rows.append(PaletteRows.reconnectCodex(account, score: 0)) }
        }
        rows += context.desktopProfiles.map { PaletteRows.openDesktop($0, score: 0) }
        rows.append(PaletteRows.addClaude(email: nil, score: 0))
        let saved = Set(claude.map { $0.email.lowercased() })
        for email in PaletteQuery(query).emails where !saved.contains(email) {
            rows.append(PaletteRows.addClaude(email: email, score: 0))
        }
        rows += claude.map { PaletteRows.copyCommand($0, score: 0) }
        rows += claude.map { PaletteRows.rename($0, score: 0) }
        rows += claude.map { PaletteRows.remove($0, score: 0) }
        for entry in PaletteCatalog.entries(for: context) {
            rows.append(PaletteRows.entry(entry, context: context, score: 0))
        }
        return rows
    }

    /// Most headroom first: the lowest weekly use, then the lowest five-hour use. Accounts with
    /// unknown usage follow, then accounts at their limit (`limitPercent`), then accounts that
    /// need to sign in again. Ties fall back to the email, so the order is stable.
    public static func headroomOrder(_ accounts: [PaletteAccount]) -> [PaletteAccount] {
        accounts.sorted { headroomKey($0) < headroomKey($1) }
    }

    /// The account to move to when the current one runs low: not selected, signed in and below
    /// its limits. It may have unknown usage; check `weekUsed` and `fiveHourUsed` when that matters.
    public static func mostHeadroom(in accounts: [PaletteAccount], product: PaletteAccount.Product) -> PaletteAccount? {
        headroomOrder(accounts.filter {
            $0.product == product && !$0.isSelected && !$0.needsSignIn && !isAtLimit($0)
        }).first
    }

    static func isAtLimit(_ account: PaletteAccount) -> Bool {
        (account.weekUsed ?? 0) >= limitPercent || (account.fiveHourUsed ?? 0) >= limitPercent
    }

    static func hasUsage(_ account: PaletteAccount) -> Bool {
        account.weekUsed != nil || account.fiveHourUsed != nil
    }

    private static func headroomKey(_ account: PaletteAccount) -> (Int, Int, Int, String, String) {
        let tier: Int
        if account.needsSignIn { tier = 3 }
        else if !hasUsage(account) { tier = 1 }
        else if isAtLimit(account) { tier = 2 }
        else { tier = 0 }
        return (tier, account.weekUsed ?? 101, account.fiveHourUsed ?? 101, account.email.lowercased(), account.id)
    }

    private static func selectedLast(_ accounts: [PaletteAccount]) -> [PaletteAccount] {
        accounts.filter { !$0.isSelected } + accounts.filter(\.isSelected)
    }

    /// Nothing typed: the accounts worth switching to, then what is pending, then the selected ones.
    static func emptyQuery(_ context: PaletteContext) -> [PaletteSuggestion] {
        let claude = headroomOrder(context.accounts.filter { $0.product == .claude })
        let codex = headroomOrder(context.accounts.filter { $0.product == .codex })
        var makers: [(Double) -> PaletteSuggestion] = []
        for account in claude where !account.isSelected {
            makers.append { PaletteRows.switchClaude(account, context: context, score: $0) }
        }
        for account in codex where !account.isSelected {
            makers.append { PaletteRows.codexDefault(account, score: $0) }
        }
        if context.stagedUpdateVersion != nil {
            makers.append { PaletteRows.entry(PaletteCatalog.entry(.installUpdate, context: context), context: context, score: $0) }
        }
        makers.append { PaletteRows.addClaude(email: nil, score: $0) }
        if context.toggles[.autoSwitch] != nil {
            makers.append { PaletteRows.entry(PaletteCatalog.entry(.autoSwitch, context: context), context: context, score: $0) }
        }
        for account in claude where account.isSelected {
            makers.append { PaletteRows.switchClaude(account, context: context, score: $0) }
        }
        for account in codex where account.isSelected {
            makers.append { PaletteRows.codexDefault(account, score: $0) }
        }
        return makers.enumerated().map { index, make in make(1 - Double(index) * 0.01) }
    }
}

// MARK: - Query

/// What the palette understood from the typed text.
struct PaletteQuery {
    enum Verb: Hashable { case switchTo, signIn, reconnect, connect, add, remove, rename, open, copy }

    /// The trimmed text as typed.
    let text: String
    /// Emails found anywhere in the text, lowercased, in order of appearance.
    let emails: [String]
    /// Every other word, folded to lowercase, filler included. "log in" and "sign in" are one word.
    let words: [String]
    /// Indexes of `words` that are not filler.
    let termIndexes: [Int]
    /// Indexes of words that steer rather than name something: verbs, products, on/off,
    /// headroom words and generic setting words.
    let steeringIndexes: Set<Int>
    /// Indexes of product words ("codex", "claude").
    let productIndexes: Set<Int>
    /// The words that can name an account, followed by the emails.
    let content: [String]
    let verbs: Set<Verb>
    let product: PaletteAccount.Product?
    let wantsHeadroom: Bool
    /// "on"/"enable" is `true`, "off"/"disable" is `false`.
    let desiredState: Bool?

    /// Only filler, or nothing at all.
    var isBlank: Bool { emails.isEmpty && termIndexes.isEmpty }
    /// Long enough to be a request in words rather than a search: two words, or eight characters.
    var isSubstantial: Bool { text.split(whereSeparator: \.isWhitespace).count >= 2 || text.count >= 8 }

    /// - Parameter isAccountWord: names a saved account; such a word is matched as a name even
    ///   when it looks like a verb or product word ("chrome", or "swatch" next to "switch").
    init(_ raw: String, isAccountWord: (String, _ exactOnly: Bool) -> Bool = { _, _ in false }) {
        text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
        var emails: [String] = []
        let whole = NSRange(folded.startIndex..., in: folded)
        for match in Self.emailPattern.matches(in: folded, range: whole).reversed() {
            guard let range = Range(match.range, in: folded) else { continue }
            emails.insert(String(folded[range]), at: 0)
            folded.replaceSubrange(range, with: " ")
        }
        self.emails = emails.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }

        var pieces: [String] = []
        var current = ""
        for character in folded {
            if character.isLetter || character.isNumber || "@._+-".contains(character) {
                current.append(character)
            } else if !current.isEmpty {
                pieces.append(current)
                current = ""
            }
        }
        if !current.isEmpty { pieces.append(current) }
        let edges = CharacterSet(charactersIn: "._+-")
        pieces = pieces.map { $0.trimmingCharacters(in: edges) }.filter { !$0.isEmpty }
        var words: [String] = []
        var index = 0
        while index < pieces.count {
            let word = pieces[index]
            if index + 1 < pieces.count, ["log", "sign"].contains(word), ["in", "on"].contains(pieces[index + 1]) {
                words.append(word + "in")
                index += 2
            } else {
                words.append(word)
                index += 1
            }
        }
        self.words = words

        var termIndexes: [Int] = []
        var steering = Set<Int>()
        var productIndexes = Set<Int>()
        var content: [String] = []
        var verbs = Set<Verb>()
        var products = Set<PaletteAccount.Product>()
        var wantsHeadroom = false
        var desiredState: Bool?
        for (position, word) in words.enumerated() {
            if let state = Self.stateWords[word] { desiredState = state }
            if Self.filler.contains(word) { continue }
            termIndexes.append(position)
            if let verb = Self.verbs[word], !isAccountWord(word, true) {
                verbs.insert(verb)
            } else if let product = Self.products[word], !isAccountWord(word, true) {
                products.insert(product)
                productIndexes.insert(position)
            } else if Self.stateWords[word] != nil || Self.settingWords.contains(word) {
                // Steers settings only.
            } else if Self.headroomWords.contains(word), !isAccountWord(word, true) {
                wantsHeadroom = true
            } else if let verb = Self.fuzzy(word, in: Self.typoVerbs), !isAccountWord(word, false) {
                verbs.insert(verb)
            } else if let product = Self.fuzzy(word, in: Self.typoProducts), !isAccountWord(word, false) {
                products.insert(product)
                productIndexes.insert(position)
            } else {
                content.append(word)
                continue
            }
            steering.insert(position)
        }
        termIndexes.sort()
        self.termIndexes = termIndexes
        self.steeringIndexes = steering
        self.productIndexes = productIndexes
        self.content = content + self.emails
        self.verbs = verbs
        self.product = products.count == 1 ? products.first : nil
        self.wantsHeadroom = wantsHeadroom
        self.desiredState = desiredState
    }

    /// Indexes of the words covered by any of `phrases`. The last word typed may be unfinished.
    func coverage(of phrases: [[String]]) -> Set<Int> {
        var covered = Set<Int>()
        for phrase in phrases where !phrase.isEmpty && phrase.count <= words.count {
            for start in 0...(words.count - phrase.count) {
                let matches = phrase.enumerated().allSatisfy { offset, part in
                    let position = start + offset
                    let word = words[position]
                    let unfinished = position == words.count - 1 && offset == phrase.count - 1
                    return word == part || (unfinished && word.count >= 2 && part.hasPrefix(word))
                }
                if matches { covered.formUnion(start..<(start + phrase.count)) }
            }
        }
        return covered
    }

    private static func fuzzy<Value>(_ word: String, in table: [String: Value]) -> Value? {
        let limit = PaletteMatch.typoLimit(word.count)
        guard limit > 0 else { return nil }
        // One typo at most: two would turn too many names into commands.
        return table.keys.sorted().first { PaletteMatch.distance(word, $0, limit: 1) != nil }.flatMap { table[$0] }
    }

    // Matches the folded, lowercased text.
    private static let emailPattern = try! NSRegularExpression(
        pattern: "[a-z0-9._%+-]+@[a-z0-9-]+(?:\\.[a-z0-9-]+)*\\.[a-z]{2,}")

    static let filler: Set<String> = [
        "to", "the", "my", "account", "accounts", "please", "for", "on", "in", "with", "a", "an", "me", "now", "one",
        "i", "want", "would", "like", "could", "can", "you", "pls", "plz", "just", "this", "that", "it", "is",
        "of", "and", "at", "email", "mail", "address", "show", "view", "see", "display",
    ]

    static let verbs: [String: Verb] = [
        "switch": .switchTo, "use": .switchTo, "select": .switchTo, "change": .switchTo, "go": .switchTo,
        "swap": .switchTo, "pick": .switchTo, "choose": .switchTo, "set": .switchTo, "log": .switchTo,
        "login": .signIn, "signin": .signIn, "logon": .signIn,
        "reconnect": .reconnect, "relogin": .reconnect, "reauth": .reconnect,
        "connect": .connect,
        "add": .add, "new": .add, "create": .add,
        "remove": .remove, "delete": .remove, "forget": .remove, "rm": .remove, "del": .remove,
        "rename": .rename, "relabel": .rename,
        "open": .open, "desktop": .open, "launch": .open,
        "copy": .copy, "command": .copy, "terminal": .copy, "cli": .copy, "cmd": .copy, "shell": .copy,
    ]

    /// Verbs a typo may stand for. Destructive ones only count when spelled out.
    private static let typoVerbs: [String: Verb] = [
        "switch": .switchTo, "select": .switchTo, "change": .switchTo, "choose": .switchTo,
        "reconnect": .reconnect, "connect": .connect, "create": .add, "rename": .rename,
        "desktop": .open, "launch": .open, "command": .copy, "terminal": .copy,
    ]

    static let products: [String: PaletteAccount.Product] = [
        "codex": .codex, "openai": .codex, "chatgpt": .codex, "gpt": .codex,
        "claude": .claude, "code": .claude, "chrome": .claude, "anthropic": .claude,
    ]

    private static let typoProducts: [String: PaletteAccount.Product] = [
        "codex": .codex, "openai": .codex, "chatgpt": .codex, "claude": .claude, "chrome": .claude, "anthropic": .claude,
    ]

    static let headroomWords: Set<String> = [
        "best", "free", "freer", "freest", "most", "least", "available", "quota", "headroom", "lowest",
        "unused", "emptiest", "spare",
    ]

    static let stateWords: [String: Bool] = [
        "on": true, "enable": true, "enabled": true, "activate": true,
        "off": false, "disable": false, "disabled": false, "deactivate": false,
    ]

    /// Words that point at settings in general.
    static let settingWords: Set<String> = [
        "turn", "toggle", "setting", "settings", "option", "options", "preference", "preferences",
    ]
}

// MARK: - Ranking

/// Scores every row for one query. Rows below `minimumScore` are dropped as noise.
struct PaletteRanker {
    /// The kinds of row that name an account.
    enum Kind { case switchClaude, switchCodex, codexSignIn, reconnectCodex, openDesktop, copyCommand, rename, remove, add }

    static let minimumScore = 0.3
    /// What a row scores when the query lists rows ("codex", "remove") instead of naming one.
    static let listingScore = 0.6
    /// Without a verb, actions other than switching need at least this strong a match.
    static let secondaryMatch = 0.75

    let query: PaletteQuery
    let context: PaletteContext
    private let claude: [PaletteAccount]
    private let codex: [PaletteAccount]
    private let keys: [String: PaletteMatchKeys]
    private let entries: [PaletteEntry]
    /// Every word is part of a setting's or command's phrase ("open at login"), so the verbs in
    /// it do not list accounts.
    private let namedByPhrase: Bool

    init(text: String, context: PaletteContext) {
        self.context = context
        claude = PaletteEngine.headroomOrder(context.accounts.filter { $0.product == .claude })
        codex = PaletteEngine.headroomOrder(context.accounts.filter { $0.product == .codex })
        var keys: [String: PaletteMatchKeys] = [:]
        for account in context.accounts {
            keys["\(account.product.rawValue):\(account.id)"] = PaletteMatchKeys(email: account.email, id: account.id)
        }
        self.keys = keys
        let all = Array(keys.values)
        let query = PaletteQuery(text) { word, exactOnly in
            all.contains { $0.names(word, exactOnly: exactOnly) }
        }
        self.query = query
        entries = PaletteCatalog.entries(for: context)
        let covered = entries.reduce(into: Set<Int>()) { $0.formUnion(query.coverage(of: $1.phrases)) }
        namedByPhrase = !query.termIndexes.isEmpty && query.termIndexes.allSatisfy(covered.contains)
    }

    /// Ranked, deduplicated by id, best first.
    func ranked() -> [PaletteSuggestion] {
        var best: [String: (row: PaletteSuggestion, order: Int)] = [:]
        func offer(_ row: PaletteSuggestion, order: Int) {
            guard row.score >= Self.minimumScore else { return }
            if let existing = best[row.id], existing.row.score >= row.score { return }
            best[row.id] = (row, order)
        }
        accountRows(offer)
        desktopRows(offer)
        addRows(offer)
        headroomRows(offer)
        entryRows(offer)
        return best.values.sorted { lhs, rhs in
            let left = (lhs.row.score * 10_000).rounded(), right = (rhs.row.score * 10_000).rounded()
            if left != right { return left > right }
            if lhs.order != rhs.order { return lhs.order < rhs.order }
            return lhs.row.id < rhs.row.id
        }.map(\.row)
    }

    // MARK: Accounts

    private var isListing: Bool {
        query.content.isEmpty && !namedByPhrase && (!query.verbs.isEmpty || query.product != nil || query.wantsHeadroom)
    }

    private func allows(_ product: PaletteAccount.Product) -> Bool {
        query.product == nil || query.product == product
    }

    private func keys(_ account: PaletteAccount) -> PaletteMatchKeys {
        keys["\(account.product.rawValue):\(account.id)"] ?? PaletteMatchKeys(email: account.email, id: account.id)
    }

    private func accountRows(_ offer: (PaletteSuggestion, Int) -> Void) {
        guard !query.content.isEmpty || isListing else { return }
        for (rank, account) in (claude + codex).enumerated() where allows(account.product) {
            let match = query.content.isEmpty ? Self.listingScore : PaletteMatch.score(query.content, keys(account))
            guard match > 0 else { continue }
            let kinds: [Kind] = account.product == .claude
                ? [.switchClaude, .copyCommand, .rename, .remove]
                : (account.needsSignIn ? [.codexSignIn] : [.switchCodex, .reconnectCodex])
            for kind in kinds {
                guard let score = score(kind, match: match, account: account) else { continue }
                switch kind {
                case .switchClaude: offer(PaletteRows.switchClaude(account, context: context, score: score), rank)
                case .switchCodex, .codexSignIn: offer(PaletteRows.codexDefault(account, score: score), 1_000 + rank)
                case .reconnectCodex: offer(PaletteRows.reconnectCodex(account, score: score), 6_000 + rank)
                case .copyCommand: offer(PaletteRows.copyCommand(account, score: score), 4_000 + rank * 2)
                case .rename: offer(PaletteRows.rename(account, score: score), 4_001 + rank * 2)
                case .remove: offer(PaletteRows.remove(account, score: score), 5_000 + rank)
                case .openDesktop, .add: break
                }
            }
        }
    }

    private func desktopRows(_ offer: (PaletteSuggestion, Int) -> Void) {
        guard allows(.claude), !query.content.isEmpty || (isListing && query.verbs.contains(.open)) else { return }
        for (rank, profile) in context.desktopProfiles.enumerated() {
            let linked = context.accounts.first { $0.product == .claude && $0.id == profile.id }
            let keys = PaletteMatchKeys(email: linked?.email, id: profile.id, label: profile.label)
            let match = query.content.isEmpty ? Self.listingScore : PaletteMatch.score(query.content, keys)
            guard match > 0, let score = score(.openDesktop, match: match, account: nil) else { continue }
            offer(PaletteRows.openDesktop(profile, score: score), 2_000 + rank)
        }
    }

    /// Final score for one kind of row, or `nil` when the query rules it out.
    private func score(_ kind: Kind, match: Double, account: PaletteAccount?) -> Double? {
        let primary = [.switchClaude, .switchCodex, .codexSignIn].contains(kind)
        var score: Double
        if query.verbs.isEmpty {
            switch kind {
            case .switchClaude, .switchCodex, .codexSignIn: score = match
            case .openDesktop, .copyCommand, .rename:
                guard !query.content.isEmpty, match >= Self.secondaryMatch else { return nil }
                score = match * 0.55
            case .reconnectCodex, .remove, .add: return nil
            }
        } else {
            let strength = intentStrength(kind)
            if strength > 0 {
                score = match * (0.85 + 0.15 * strength) + 0.1 * strength
            } else {
                // A different verb leaves the main action visible below, never in a list of all rows.
                guard primary, !query.content.isEmpty else { return nil }
                score = match * 0.55
            }
        }
        if let account {
            if account.isSelected { score -= 0.05 }
            if account.needsSignIn {
                // Asked to sign in: the accounts that need it come first. Otherwise they come last.
                let signingIn = !query.verbs.isDisjoint(with: [.signIn, .reconnect, .connect])
                    && [.switchClaude, .codexSignIn, .reconnectCodex].contains(kind)
                score += signingIn ? 0.04 : -0.04
            }
            if query.product == nil, account.product == .codex { score -= 0.03 }
        }
        return score
    }

    /// How strongly the typed verbs ask for this kind of row, 0…1.
    private func intentStrength(_ kind: Kind) -> Double {
        let codexAsked = query.product == .codex
        var best = 0.0
        for verb in query.verbs {
            let strength: Double
            switch (verb, kind) {
            case (.switchTo, .switchClaude), (.switchTo, .switchCodex), (.switchTo, .codexSignIn): strength = 1
            case (.signIn, .switchClaude), (.signIn, .codexSignIn), (.signIn, .reconnectCodex): strength = 1
            case (.signIn, .switchCodex): strength = 0.5
            case (.reconnect, .reconnectCodex), (.reconnect, .codexSignIn): strength = 1
            case (.reconnect, .switchClaude): strength = 0.8
            case (.connect, .reconnectCodex), (.connect, .codexSignIn): strength = codexAsked ? 1 : 0.8
            case (.connect, .add): strength = query.emails.isEmpty ? 0 : 1
            case (.add, .add), (.remove, .remove), (.rename, .rename), (.open, .openDesktop), (.copy, .copyCommand): strength = 1
            case (.open, .switchClaude): strength = context.coordinated ? 0 : 0.85
            default: strength = 0
            }
            best = max(best, strength)
        }
        return best
    }

    // MARK: Adding and headroom

    private func addRows(_ offer: (PaletteSuggestion, Int) -> Void) {
        guard allows(.claude) else { return }
        let asked = query.verbs.isEmpty ? 0 : intentStrength(.add)
        for email in query.emails {
            if let saved = claude.first(where: { $0.email.lowercased() == email }) {
                guard asked > 0 else { continue }
                offer(PaletteRows.switchClaude(saved, context: context, score: 1.1, note: "already added"), 0)
                continue
            }
            let lookalike = claude.contains { PaletteMatch.strength(email, keys($0)) >= 0.6 }
            let score = asked > 0 ? 1.1 : (query.verbs.isEmpty ? (lookalike ? 0.58 : 0.85) : 0.4)
            offer(PaletteRows.addClaude(email: email, score: score), 3_000)
        }
        if query.emails.isEmpty, asked > 0 {
            offer(PaletteRows.addClaude(email: nil, score: query.content.isEmpty ? 1 : 0.75), 3_000)
        }
    }

    /// "best", "freest", "quota"…: the account with the most headroom, ahead of everything else.
    private func headroomRows(_ offer: (PaletteSuggestion, Int) -> Void) {
        guard query.wantsHeadroom, query.verbs.isSubset(of: [.switchTo, .signIn]) else { return }
        let product: PaletteAccount.Product = query.product == .codex ? .codex : .claude
        let accounts = product == .claude ? claude : codex
        var pool = accounts.filter { !$0.isSelected && !$0.needsSignIn && !PaletteEngine.isAtLimit($0) }
        let named = pool.filter { PaletteMatch.score(query.content, keys($0)) > 0 }
        if !named.isEmpty { pool = named }
        guard let best = pool.first else { return }
        let note = PaletteEngine.hasUsage(best) ? "most headroom" : "usage unknown"
        let row = product == .claude
            ? PaletteRows.switchClaude(best, context: context, score: 1.15, note: note)
            : PaletteRows.codexDefault(best, score: 1.15, note: note)
        offer(row, 0)
    }

    // MARK: Settings and commands

    private func entryRows(_ offer: (PaletteSuggestion, Int) -> Void) {
        for (rank, entry) in entries.enumerated() {
            guard var score = score(entry) else { continue }
            var note: String?
            if case .toggle(let toggle) = entry.action, let isOn = context.toggles[toggle] {
                var desired = query.desiredState
                for index in query.termIndexes {
                    if let implied = entry.impliedStates[query.words[index]] { desired = implied }
                }
                if let desired {
                    if desired == isOn {
                        score *= 0.5
                        note = isOn ? "Already on" : "Already off"
                    } else {
                        score += 0.05
                    }
                } else if isOn {
                    // "history" alone should not put "Turn off…" under ↩ when something else fits.
                    score -= 0.12
                }
            }
            let group = entry.isToggle ? 7_000 : 8_000
            offer(PaletteRows.entry(entry, context: context, score: score, note: note), group + rank)
        }
    }

    /// The share of typed words a setting or command explains. Verbs and similar steering words
    /// count only when spelled out in its keywords or title, and are left out otherwise; a
    /// product word it does not mention counts against it ("login codex" is about accounts).
    /// When the text names something, the entry has to explain at least one of those words.
    private func score(_ entry: PaletteEntry) -> Double? {
        let covered = query.coverage(of: entry.phrases)
        var total = 0.0
        var counted = 0
        var hasNames = false
        var explainsName = false
        for index in query.termIndexes {
            let word = query.words[index]
            let steering = query.steeringIndexes.contains(index)
            if !steering { hasNames = true }
            if covered.contains(index) {
                total += 1
                counted += 1
                if !steering { explainsName = true }
                continue
            }
            if steering {
                if let weight = entry.keywords[word] {
                    total += weight
                    counted += 1
                } else if entry.titleWords.contains(word) {
                    // "switch" or "claude" in a title is weak evidence on its own.
                    total += 0.5
                    counted += 1
                } else if query.productIndexes.contains(index) {
                    counted += 1
                }
                continue
            }
            let strength = max(PaletteMatch.keywordStrength(word, entry.keywords),
                               PaletteMatch.titleStrength(word, entry.titleWords))
            if strength > 0 { explainsName = true }
            total += strength
            counted += 1
        }
        guard counted > 0, total > 0, !hasNames || explainsName else { return nil }
        return total / Double(counted)
    }
}

// MARK: - Matching

/// The strings an account or Desktop profile can be found by.
struct PaletteMatchKeys {
    /// The full address, lowercased.
    var email: String?
    var local: String?
    var domain: String?
    /// The local part, the local part without separators, its pieces and letter and digit runs,
    /// and label words.
    var primary: [String] = []
    /// The domain and its labels without the top-level domain. Weaker: many accounts share one.
    var secondary: [String] = []

    init(email: String?, id: String? = nil, label: String? = nil) {
        var primary: [String] = []
        if let email = email?.lowercased(), !email.isEmpty {
            self.email = email
            let parts = email.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            let local = parts[0]
            self.local = local
            primary += Self.pieces(of: local)
            if parts.count > 1, !parts[1].isEmpty {
                let domain = parts[1]
                self.domain = domain
                let labels = domain.split(separator: ".").map(String.init)
                secondary = [domain] + labels.dropLast()
            }
        }
        if let id = id?.lowercased(), id != email?.lowercased(), !id.contains("@") {
            primary += Self.pieces(of: id)
        }
        if let label = label?.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased() {
            if label.contains("@") {
                primary += Self.pieces(of: String(label.split(separator: "@")[0]))
            } else {
                primary += label.split { !$0.isLetter && !$0.isNumber }.map(String.init)
            }
        }
        self.primary = primary.reduce(into: []) { if !$1.isEmpty && !$0.contains($1) { $0.append($1) } }
    }

    /// "lab-alpha" → lab-alpha, labalpha, lab, alpha. "team199" → team199, team, 199.
    private static func pieces(of text: String) -> [String] {
        let separators: Set<Character> = [".", "_", "+", "-"]
        var result = [text, String(text.filter { !separators.contains($0) })]
        for piece in text.split(whereSeparator: { separators.contains($0) }) {
            result.append(String(piece))
            var run = ""
            for character in piece {
                if let last = run.last, last.isNumber != character.isNumber {
                    result.append(run)
                    run = ""
                }
                run.append(character)
            }
            result.append(run)
        }
        return result
    }

    /// Whether `word` names this account outright, so it is not read as a verb or product word.
    func names(_ word: String, exactOnly: Bool) -> Bool {
        primary.contains { $0 == word || (!exactOnly && word.count >= 3 && $0.hasPrefix(word)) }
    }
}

enum PaletteMatch {
    /// Typos tolerated in a word of this length: none below five characters, one below eight, two from eight.
    static func typoLimit(_ length: Int) -> Int {
        length >= 8 ? 2 : (length >= 5 ? 1 : 0)
    }

    /// The average strength of `words` against one account.
    static func score(_ words: [String], _ keys: PaletteMatchKeys) -> Double {
        guard !words.isEmpty else { return 0 }
        return words.map { strength($0, keys) }.reduce(0, +) / Double(words.count)
    }

    /// 1 for an exact match, about 0.75–0.95 for a prefix, 0.6–0.75 inside a name, 0.46–0.62 with typos.
    static func strength(_ word: String, _ keys: PaletteMatchKeys) -> Double {
        if word.contains("@") { return emailStrength(word, keys) }
        var best = 0.0
        for key in keys.primary { best = max(best, nameStrength(word, key)) }
        for key in keys.secondary { best = max(best, 0.8 * nameStrength(word, key)) }
        return best
    }

    private static func nameStrength(_ word: String, _ key: String) -> Double {
        guard !word.isEmpty, !key.isEmpty else { return 0 }
        if word == key { return 1 }
        let ratio = Double(word.count) / Double(key.count)
        if key.hasPrefix(word) { return 0.75 + 0.2 * ratio }
        if word.count >= 3, key.contains(word) { return 0.6 + 0.15 * ratio }
        return typoStrength(word, key, whole: 0.62, prefix: 0.58)
    }

    private static func emailStrength(_ word: String, _ keys: PaletteMatchKeys) -> Double {
        guard let email = keys.email else { return 0 }
        if word == email { return 1 }
        let parts = word.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let local = parts[0], domain = parts.count > 1 ? parts[1] : ""
        if local.isEmpty {
            return keys.domain.map { 0.8 * nameStrength(domain, $0) } ?? 0
        }
        if domain.isEmpty { return keys.local.map { nameStrength(local, $0) } ?? 0 }
        if email.hasPrefix(word) { return 0.8 + 0.2 * Double(word.count) / Double(email.count) }
        // A whole address with a typo or two is still strong evidence: addresses are long.
        return typoStrength(word, email, whole: 0.8, prefix: 0.7)
    }

    /// A small typo in the whole key, or in its first `word.count` or so characters.
    private static func typoStrength(_ word: String, _ key: String, whole: Double, prefix: Double) -> Double {
        let limit = typoLimit(word.count)
        guard limit > 0 else { return 0 }
        if let edits = distance(word, key, limit: limit) { return edits == 1 ? whole : whole - 0.12 }
        if let edits = prefixDistance(word, key, limit: limit) { return edits == 1 ? prefix : prefix - 0.12 }
        return 0
    }

    /// A keyword: weight × (1 exact, 0.7–0.95 prefix, 0.6–0.65 with a typo).
    static func keywordStrength(_ word: String, _ keywords: [String: Double]) -> Double {
        var best = 0.0
        for (keyword, weight) in keywords {
            let strength: Double
            if word == keyword {
                strength = 1
            } else if keyword.hasPrefix(word) {
                strength = 0.7 + 0.25 * Double(word.count) / Double(keyword.count)
            } else {
                strength = typoStrength(word, keyword, whole: 0.65, prefix: 0.6)
            }
            best = max(best, weight * strength)
        }
        return best
    }

    /// A word of the visible title: weaker than a keyword, and prefixes need two letters.
    static func titleStrength(_ word: String, _ titleWords: [String]) -> Double {
        var best = 0.0
        for titleWord in titleWords {
            let strength: Double
            if word == titleWord {
                strength = 0.85
            } else if word.count >= 2, titleWord.hasPrefix(word) {
                strength = 0.6 + 0.25 * Double(word.count) / Double(titleWord.count)
            } else {
                strength = typoStrength(word, titleWord, whole: 0.5, prefix: 0.45)
            }
            best = max(best, strength)
        }
        return best
    }

    /// Optimal string alignment distance (a swap of neighbours is one edit), or `nil` above `limit`.
    static func distance(_ a: String, _ b: String, limit: Int) -> Int? {
        let a = Array(a), b = Array(b)
        guard abs(a.count - b.count) <= limit else { return nil }
        if a.isEmpty || b.isEmpty { return max(a.count, b.count) <= limit ? max(a.count, b.count) : nil }
        var beforePrevious = [Int](repeating: 0, count: b.count + 1)
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                var value = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    value = min(value, beforePrevious[j - 2] + 1)
                }
                current[j] = value
            }
            (beforePrevious, previous, current) = (previous, current, beforePrevious)
        }
        return previous[b.count] <= limit ? previous[b.count] : nil
    }

    /// The smallest distance between `word` and a strict prefix of `key` of about its length.
    static func prefixDistance(_ word: String, _ key: String, limit: Int) -> Int? {
        let lower = max(1, word.count - limit)
        let upper = min(key.count - 1, word.count + limit)
        guard lower <= upper else { return nil }
        var best: Int?
        for length in lower...upper {
            if let edits = distance(word, String(key.prefix(length)), limit: limit) {
                best = min(best ?? edits, edits)
            }
        }
        return best
    }
}

// MARK: - Settings and commands

/// One setting or command: what it is called, and the words that find it.
struct PaletteEntry {
    let action: PaletteAction
    /// The setting's name ("Open at login"), or the command's title.
    let name: String
    let subtitle: String?
    let symbol: String
    let keywords: [String: Double]
    let phrases: [[String]]
    /// Words that ask for a particular state of a setting: "resume" means Pause off.
    var impliedStates: [String: Bool] = [:]

    var isToggle: Bool {
        if case .toggle = action { return true }
        return false
    }

    var titleWords: [String] {
        name.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
            .filter { !PaletteQuery.filler.contains($0) }
    }
}

enum PaletteCatalog {
    /// Available settings, then available commands, in display order.
    static func entries(for context: PaletteContext) -> [PaletteEntry] {
        let toggles = PaletteToggle.allCases.filter { context.toggles[$0] != nil }.map { entry($0, context: context) }
        let commands = PaletteCommand.allCases
            .filter { $0 != .installUpdate || context.stagedUpdateVersion != nil }
            .map { entry($0, context: context) }
        return toggles + commands
    }

    static func entry(_ toggle: PaletteToggle, context: PaletteContext) -> PaletteEntry {
        // Any setting can be turned on or off, so these explain every one of them.
        let generic: [String: Double] = Dictionary(uniqueKeysWithValues: PaletteQuery.settingWords.map { ($0, 1) })
        func keywords(_ specific: [String: Double]) -> [String: Double] {
            generic.merging(specific) { _, new in new }
        }
        switch toggle {
        case .launchAtLogin:
            return PaletteEntry(action: .toggle(toggle), name: "Open at login",
                                subtitle: "Start Claude Switcher when you log in", symbol: "power.circle",
                                keywords: keywords(["login": 1, "startup": 1, "autostart": 1, "boot": 0.8,
                                                    "autolaunch": 1, "item": 0.5]),
                                phrases: [["login", "item"], ["login", "items"], ["open", "at", "login"],
                                          ["launch", "at", "login"], ["start", "at", "login"], ["start", "up"]])
        case .shareHistory:
            return PaletteEntry(action: .toggle(toggle), name: "Share Desktop Code history",
                                subtitle: "Keep Code conversations when the Desktop account changes",
                                symbol: "bubble.left.and.bubble.right",
                                keywords: keywords(["history": 1, "share": 1, "sharing": 1, "shared": 0.9,
                                                    "conversations": 0.7, "sessions": 0.6, "chats": 0.6]),
                                phrases: [["share", "history"], ["code", "history"]])
        case .reopenAfterUpdate:
            return PaletteEntry(action: .toggle(toggle), name: "Reopen Desktop after updates",
                                subtitle: "Bring Desktop profiles back after Claude updates itself",
                                symbol: "arrow.clockwise.circle",
                                keywords: keywords(["reopen": 1, "relaunch": 1, "restart": 0.8, "update": 0.8,
                                                    "updates": 0.85, "updated": 0.8]),
                                phrases: [["after", "update"], ["after", "updates"]])
        case .pauseDesktopUpdates:
            return PaletteEntry(action: .toggle(toggle), name: "Pause Desktop updates",
                                subtitle: "Keep Claude Desktop from updating itself", symbol: "pause.circle",
                                keywords: keywords(["pause": 1, "paused": 1, "block": 0.9, "freeze": 0.8,
                                                    "stop": 0.8, "update": 0.85, "updates": 0.9,
                                                    "autoupdate": 0.9, "autoupdates": 0.9, "resume": 0.8,
                                                    "unpause": 0.9, "unblock": 0.9]),
                                phrases: [["auto", "update"], ["auto", "updates"], ["stop", "updates"]],
                                impliedStates: ["pause": true, "paused": true, "block": true, "freeze": true,
                                                "stop": true, "resume": false, "unpause": false, "unblock": false])
        case .autoSwitch:
            return PaletteEntry(action: .toggle(toggle), name: "Auto-switch at limit",
                                subtitle: "At \(context.autoSwitchThreshold)% of a limit, move Claude to the account with most headroom",
                                symbol: "arrow.triangle.swap",
                                keywords: keywords(["auto": 1, "automatic": 1, "automatically": 0.9,
                                                    "autoswitch": 1, "auto-switch": 1, "limit": 1, "limits": 0.9,
                                                    "seamless": 1, "rotate": 1, "rotation": 0.9, "failover": 0.8]),
                                phrases: [["auto", "switch"], ["switch", "at", "limit"]])
        }
    }

    static func entry(_ command: PaletteCommand, context: PaletteContext) -> PaletteEntry {
        switch command {
        case .connectChrome:
            return PaletteEntry(action: .command(command), name: "Connect Chrome\u{2026}",
                                subtitle: "Set up switching in Chrome", symbol: "puzzlepiece.extension",
                                keywords: ["chrome": 1, "extension": 1, "companion": 1, "browser": 0.9,
                                           "connect": 1, "setup": 0.7, "coordinated": 0.8, "bridge": 0.7],
                                phrases: [["set", "up"], ["connect", "chrome"]])
        case .diagnostics:
            return PaletteEntry(action: .command(command), name: "Diagnostics\u{2026}",
                                subtitle: "Paths, profiles and sign-in checks", symbol: "stethoscope",
                                keywords: ["diagnostics": 1, "diagnostic": 1, "diag": 1, "debug": 0.9,
                                           "doctor": 0.9, "troubleshoot": 0.9, "problem": 0.7, "problems": 0.7,
                                           "broken": 0.7, "report": 0.6, "help": 0.6],
                                phrases: [])
        case .openSwitchLog:
            return PaletteEntry(action: .command(command), name: "Open switch log",
                                subtitle: "Recent switches and what went wrong", symbol: "list.bullet.rectangle",
                                keywords: ["log": 1, "logs": 1, "events": 0.9, "journal": 0.8, "activity": 0.7],
                                phrases: [["switch", "log"], ["switch", "logs"], ["open", "log"], ["open", "logs"]])
        case .syncHistory:
            return PaletteEntry(action: .command(command), name: "Sync Desktop history now",
                                subtitle: "Bring Code conversations to the current Desktop account",
                                symbol: "clock.arrow.2.circlepath",
                                keywords: ["sync": 1, "synchronize": 1, "resync": 1, "history": 0.9,
                                           "conversations": 0.6],
                                phrases: [["sync", "history"]])
        case .undoHistory:
            return PaletteEntry(action: .command(command), name: "Undo last history sync",
                                subtitle: "Put back the history from before the last sync",
                                symbol: "arrow.uturn.backward",
                                keywords: ["undo": 1, "revert": 0.9, "rollback": 0.9, "restore": 0.7, "history": 0.8],
                                phrases: [["undo", "sync"]])
        case .chooseClaudeApp:
            return PaletteEntry(action: .command(command), name: "Choose Claude.app\u{2026}",
                                subtitle: "Pick where Claude Desktop is installed", symbol: "folder",
                                keywords: ["app": 1, "claude.app": 1, "application": 0.9, "locate": 0.8,
                                           "location": 0.7, "path": 0.7, "folder": 0.6],
                                phrases: [["choose", "app"], ["claude", "app"]])
        case .installUpdate:
            let version = context.stagedUpdateVersion ?? ""
            var keywords: [String: Double] = ["update": 1, "updates": 0.95, "install": 1, "upgrade": 1, "version": 0.6]
            if !version.isEmpty { keywords[version.lowercased()] = 1 }
            return PaletteEntry(action: .command(command), name: "Install Claude Desktop update \(version)",
                                subtitle: "Quits Desktop profiles, installs, then opens them again",
                                symbol: "arrow.down.circle", keywords: keywords, phrases: [["install", "update"]])
        case .refreshUsage:
            return PaletteEntry(action: .command(command), name: "Refresh usage",
                                subtitle: "Check every account\u{2019}s usage now", symbol: "arrow.clockwise",
                                keywords: ["refresh": 1, "reload": 1, "usage": 0.9, "rescan": 0.8, "recheck": 0.8,
                                           "fetch": 0.7],
                                phrases: [["update", "usage"], ["check", "usage"]])
        case .quit:
            return PaletteEntry(action: .command(command), name: "Quit Claude Switcher",
                                subtitle: nil, symbol: "power",
                                keywords: ["quit": 1, "exit": 1, "terminate": 0.8],
                                phrases: [])
        }
    }
}

// MARK: - Rows

/// Builds the rows; ids are stable so a selection survives re-ranking.
enum PaletteRows {
    static func switchClaude(_ account: PaletteAccount, context: PaletteContext, score: Double,
                             note: String? = nil) -> PaletteSuggestion {
        let title = context.coordinated ? "Switch to \(name(account))" : "Open Claude Code as \(name(account))"
        let symbol = account.needsSignIn ? "person.crop.circle.badge.exclamationmark"
            : (account.isSelected ? "person.crop.circle.badge.checkmark" : "person.crop.circle")
        return PaletteSuggestion(id: "switchClaude:\(account.id)", action: .switchClaude(profileID: account.id),
                                 title: title, subtitle: accountSubtitle(account, note: note),
                                 symbol: symbol, score: score)
    }

    /// Switching, or signing in again when the saved login no longer works.
    static func codexDefault(_ account: PaletteAccount, score: Double, note: String? = nil) -> PaletteSuggestion {
        guard !account.needsSignIn else { return reconnectCodex(account, score: score, note: note) }
        return PaletteSuggestion(id: "switchCodex:\(account.id)", action: .switchCodex(email: account.id),
                                 title: "Switch Codex to \(name(account))", subtitle: accountSubtitle(account, note: note),
                                 symbol: "chevron.left.forwardslash.chevron.right", score: score)
    }

    static func reconnectCodex(_ account: PaletteAccount, score: Double, note: String? = nil) -> PaletteSuggestion {
        let subtitle = account.needsSignIn ? accountSubtitle(account, note: note) : "Sign in again in the browser"
        return PaletteSuggestion(id: "connectCodex:\(account.id)", action: .connectCodex(email: account.id),
                                 title: "Reconnect Codex \(name(account))", subtitle: subtitle,
                                 symbol: "arrow.triangle.2.circlepath", score: score)
    }

    static func addClaude(email: String?, score: Double) -> PaletteSuggestion {
        PaletteSuggestion(id: email.map { "addClaude:\($0)" } ?? "addClaude", action: .addClaude(email: email),
                          title: email.map { "Add Claude account \($0)" } ?? "Add Claude account\u{2026}",
                          subtitle: email == nil ? "Asks for the email, then opens sign-in" : "Opens sign-in for this account",
                          symbol: "plus.circle", score: score)
    }

    static func remove(_ account: PaletteAccount, score: Double) -> PaletteSuggestion {
        PaletteSuggestion(id: "removeClaude:\(account.id)", action: .removeClaude(profileID: account.id),
                          title: "Remove \(name(account))", subtitle: "Asks first · account data stays on this Mac",
                          symbol: "trash", isDestructive: true, score: score)
    }

    static func rename(_ account: PaletteAccount, score: Double) -> PaletteSuggestion {
        PaletteSuggestion(id: "renameClaude:\(account.id)", action: .renameClaude(profileID: account.id),
                          title: "Rename \(name(account))", subtitle: "Change the name of its Desktop profile",
                          symbol: "pencil", score: score)
    }

    static func copyCommand(_ account: PaletteAccount, score: Double) -> PaletteSuggestion {
        PaletteSuggestion(id: "copyTerminalCommand:\(account.id)", action: .copyTerminalCommand(profileID: account.id),
                          title: "Copy terminal command for \(name(account))",
                          subtitle: "Paste it in Terminal to use this account", symbol: "terminal", score: score)
    }

    static func openDesktop(_ profile: PaletteDesktopProfile, score: Double) -> PaletteSuggestion {
        PaletteSuggestion(id: "openDesktop:\(profile.id)", action: .openDesktop(profileID: profile.id),
                          title: "Open Claude Desktop: \(profile.label)",
                          subtitle: profile.isRunning ? "Running · brings it to the front" : "Desktop has its own sign-in",
                          symbol: "macwindow", score: score)
    }

    static func entry(_ entry: PaletteEntry, context: PaletteContext, score: Double, note: String? = nil) -> PaletteSuggestion {
        switch entry.action {
        case .toggle(let toggle):
            let isOn = context.toggles[toggle] ?? false
            return PaletteSuggestion(id: "toggle:\(toggle.rawValue)", action: entry.action,
                                     title: "Turn \(isOn ? "off" : "on") \(entry.name)",
                                     subtitle: note ?? entry.subtitle, symbol: entry.symbol, score: score)
        case .command(let command):
            return PaletteSuggestion(id: "command:\(command.rawValue)", action: entry.action, title: entry.name,
                                     subtitle: note ?? entry.subtitle, symbol: entry.symbol, score: score)
        default:
            return PaletteSuggestion(id: entry.name, action: entry.action, title: entry.name,
                                     subtitle: entry.subtitle, symbol: entry.symbol, score: score)
        }
    }

    static func askJev(_ text: String) -> PaletteSuggestion {
        PaletteSuggestion(id: "askJev", action: .askJev(text), title: "Ask Jev: \u{201C}\(text)\u{201D}",
                          subtitle: "TypeSafe picks the closest action", symbol: "sparkles", score: 0)
    }

    private static func name(_ account: PaletteAccount) -> String {
        account.email.isEmpty ? account.id : account.email
    }

    /// "5h 28% · Week 26% · selected". Unknown values show as an em dash.
    static func accountSubtitle(_ account: PaletteAccount, note: String? = nil) -> String? {
        var parts: [String] = []
        if PaletteEngine.hasUsage(account) || !account.needsSignIn {
            let five = account.fiveHourUsed.map { "\($0)%" } ?? "\u{2014}"
            let week = account.weekUsed.map { "\($0)%" } ?? "\u{2014}"
            parts.append("5h \(five) \u{00B7} Week \(week)")
        }
        if account.isSelected { parts.append("selected") }
        if account.needsSignIn { parts.append("sign in needed") }
        if let note { parts.append(note) }
        return parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} ")
    }
}
