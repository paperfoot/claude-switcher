---
name: claude-accounts
description: Switch saved Claude accounts in Chrome, Claude Code, or both using the installed macOS menu bar switcher. Use when asked to change Claude user, switch Chrome Claude sessions, check saved accounts, or verify a switch.
---

# Claude accounts

Use `~/.local/bin/claude-accounts`. It returns account metadata as JSON; credentials stay in Keychain.

```sh
~/.local/bin/claude-accounts accounts
~/.local/bin/claude-accounts chrome-status
~/.local/bin/claude-accounts logs
~/.local/bin/claude-accounts chrome person@example.com --expect-profiles 2
~/.local/bin/claude-accounts claude person@example.com
```

- **Chrome only:** use `chrome`. This leaves Claude Code unchanged. For normal and Work Chrome together, require `--expect-profiles 2`; check every returned profile has `ok: true` and the requested email. Connection IDs identify live companion instances, not Chrome profile names.
- **Chrome and Code:** use `claude`. Require `ok: true`, the requested `codeEmail`, and `browserReady: true`. Then check `chrome-status` for the requested number of profiles. If the user only asked for Chrome, use the Chrome-only command.
- `partial: true` with `code_only_after_web_failure` means Code is already on the requested account. Do not undo it. Inspect `browserError` and `claude-accounts logs`, then recover Chrome separately with `chrome`.
- Logs contain safe error codes, stages, timings, and HTTP status. They never contain credential values or account names.
- Resolve partial names against `accounts`. Ask only if more than one saved account matches. Honour the latest target when the user corrects it.
- The companion must be enabled separately in each Chrome profile. `browser_profiles_missing` means the requested number is not connected; do not report all profiles switched. Open the missing Chrome profile, then inspect its companion before retrying once.
- First-time setup uses `~/Library/Application Support/Claude Switcher/BrowserExtension` in Chrome's **Load unpacked** dialog. Follow the current tool's confirmation rules when installing it. Do not force-install it with policies or edit live Chrome cookie databases.
- `web_login_needed` or `web_login_expired` requires reconnecting that Claude account. Do not repeatedly switch, call logout, or claim the saved account works. Preserve other saved logins.
- For `web_switch_failed`, inspect `failureStep` and `failedConnection` in the JSON. Reload **Claude Switcher Companion** at `chrome://extensions` in the affected Chrome profile and retry once. Verify the companion version through `chrome-status`. A restore failure does not by itself prove the saved login expired. If the retry fails, preserve the returned diagnostics and investigate; do not erase the saved login.
- `chrome-status` includes `lastHealthCheckAt` and `lastSessionSavedAt` as Unix milliseconds per connection. Background checks run while Chrome is open. They keep each profile's current login saved; they do not guarantee inactive sessions remain valid or authorize rotating through accounts to keep them alive.
- Already-running Claude Code processes can retain their previous login. The user can stop and run `claude --resume` or `claude --continue`; do not stop active work yourself.
- This switches Claude.ai website sessions. Google/Chrome profile identities, Anthropic's separate Claude browser-extension OAuth account, and Claude Desktop have separate logins.
- Do not invoke `--codex-switch`, log out Codex, or restart the Codex app hosting the current agent. Codex account changes need a separate handoff outside that active app.

For UI verification, open Claude.ai in each requested Chrome profile and inspect its account menu. A successful result in one profile is not proof about another.

The app's source is `~/Projects/claude-switcher`. If the command is missing, inspect the installed app and source before rebuilding or reinstalling anything.
