# Verification: 0.7.2

Checked locally on macOS on 28 September 2026.

## Failure and fix

A saved account failed to restore after being idle overnight. Its main Claude session remained within its expiry, but an auxiliary cookie had expired. Restoring a cookie with an expired timestamp can delete it and return no cookie, which the switcher incorrectly treated as a fatal restoration failure. See [Chrome's cookie API](https://developer.chrome.com/docs/extensions/reference/api/cookies).

Expired cookies are now skipped on restore and rollback. The native host also filters them when returning a saved login, so the fix works with an older companion already loaded in Chrome. Browser validation and device cookies are excluded from account restoration. The updated extension preserves the current browser's versions of those cookies.

A second saved web login still failed verification. It was refreshed through its existing Google sign-in and saved again; repeated switches then passed. The test does not establish why that earlier login was rejected.

## Checks

- **355 automated tests passed:** 295 Swift, 30 browser, 30 Python.
- Regression tests model Chrome returning no cookie for an expired cookie write. They cover expiry boundaries, rollback, preservation of browser validation cookies, and the native host's compatibility filtering.
- Five repeated live selections across all three saved accounts passed. Each check compared the actual Chrome identity with ordinary Claude Code's authenticated email. Switching plus verification took about 4–6 seconds.
- The final visible Claude website account and Code identity matched the selected account.
- The release build and strict local code-signature verification passed.

## Visual feedback

The menu bar shows a native spinner while switching, a green check for three seconds after verified success, a persistent red warning on failure, and amber for Code-only success. A new attempt cancels the old success reset, so a delayed reset cannot hide the new spinner.

The actual AppKit components were rendered in light and dark appearances. Green, red, and amber glyphs passed visual review for contrast and alignment. The static captures confirm spinner visibility, not animation timing. Native computer-use inspection could not bind the windowless menu app, so a direct automated menu-click check was unavailable; live account switching was tested through the installed coordinator used by that menu.
