# Verification: 0.7.1

Checked locally on macOS on 28 September 2026.

## Automated checks

347 tests passed: 295 Swift, 25 browser, and 27 Python tests. The release build and local code-signature verification also passed.

The tests cover:

- Missing, expired, and mismatched browser sessions.
- Failed cookie restoration, failed Code activation, and failed rollback.
- A popup selection overlapping a menu selection.
- Delayed requests expiring before changing the browser, and rollback if a deadline passes during restoration.
- Disconnected, timed-out, malformed, or oversized native-host responses.
- Recovery of a pending selection when Chrome reconnects, including expired or missing saved sessions.
- Rejection of stale reconnect acknowledgements and simultaneous selections.
- Preserving cached usage readings, expired reset times, and corrupt cache files.

Browser failures are tested with fake sessions; no live account was deliberately revoked.

## Live checks

Three existing accounts were saved in Keychain. Every directed pair of account switches passed against the installed app. After each selection, the browser's authenticated email matched the email from ordinary `claude auth status`.

Repeated selection of the same account passed. Three simultaneous requests produced one successful switch and two busy responses, leaving Chrome and Code matched. An unknown account was rejected without changing the active account. Saved sessions remained available after restarting Chrome.

Selecting an account while Chrome was closed successfully changed Code and reported that Chrome was disconnected.

## Remaining verification

Chrome retained the older unpacked companion after restarting. Reloading **Claude Switcher Companion** from `chrome://extensions` is required to activate the 0.7.1 browser changes. Automatic reconnect and the new popup failure paths passed automated tests; live verification of those changes remains pending that reload.

These checks verify authentication and switching. They do not claim that an account has remaining inference quota or that a provider will never expire a login.
