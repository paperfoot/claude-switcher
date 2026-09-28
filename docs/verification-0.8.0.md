# Version 0.8.0 verification

Checked on 28 September 2026.

## Delivered

- One native menu with three Claude labels and three Codex labels.
- Five-hour and weekly usage share one line with a spaced `|`, small rounded gauges, percentage consumed, and reset times. Gauges have no battery tip.
- The installed official Codex runtime handles browser authorization, identity checks, and usage requests. Saved credentials live in macOS Keychain; account labels, aliases and usage caches contain no tokens.
- Selecting a saved Codex account preflights it, requests a normal desktop quit, preserves the outgoing credential, changes the ordinary Codex auth file, verifies the target, and reopens the official app. Failure restores the previous credential when it is safe to do so. The desktop is never force-killed.
- Initial connection saves a login without switching the running desktop. Expired logins can be reconnected from Settings.

## Observed

- All three requested Codex accounts are saved. Two completed the official Google/browser authorization flow. The existing active login was imported and mapped to its requested display alias.
- The installed app read live usage for every saved Codex account. The provider currently returns a weekly window for these accounts; absent five-hour values remain unavailable instead of showing zero.
- The active Codex account remained unchanged. Codex Desktop was not logged out, quit or restarted during this work, as requested by the user.
- The release bundle was installed and launched, signed with the available Developer ID certificate, and its signature verified. It is not a notarized distribution.

## Tests

- 254 XCTest tests and 56 Swift Testing tests passed (310 total).
- Fifteen new tests cover credential parsing, aliases, existing-account no-op, invalid-target preflight, blocked quit, outgoing account changes, target-verification failure, rollback, retained history, failed reopen, concurrent operations, usage validation, and cache identity/expiry.
- Build and `git diff --check` passed.
- Updated light and dark component previews passed visual review after correcting label overlap, reset baseline alignment and spacing around 100% readings. The final round confirmed that no battery tips remain.

## Limits of this check

The switch transaction was exercised with isolated filesystem fixtures and fake desktop controls. A live desktop account handoff was deliberately not run because it would restart the Codex session doing this work. Live saved-account identity/usage checks passed, but they are not a claim that the running desktop was switched. Computer Use could not inspect the menu-only app reliably; visual review used the actual usage component in a preview shell. The user also supplied a native-menu screenshot that exposed the first layout's cropping; those defects were corrected and the installed app replaced.
