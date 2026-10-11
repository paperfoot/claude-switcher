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

    public init(accounts: [PaletteAccount] = [], desktopProfiles: [PaletteDesktopProfile] = [],
                toggles: [PaletteToggle: Bool] = [:], stagedUpdateVersion: String? = nil,
                coordinated: Bool = true, jevAvailable: Bool = false) {
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
}

// MARK: - Engine

/// Turns what the user typed into ranked suggestions. Pure and synchronous.
public enum PaletteEngine {
    public static func suggestions(for query: String, context: PaletteContext, limit: Int = 8) -> [PaletteSuggestion] {
        []
    }
}
