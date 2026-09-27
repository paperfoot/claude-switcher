import Foundation

// MARK: - Matching running instances to profiles

/// Maps live Claude.app processes onto configured profiles.
///
/// A running instance belongs to the profile whose normalized `userDataDir` equals the
/// normalized `--user-data-dir` it was launched with; an instance launched with no such
/// argument is the app's own default profile.
///
/// An instance whose argument vector could not be read (``InstanceProfile/unknown``) belongs
/// to *no* profile. It is never folded into the default account — doing so would show the
/// wrong account as running and, worse, let a "focus" action bring an unrelated window
/// forward while the UI claimed the switch succeeded.
public enum ProfileMatching {

    /// The instance currently serving `profile`, if any.
    public static func instance(for profile: Profile, in running: [RunningInstance]) -> RunningInstance? {
        let wanted = InstanceManager.binding(for: profile)
        return running.first { $0.profile == wanted }
    }

    public static func isRunning(_ profile: Profile, in running: [RunningInstance]) -> Bool {
        instance(for: profile, in: running) != nil
    }

    /// Instances that belong to no configured profile — a directory the user removed from the
    /// config, an instance launched by hand, or one whose argv we could not read.
    public static func unmatched(_ running: [RunningInstance], profiles: [Profile]) -> [RunningInstance] {
        let known = Set(profiles.map { InstanceManager.binding(for: $0) }.compactMap { binding -> String? in
            if case .directory(let dir) = binding { return dir }
            return nil
        })
        let hasDefaultProfile = profiles.contains { $0.isDefaultProfile }

        return running.filter { instance in
            switch instance.profile {
            case .directory(let dir): return !known.contains(dir)
            case .defaultProfile:     return !hasDefaultProfile
            case .unknown:            return true
            }
        }
    }
}

// MARK: - Launch plan derivations

/// The exact command lines the switcher would use, derived purely from a ``Profile``.
///
/// These encode two of the project's hard constraints, so they are kept here — testable,
/// and in one place — rather than inline at the call sites.
public enum LaunchPlanning {

    /// The argument vector `InstanceManager.launch` passes to Claude.app.
    ///
    /// The default profile (no `userDataDir`) must never receive `--user-data-dir`: omitting
    /// the flag is exactly what selects the app's own default profile directory.
    public static func launchArguments(for profile: Profile) -> [String] {
        guard let dir = profile.userDataDir else { return [] }
        let normalized = PathNormalizer.normalize(dir)
        guard !normalized.isEmpty else { return [] }
        return ["--user-data-dir=\(normalized)"]
    }

    /// Clear inherited account selectors before choosing this profile. Named CLI profiles
    /// isolate both credentials and account metadata: sharing config while switching only
    /// the Keychain slot can show the previous account's email and organization.
    public static let accountEnvironmentKeys = [
        "CLAUDE_CONFIG_DIR", "CLAUDE_SECURESTORAGE_CONFIG_DIR",
        "CLAUDE_CODE_OAUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR",
        "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL",
        "ANTHROPIC_CUSTOM_HEADERS", "CLAUDE_CODE_USE_BEDROCK",
        "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY",
    ]

    public static func terminalCommand(for profile: Profile, executable: String = "claude") -> String {
        var parts = ["/usr/bin/env"]
        for key in accountEnvironmentKeys { parts += ["-u", key] }
        if let dir = profile.credDir {
            let normalized = PathNormalizer.normalize(dir)
            if !normalized.isEmpty {
                parts.append("CLAUDE_CONFIG_DIR=\(shellQuoted(normalized))")
                parts.append("CLAUDE_SECURESTORAGE_CONFIG_DIR=\(shellQuoted(normalized))")
            }
        }
        parts.append(shellQuoted(executable))
        return parts.joined(separator: " ")
    }

    /// Double-quotes a value, escaping the characters the shell still expands inside quotes.
    public static func shellQuoted(_ value: String) -> String {
        var escaped = ""
        for character in value {
            if character == "\"" || character == "\\" || character == "$" || character == "`" {
                escaped.append("\\")
            }
            escaped.append(character)
        }
        return "\"\(escaped)\""
    }
}
