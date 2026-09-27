import CryptoKit
import Foundation

/// Creates a small Terminal document; opening it needs no Apple Events permission.
public enum TerminalLauncher {
    public static func write(profile: Profile, executable: String, directory: URL, signIn: Bool = false) throws -> URL {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        let digest = SHA256.hash(data: Data(profile.id.utf8))
            .prefix(8).map { String(format: "%02x", $0) }.joined()
        let destination = directory.appendingPathComponent("Claude-\(digest).command")
        let command = LaunchPlanning.terminalCommand(for: profile, executable: executable)
        let hint = profile.expectedEmail.map { " --email \(LaunchPlanning.shellQuoted($0))" } ?? ""
        // Login ends here. The next menu click verifies the resulting email before opening Code.
        let action = signIn ? "\(command) auth login --claudeai\(hint)" : command
        let script = "#!/bin/zsh\ncd \"$HOME\" || exit 1\nexec \(action)\n"
        try Data(script.utf8).write(to: destination, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: destination.path)
        return destination
    }
}
