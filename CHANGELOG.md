# Changelog

User-visible changes, newest first. From 0.6.1 on, version numbers belong to this fork. Upstream releases with the same numbers are different software.

## Unreleased

- The account engine that saves, switches and auto-switches Claude Code logins is now part of Claude Switcher instead of a separate `claude-swap` install. It began as claude-swap 0.26.0 and runs from the app on Python's standard library alone, with no third-party packages, so setup no longer needs `uv tool install claude-swap`. Saved accounts stay where they were and carry over untouched.
- Auto-switch no longer keeps away from an account whose five-hour window has reset since it left it, so that account's last weekly points, if they reset soonest, are used rather than expiring.
- Auto-switch now spends the account whose weekly limit resets soonest first, while it still has room, so the last few percent of an account is used before it resets instead of expiring. Before, it waited for the selected account to hit the limit and then picked the account with the most room left, which saved the perishable quota for last. An account counts as spent at 98% (was 95%).
- After an automatic switch that Chrome could not follow, the menu's "Chrome needs attention" warning now clears once Chrome catches up, whether you sign in or Chrome simply reopens. Before, it stayed until the next switch, even hours after Chrome had recovered.
- Each account whose saved Chrome login has expired now shows a small amber sign-in mark after its email, so "choose one to sign in" says which ones; hover it for what to do. Logins that only expire soon get the warning line but no mark, since choosing them works as usual.
- The menu-bar icon no longer keeps a warning triangle for hours when Code switched and only Chrome lagged: it shows for ten seconds, then the icon returns to normal while the menu keeps the details. A switch that failed outright still keeps it.
- An automatic switch onto an account whose Chrome login is known to be dead no longer restores, tests and rolls back its cookies in Chrome. Code still moves, and the menu says to choose that account to sign in.
- A switch warning can no longer stay up for good when Chrome's "done" message was lost: a profile that already has the selected account says so again on its next check. Companion 0.9.4.
- Switching to an account whose Chrome login claude.ai signed out now opens claude.ai's sign-in page in Chrome, without signing out the account you were on. Sign in once and the switch finishes by itself: the menu's warning turns into a tick and Claude in Chrome follows. You never need to log out of one account to log in to another, which is what kills saved logins.
- Saved Chrome logins are checked against claude.ai every six hours, so the menu warns about a dead one before you pick it. Companion 0.9.3.
- When a switch reaches Code but Chrome's saved login for that account was signed out on claude.ai, the menu now says the Chrome login expired and to sign in once, instead of a vague "Chrome could not switch". Any other Chrome failure says Chrome kept the previous account. Companion 0.9.2.
- The palette no longer shows the name of the model behind free-form requests: the row reads **Ask**, and its answers show only how likely each one is.

## 1.1.1 — No setup chores after updates

- The Chrome companion reloads itself within a minute of an update; clicking **Reload** in `chrome://extensions` is no longer needed. Companion 0.9.1 is the last version that needs that click once.
- Claude Switcher asks for Accessibility once at launch instead of during the first switch.

## 1.1.0 — Claude in Chrome follows every switch

- After a Claude switch, Anthropic's Claude extension in each connected Chrome profile signs in to the same account, so Claude Code's browser tools keep working. Before, the extension stayed on the old account, or signed itself out after Chrome restarted, and agents saw no browser.
- The switcher turns the extension off and on, presses its **Log in** and approves Anthropic's consent page only for the selected email. It never uses the extension's **Log out**, which erases its shortcuts and scheduled tasks.
- Pressing **Log in** needs Accessibility for Claude Switcher; macOS asks once. `claude-accounts extension EMAIL` repeats just this step.
- Companion 0.9.0 adds the `management` and `scripting` permissions for this.

## 1.0.1 — No more Keychain prompts after updates

- Codex logins and the TypeSafe key are stored through Apple's `security` tool, like claude-swap's own items. A locally built app no longer asks for the login password after every rebuild. Logins saved by 1.0.0 move over the first time each is read, which can ask one last time.

## 1.0.0 — Command palette

- Press ⌥Space anywhere, or choose **Command…** in the menu bar, to open a command palette. Type a few letters of an account and press ↩ to switch, or type a command such as `diagnostics` or `quit`.
- A single **Command…** item replaces the Settings submenu. Every setting is reachable from the palette.
- Gauges and percentages use one colour scale everywhere: green below 70%, amber from 70%, red from 90%.
- A Chrome profile that was closed or disconnected during a switch catches up with the selected account when it next connects.
- Fewer background Keychain writes.
- Auto-switch at limit (palette: `auto`): at 95% of the five-hour or weekly limit, Claude Code and every connected Chrome profile move to the account with the most headroom, using claude-swap's auto-switch engine. Never within ten minutes of a manual choice; Codex is never switched automatically.
- Usage readings keep their colour as they age; one that is more than 20 minutes old shows as `~84%`, and a passed reset shows `↻ due` instead of the finished window's percentage.
- Adding an account in coordinated mode saves it for switching right after sign-in; before, selecting it failed until the setup script ran again.
- Switches carry one deadline through every layer and restore what changed before the caller gives up; a Chrome profile's host keeps answering during a popup switch.
- Removed the unused prototype that patched Anthropic's Chrome extension.
- Optional: with a TypeSafe API key stored, free-form requests can be interpreted by TypeSafe. Off by default.

## 0.9.7 — Fresh Code credentials (2026-10-10)

- Selecting an account, including the one already active, refreshes an existing `~/.claude/.credentials.json` that fell behind the Keychain after a manual login. The file is updated under Claude's credential locks and is never created just to force a refresh.
- New `claude-accounts refresh-code` does the same after `cswap add`.

## 0.9.6 — Safer partial switches (2026-10-09)

- If Chrome fails, the verified Code selection stays active and the Chrome failure is reported on its own. Code is never switched back because of a browser problem.
- If Chrome is closed, Code switches at once and the companion applies the pending selection when it reconnects.
- New local switch log, also available as `claude-accounts logs`. It records results, timings, the failing step and HTTP status, never tokens, cookies, account emails or URLs. It rotates at 256 KiB.
- Companion 0.7.4.

## 0.9.5 — Steadier Chrome connections (2026-10-05)

- While Chrome is open, the companion checks its connection every minute and reconnects if it stops responding.
- Every five minutes it verifies and saves the current browser login, including renewed session cookies. These checks never change the selected account.
- Failed switches name the connection and the restore step. A failed cookie write names the cookie, never its value.
- Companion 0.7.3.

## 0.9.4 — Several Chrome profiles (2026-10-04)

- A Claude selection switches every connected Chrome profile and verifies each one. If one profile rejects it, the profiles already changed are restored.
- Agent commands: `scripts/claude-accounts` and a matching agent skill.

## 0.9.3 — Permission defaults for copied history (2026-10-02)

- Copied Desktop history uses your `permissions.defaultMode` from `~/.claude/settings.json`, or Manual if it is unset. Connector grants are still cleared. See [permission defaults](docs/permissions.md).

## 0.9.2 — Faster history sharing (2026-10-02)

- History sharing copies missing Desktop sidebar entries instead of moving them. Source entries, shared transcripts and sidecars stay in place. Existing destination titles and IDs do not change.
- Duplicates are matched by CLI session ID and project path. Conflicting Desktop IDs are refused.
- Syncs check small records instead of scanning conversation contents, so large libraries finish in seconds instead of timing out.
- Writes are atomic and journalled. An interrupted copy can be undone before a retry.

## 0.9.1 — History fixes (2026-10-01)

- MCP connector processes no longer count as open Code sessions. They had blocked automatic transfers.
- A removed project folder no longer blocks a transfer. Original paths are kept.
- Transfers inspect only the relevant project folders, so unrelated imported sessions stay untouched.
- `--login-item on|off|status` sets or checks launch at login.

## 0.9.0 — Desktop Code history sharing (2026-10-01)

- Optional sharing of local Claude Desktop Code history across accounts. After a verified Desktop sign-in, the switcher waits for open Code sessions to close, quits Claude normally, transfers the sidebar records and reopens the same profile.
- Transcripts stay in place. Every transfer has a private recovery record and an undo. Connector settings, permission grants and Remote Control links are cleared in copied records.
- The main menu holds accounts, usage, status and Settings. Connection and Desktop controls moved into Settings.

## 0.8.1 — Stable menu (2026-09-28)

- Background refreshes update the open menu in place. Its size, rows and labels no longer jump.
- Usage labels align with account names, and section headings have more contrast.

## 0.8.0 — Codex accounts (2026-09-28)

- A Codex section next to Claude. Connect each account once through the official Codex browser login. Saved logins live in the Keychain; labels, aliases and the usage cache hold no tokens.
- Selecting a Codex account checks it first, asks Codex to quit normally, swaps the login, verifies it and reopens Codex. Codex is never force-quit. If something fails, the previous login is restored when that is safe.
- Five-hour and weekly usage share one line. A window the provider does not report shows as unknown, not zero.

## 0.7.2 — Expired cookies and switch feedback (2026-09-28)

- Fixed saved accounts that failed to restore after an idle night because a secondary cookie had expired. Expired cookies are now skipped on restore and rollback, and Chrome's own validation and device cookies are left alone.
- The menu-bar icon spins during a switch, shows a green check for three seconds after success, turns amber when only Code switched and stays red after a failure.

## 0.7.1 — Hardened switching (2026-09-28)

- Overlapping selections are serialised: one switch runs and the others report busy.
- An unknown account is rejected without changing the active one.
- Selecting while Chrome is closed switches Code, reports Chrome as disconnected, and finishes Chrome when the companion reconnects.
- Late requests expire before they touch the browser, and malformed or oversized messages from the native host are rejected.
- After updating, reload the companion in `chrome://extensions`. Chrome can keep an unpacked extension's old code even after a restart.

## 0.7.0 — Chrome and Code together (2026-09-28)

- Choosing an email switches Claude Code's default login, through claude-swap 0.26.0, and Claude.ai in Chrome, through the new companion extension.
- Browser sessions are saved in the Keychain through a local native-messaging host. No network port is opened.

## 0.6.1 to 0.6.5 — Fork start (2026-09-27)

- The menu shows each account's verified Claude Code email.
- Compact five-hour and weekly gauges with exact reset times, coloured green, amber and red.
- Cached readings survive restarts and refresh in the background about every five minutes and after wake. A passed reset is marked instead of shown as zero.

## 0.6.0 and earlier

Kevin Chau's original Claude Switcher. See [kevinchau/claude-switcher](https://github.com/kevinchau/claude-switcher).
