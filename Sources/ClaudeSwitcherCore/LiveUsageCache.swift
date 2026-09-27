import Foundation
import Darwin

/// Only usage readings are persisted. A cache entry is bound to the complete profile and
/// verified email; changing a directory or account cannot reuse another account's reading.
public enum LiveUsageCache {
    private struct Entry: Codable {
        let profile: Profile
        let snapshot: LiveUsageSnapshot
    }

    public static var url: URL {
        Config.configURL.deletingLastPathComponent().appendingPathComponent("usage-cache.json")
    }

    public static func load(profiles: [Profile], from url: URL = url, now: Date = Date()) -> [String: LiveUsageSnapshot] {
        guard let data = try? Data(contentsOf: url), data.count <= 1_048_576,
              let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return [:] }
        var result: [String: LiveUsageSnapshot] = [:]
        for entry in entries where profiles.contains(entry.profile) {
            let age = now.timeIntervalSince(entry.snapshot.fetchedAt)
            guard age >= 0, age <= LiveUsagePolicy.cacheLifetime,
                  entry.profile.expectedEmail.map({ $0.caseInsensitiveCompare(entry.snapshot.email) == .orderedSame }) ?? true else { continue }
            result[entry.profile.id] = entry.snapshot
        }
        return result
    }

    public static func save(_ snapshots: [String: LiveUsageSnapshot], profiles: [Profile], to url: URL = url) throws {
        let entries = profiles.compactMap { profile in
            snapshots[profile.id].map { Entry(profile: profile, snapshot: $0) }
        }
        let data = try JSONEncoder().encode(entries)
        let fm = FileManager.default
        let directory = url.deletingLastPathComponent()
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temporary = directory.appendingPathComponent(".usage-cache-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: temporary) }
        guard fm.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]),
              rename(temporary.path, url.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
}

/// Presentation retains last-known values while refreshing, but labels older or expired
/// readings explicitly. Sign-out and identity mismatches always hide cached account data.
public struct LiveUsagePresentation: Sendable {
    public let snapshot: LiveUsageSnapshot?
    public let isCached: Bool

    public init(profile: Profile, status: AccountStatus?, snapshot: LiveUsageSnapshot?, failed: Bool, now: Date) {
        var allowed = true
        switch status {
        case .signedOut: allowed = false
        case .signedIn:
            allowed = status?.matches(profile.expectedEmail) == true &&
                status?.email?.caseInsensitiveCompare(snapshot?.email ?? "") == .orderedSame
        case nil, .unavailable:
            allowed = profile.expectedEmail.map { $0.caseInsensitiveCompare(snapshot?.email ?? "") == .orderedSame } ?? true
        }
        let age = snapshot.map { now.timeIntervalSince($0.fetchedAt) } ?? .infinity
        self.snapshot = allowed && age >= 0 && age <= LiveUsagePolicy.cacheLifetime ? snapshot : nil
        self.isCached = failed || status?.email == nil || age >= LiveUsagePolicy.refreshInterval
    }
}
