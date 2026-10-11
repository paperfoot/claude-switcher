import Foundation
import Testing
@testable import ClaudeSwitcherCore

struct LiveUsageCacheTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let profile = Profile(id: "work", label: "Work", credDir: "/tmp/work", expectedEmail: "work@example.com")

    func snapshot(age: TimeInterval = 0, email: String = "work@example.com") -> LiveUsageSnapshot {
        LiveUsageSnapshot(email: email, fetchedAt: now.addingTimeInterval(-age),
                          fiveHour: LiveUsageWindow(percent: 42, resetsAt: now.addingTimeInterval(3600)),
                          sevenDay: LiveUsageWindow(percent: 64, resetsAt: now.addingTimeInterval(86400)))
    }

    var signedIn: AccountStatus { .signedIn(email: "work@example.com", plan: nil) }

    @Test func oldReadingsRemainVisibleAndMarkedStale() {
        let reading = snapshot(age: 3600)
        let presentation = LiveUsagePresentation(profile: profile, status: signedIn, snapshot: reading, failed: false, now: now)
        #expect(presentation.snapshot == reading)
        #expect(presentation.isStale)
    }

    /// Accounts refresh at different moments; a reading a few refresh cycles old is still current.
    @Test func readingsStayFreshForTwentyMinutes() {
        let current: [TimeInterval] = [20, 6 * 60, 19 * 60, LiveUsagePolicy.staleAfter]
        for age in current {
            let presentation = LiveUsagePresentation(profile: profile, status: signedIn, snapshot: snapshot(age: age),
                                                    failed: false, now: now)
            #expect(presentation.snapshot != nil)
            #expect(!presentation.isStale, "a reading \(Int(age)) s old is not stale")
        }
        let stale: [TimeInterval] = [LiveUsagePolicy.staleAfter + 1, 3600]
        for age in stale {
            let presentation = LiveUsagePresentation(profile: profile, status: signedIn, snapshot: snapshot(age: age),
                                                    failed: false, now: now)
            #expect(presentation.isStale, "a reading \(Int(age)) s old is stale")
        }
    }

    @Test func failedRefreshIsStaleEvenWhenRecent() {
        let failed = LiveUsagePresentation(profile: profile, status: signedIn, snapshot: snapshot(age: 20), failed: true, now: now)
        #expect(failed.snapshot != nil)
        #expect(failed.isStale)
    }

    @Test func startupAndOfflinePreserveCache() {
        for status: AccountStatus? in [nil, .unavailable] {
            let presentation = LiveUsagePresentation(profile: profile, status: status, snapshot: snapshot(), failed: false, now: now)
            #expect(presentation.snapshot != nil)
            // A pending identity check says nothing about the reading's age.
            #expect(!presentation.isStale)
        }
    }

    @Test func codexRowsShareTheStaleRule() {
        #expect(LiveUsagePolicy.isStale(nil, failed: false, now: now))
        #expect(LiveUsagePolicy.isStale(snapshot(age: 20), failed: true, now: now))
        #expect(!LiveUsagePolicy.isStale(snapshot(age: 10 * 60), failed: false, now: now))
        #expect(LiveUsagePolicy.isStale(snapshot(age: 21 * 60), failed: false, now: now))
    }

    /// The last percentage of a finished window would describe the previous window.
    @Test func expiredWindowIsUnknownWhileTheOtherStaysKnown() {
        let reading = LiveUsageSnapshot(email: "work@example.com", fetchedAt: now.addingTimeInterval(-600),
                                        fiveHour: LiveUsageWindow(percent: 97, resetsAt: now.addingTimeInterval(-60)),
                                        sevenDay: LiveUsageWindow(percent: 64, resetsAt: now.addingTimeInterval(86400)))
        let presentation = LiveUsagePresentation(profile: profile, status: signedIn, snapshot: reading, failed: false, now: now)
        #expect(!presentation.isStale)
        #expect(presentation.snapshot?.fiveHour?.displayedPercent(at: now) == nil)
        #expect(presentation.snapshot?.sevenDay?.displayedPercent(at: now) == 64)
    }

    @Test func signOutAndOtherAccountsNeverShowCachedValues() {
        for status: AccountStatus? in [.signedOut, .signedIn(email: "other@example.com", plan: nil)] {
            #expect(LiveUsagePresentation(profile: profile, status: status, snapshot: snapshot(), failed: false, now: now).snapshot == nil)
        }
        #expect(LiveUsagePresentation(profile: profile, status: nil, snapshot: snapshot(email: "other@example.com"), failed: false, now: now).snapshot == nil)
    }

    @Test func futureAndVeryOldReadingsAreRejected() {
        for age in [-60.0, LiveUsagePolicy.cacheLifetime + 1] {
            #expect(LiveUsagePresentation(profile: profile, status: nil, snapshot: snapshot(age: age), failed: false, now: now).snapshot == nil)
        }
    }

    @Test func refreshIsScheduledAtResetOrFiveMinutes() {
        let reading = snapshot(age: 20)
        #expect(LiveUsagePolicy.nextRefresh(for: reading, now: now) == now.addingTimeInterval(280))
        let resetting = LiveUsageSnapshot(email: reading.email, fetchedAt: now,
                                         fiveHour: LiveUsageWindow(percent: 95, resetsAt: now.addingTimeInterval(30)), sevenDay: nil)
        #expect(LiveUsagePolicy.nextRefresh(for: resetting, now: now) == now.addingTimeInterval(30))
        #expect(LiveUsagePolicy.nextRefresh(for: resetting, now: now.addingTimeInterval(31)) == now.addingTimeInterval(300))
    }

    @Test func cacheSurvivesRestartWithPrivatePermissionsAndExactProfileBinding() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("usage.json")
        let readings = [profile.id: snapshot()]
        try LiveUsageCache.save(readings, profiles: [profile], to: url)
        #expect(LiveUsageCache.load(profiles: [profile], from: url, now: now) == readings)
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
        var changed = profile
        changed.credDir = "/tmp/another-account"
        #expect(LiveUsageCache.load(profiles: [changed], from: url, now: now).isEmpty)
        #expect(LiveUsageCache.load(profiles: [], from: url, now: now).isEmpty)
        try LiveUsageCache.save([:], profiles: [profile], to: url)
        #expect(LiveUsageCache.load(profiles: [profile], from: url, now: now).isEmpty)
    }

    @Test func corruptCacheIsIgnored() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("broken".utf8).write(to: url)
        #expect(LiveUsageCache.load(profiles: [profile], from: url, now: now).isEmpty)
    }

    @Test func expiredResetRetainsHistoricalSnapshotWithoutInventingZero() {
        let reading = snapshot()
        let later = now.addingTimeInterval(4000)
        let presentation = LiveUsagePresentation(profile: profile, status: nil, snapshot: reading, failed: false, now: later)
        #expect(presentation.snapshot?.fiveHour?.percent == 42)
        #expect(presentation.snapshot?.fiveHour?.displayedPercent(at: later) == nil)
        #expect(presentation.isStale)
    }
}
