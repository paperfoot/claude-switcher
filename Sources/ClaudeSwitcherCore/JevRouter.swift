import Foundation
import Security

// MARK: - Router

/// Asks TypeSafe's Jev which palette action a request in plain words means.
///
/// One request with one Choice question: the options are the candidates' titles plus
/// "None of these". Jev sees the typed request, the option titles with a short description of
/// each kind of action, and for each account its email, product, whether it is selected or
/// needs to sign in, and its usage. Nothing else leaves the Mac: no tokens, cookies or paths.
public struct JevRouter: Sendable {
    /// Sends one request and returns the body and response, like `URLSession.data(for:)`.
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    public static let endpoint = URL(string: "https://api.typesafe.ai/v1/systemone")!
    public static let noneOption = "None of these"
    /// Choice questions take at most 255 options; one is "None of these".
    static let maximumOptions = 254
    /// Interpretations less likely than this are not worth showing.
    static let minimumProbability = 0.05
    /// Long pastes are cut; a palette request is a sentence.
    static let maximumRequestLength = 500

    public let model: String
    public let timeout: Duration
    private let apiKey: String
    private let transport: Transport

    public init(apiKey: String, model: String = "jev-latest", timeout: Duration = .seconds(8),
                transport: @escaping Transport = JevRouter.urlSession) {
        self.apiKey = apiKey
        self.model = model
        self.timeout = timeout
        self.transport = transport
    }

    /// A router using the key saved in the Keychain, or `nil` when there is none.
    public static func stored() -> JevRouter? {
        JevKeyStore.load().map { JevRouter(apiKey: $0) }
    }

    /// Up to three candidates Jev thinks `text` asks for, most likely first, each scored with
    /// its probability (0…1). Empty when Jev picks "None of these" or nothing is likely enough.
    public func interpret(_ text: String, candidates: [PaletteSuggestion],
                          context: PaletteContext) async throws -> [PaletteSuggestion] {
        let options = Self.options(for: candidates)
        guard !options.isEmpty else { return [] }
        let request = try makeRequest(text: text, options: options, context: context)
        let transport = self.transport
        let (data, status) = try await withTimeout {
            let (data, response) = try await transport(request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        guard (200..<300).contains(status) else { throw JevError.rejected(status: status) }
        let probabilities = try Self.probabilities(in: data)
        return options.enumerated()
            .compactMap { index, option -> (Int, PaletteSuggestion, Double)? in
                guard let probability = probabilities[option.key], probability >= Self.minimumProbability else { return nil }
                return (index, option.suggestion, probability)
            }
            .sorted { $0.2 != $1.2 ? $0.2 > $1.2 : $0.0 < $1.0 }
            .prefix(3)
            .map { $0.1.with(score: $0.2) }
    }

    // MARK: Request

    /// One option per candidate, keyed by its title; repeated titles get a number.
    static func options(for candidates: [PaletteSuggestion]) -> [(key: String, suggestion: PaletteSuggestion)] {
        var seen: [String: Int] = [:]
        var options: [(key: String, suggestion: PaletteSuggestion)] = []
        for candidate in candidates {
            if case .askJev = candidate.action { continue }
            guard options.count < maximumOptions else { break }
            let count = seen[candidate.title, default: 0] + 1
            seen[candidate.title] = count
            var key = count == 1 ? candidate.title : "\(candidate.title) (\(count))"
            if key == noneOption { key += " (\(count + 1))" }
            options.append((key, candidate))
        }
        return options
    }

    func makeRequest(text: String, options: [(key: String, suggestion: PaletteSuggestion)],
                     context: PaletteContext) throws -> URLRequest {
        let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
        var request = URLRequest(url: Self.endpoint, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: max(1, seconds))
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try Self.body(model: model, text: text, options: options, context: context)
        return request
    }

    /// Written by hand so the options keep the candidates' order: Jev leans towards earlier options,
    /// and the candidates come best first.
    static func body(model: String, text: String, options: [(key: String, suggestion: PaletteSuggestion)],
                     context: PaletteContext) throws -> Data {
        struct Account: Encodable {
            let email: String
            let product: String
            let selected: Bool
            let needsSignIn: Bool
            let fiveHourUsed: String
            let weekUsed: String
            /// Jev reads words better than numbers, so the comparison is done here.
            let headroom: String
            let mostHeadroom: Bool
            enum CodingKeys: String, CodingKey {
                case email, product, selected, headroom
                case needsSignIn = "needs_sign_in", fiveHourUsed = "five_hour_used", weekUsed = "week_used"
                case mostHeadroom = "most_headroom"
            }
        }
        struct State: Encodable {
            let request: String
            let accounts: [Account]
        }
        let best = [PaletteEngine.mostHeadroom(in: context.accounts, product: .claude),
                    PaletteEngine.mostHeadroom(in: context.accounts, product: .codex)].compactMap { $0 }
        let state = State(
            request: String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maximumRequestLength)),
            accounts: context.accounts.map { account in
                Account(email: account.email, product: account.product == .claude ? "Claude" : "Codex",
                        selected: account.isSelected, needsSignIn: account.needsSignIn,
                        fiveHourUsed: account.fiveHourUsed.map { "\($0)%" } ?? "unknown",
                        weekUsed: account.weekUsed.map { "\($0)%" } ?? "unknown",
                        headroom: headroom(account),
                        mostHeadroom: best.contains { $0.product == account.product && $0.id == account.id })
            })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        func json<T: Encodable>(_ value: T) throws -> String {
            String(decoding: try encoder.encode(value), as: UTF8.self)
        }
        var criteria: [String] = []
        for option in options {
            criteria.append("\(try json(option.key)):\(try json(describe(option.suggestion, context: context)))")
        }
        criteria.append("\(try json(noneOption)):\(try json("The request asks for something no other option does"))")
        let instructions = "Which option does `request` ask Claude Switcher to do? Claude Switcher is a Mac "
            + "menu bar app that switches between the saved Claude and Codex accounts in `accounts`. "
            + "In `accounts`, `headroom` says how much of its usage limits an account has left, and "
            + "`most_headroom` marks the best account to switch to. "
            + "Choose \(noneOption) when no option does what `request` asks."
        let question = "{\"type\":\"choice\",\"instructions\":\(try json(instructions)),\"criteria\":{\(criteria.joined(separator: ","))}}"
        let body = "{\"model\":\(try json(model)),\"state\":\(try json(state)),\"questions\":{\"action\":\(question)}}"
        return Data(body.utf8)
    }

    /// "plenty", "some", "little", "none" or "unknown": how much of its limits an account has left.
    static func headroom(_ account: PaletteAccount) -> String {
        guard PaletteEngine.hasUsage(account) else { return "unknown" }
        let used = max(account.weekUsed ?? 0, account.fiveHourUsed ?? 0)
        if used >= PaletteEngine.limitPercent { return "none" }
        if used >= 80 { return "little" }
        if used >= 50 { return "some" }
        return "plenty"
    }

    /// Exactly what choosing an option does, so Jev can tell similar titles apart. Jev reads
    /// literally, so settings say which way they flip.
    static func describe(_ suggestion: PaletteSuggestion, context: PaletteContext) -> String {
        switch suggestion.action {
        case .switchClaude:
            return context.coordinated
                ? "Make this the active Claude account in Chrome and Claude Code"
                : "Open Claude Code in Terminal signed in as this Claude account"
        case .switchCodex: return "Make this the active Codex account"
        case .connectCodex: return "Sign in to this Codex account again in the browser"
        case .addClaude: return "Save another Claude account and sign in to it"
        case .removeClaude: return "Delete this account from Claude Switcher's saved accounts. It does not switch accounts"
        case .renameClaude: return "Change the name shown for this account's Desktop profile"
        case .openDesktop: return "Open the Claude Desktop app with this profile"
        case .copyTerminalCommand: return "Copy a Terminal command that starts Claude Code as this account"
        case .toggle(let toggle):
            let effect = effectWhenOn(toggle)
            return context.toggles[toggle] == true
                ? "This setting is on now: \(effect). Choosing this turns it off"
                : "This setting is off now. Choosing this turns it on, so that \(effect.prefix(1).lowercased() + effect.dropFirst())"
        case .command(let command): return PaletteCatalog.entry(command, context: context).subtitle ?? suggestion.title
        case .askJev: return suggestion.title
        }
    }

    private static func effectWhenOn(_ toggle: PaletteToggle) -> String {
        switch toggle {
        case .launchAtLogin: return "Claude Switcher opens automatically when the user logs in to the Mac"
        case .shareHistory: return "Claude Desktop keeps its Code conversations when its account changes"
        case .reopenAfterUpdate: return "Desktop profiles open again after Claude Desktop updates itself"
        case .pauseDesktopUpdates: return "Claude Desktop does not update itself"
        case .autoSwitch:
            return "Claude moves to the account with the most headroom when the active one reaches \(PaletteEngine.limitPercent)% of a limit"
        }
    }

    // MARK: Response

    /// The probability of every option in the answer to the "action" question.
    static func probabilities(in data: Data) throws -> [String: Double] {
        struct Answer: Decodable {
            let type: String?
            let probabilities: [String: Double]?
        }
        struct Response: Decodable {
            let answers: [String: Answer]
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data),
              let probabilities = response.answers["action"]?.probabilities else { throw JevError.unreadable }
        return probabilities
    }

    private func withTimeout<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) async throws -> T {
        let timeout = self.timeout
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw JevError.timedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw JevError.timedOut }
            return first
        }
    }

    // MARK: Transport

    /// No cookies, no cache: every request stands alone.
    public static let urlSession: Transport = { request in
        try await session.data(for: request)
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()
}

public enum JevError: Error, Equatable, LocalizedError {
    case timedOut
    /// TypeSafe answered with an HTTP error: 401 means the key was refused, 429 and 529 that it is busy.
    case rejected(status: Int)
    case unreadable

    public var errorDescription: String? {
        switch self {
        case .timedOut: return "Jev did not answer in time"
        case .rejected(let status) where status == 401 || status == 403: return "TypeSafe refused the API key"
        case .rejected(let status) where status == 429 || status == 529: return "TypeSafe is busy · try again"
        case .rejected: return "TypeSafe could not answer"
        case .unreadable: return "Jev's answer could not be read"
        }
    }
}

// MARK: - Key

/// Where the TypeSafe key lives. Injectable, so tests never touch the real Keychain.
public protocol JevKeyStorage: Sendable {
    func read(service: String, account: String) throws -> Data?
    func write(_ data: Data, service: String, account: String) throws
    func delete(service: String, account: String) throws
}

/// The login Keychain, as a generic password.
public struct JevKeychainStorage: JevKeyStorage {
    public init() {}

    private func query(service: String, account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public func read(service: String, account: String) throws -> Data? {
        var query = query(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw JevKeyStoreError.keychain(status) }
        return data
    }

    public func write(_ data: Data, service: String, account: String) throws {
        let query = query(service: service, account: account)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = "Claude Switcher TypeSafe API key"
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw JevKeyStoreError.keychain(added) }
        } else if status != errSecSuccess {
            throw JevKeyStoreError.keychain(status)
        }
    }

    public func delete(service: String, account: String) throws {
        let status = SecItemDelete(query(service: service, account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw JevKeyStoreError.keychain(status) }
    }
}

public enum JevKeyStoreError: Error, Equatable {
    case empty
    case keychain(OSStatus)
}

/// The TypeSafe API key that turns on Jev in the palette.
public enum JevKeyStore {
    public static let service = "Claude Switcher TypeSafe"
    public static let account = "api-key"

    /// The saved key, or `nil` when there is none or the Keychain cannot be read.
    public static func load(from storage: any JevKeyStorage = JevKeychainStorage()) -> String? {
        guard let data = try? storage.read(service: service, account: account) else { return nil }
        let key = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
    }

    public static func save(_ key: String, to storage: any JevKeyStorage = JevKeychainStorage()) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw JevKeyStoreError.empty }
        try storage.write(Data(trimmed.utf8), service: service, account: account)
    }

    public static func remove(from storage: any JevKeyStorage = JevKeychainStorage()) throws {
        try storage.delete(service: service, account: account)
    }
}
