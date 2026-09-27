# Claude Switcher

**Your Claude accounts, one click away.**

Open Claude Code as the right account and see its usage before you start. A small native macOS menu bar app, written in Swift and AppKit, with no third-party packages.

<p>
  <img src="assets/usage-light.png" width="320" alt="Light appearance: three example accounts with compact battery gauges, usage percentages, and reset times">
  <img src="assets/usage-dark.png" width="320" alt="Dark appearance of the same account menu">
</p>

<sub>Interface previews rendered with the app’s usage view. Account names and readings are examples.</sub>

## What you get

- **An email for every account.** The app verifies the signed-in identity before opening Claude Code.
- **Separate sessions.** Each added account keeps its own login, settings, and history. Existing terminal sessions keep running.
- **Usage at a glance.** Tiny battery gauges show five-hour and weekly usage, with percentages and reset times in your local timezone.
- **A compact menu.** Click an email to open Code. Account management and other options live under Settings.
- **Desktop profiles too.** Open separate Claude Desktop profiles from the Desktop submenu.

Usage means **percentage consumed**. Green is below 70%, amber is 70–89%, and red is 90% or higher. Unknown readings stay gray.

## Install

You need **macOS 14 or later**, a **Swift 6 toolchain**, and [Claude Code](https://code.claude.com/docs/en/setup) installed. Claude Desktop is optional.

Build on the Mac you plan to use:

```sh
git clone https://github.com/paperfoot/claude-switcher.git
cd claude-switcher
CODESIGN_IDENTITY=- make install
open -a "Claude Switcher"
```

The build is signed locally. This fork does not currently provide a notarized download. Quit an older copy before replacing it.

## Add your accounts

1. Click the people icon in the menu bar. Your existing default Claude Code account appears automatically.
2. Choose **Add account…**, enter an email, and complete Claude’s sign-in flow.
3. Click that email whenever you want to open a session with it.

Repeat for your other accounts. Enable **Settings → Launch at Login** to keep the switcher available after restarting your Mac.

A **Sign in** badge means that profile needs authentication. If Claude reports a different email, the app asks you to sign in to the expected account before opening a session.

**Claude Code and Claude Desktop have separate sign-ins.** The main menu shows verified Code accounts. Desktop profile names do not establish which account is signed in inside the Desktop app.

## How it works

The switcher asks the installed Claude Code CLI for account identity and usage. Claude handles authentication and token refresh; the switcher does not read or copy tokens.

Usage checks send no model prompt. Tools, hooks, MCP servers, and transcript scanning are disabled for those checks. Readings refresh in the background every five minutes, at a known reset, and when due after your Mac wakes. Failed requests back off for fifteen minutes.

The last reading appears immediately, including after restarting the app. Older readings stay visible in gray with a **cached** label while refreshing; a passed reset is marked **Previous · reset passed** until Claude returns the new window. Cached readings expire after seven days and are cleared when sign-out or a different account is detected.

New Code profiles set both `CLAUDE_CONFIG_DIR` and `CLAUDE_SECURESTORAGE_CONFIG_DIR` to their own directory. Inherited authentication and provider overrides are cleared before checking or opening an account. Your default Claude data stays in place.

<details>
<summary>Local files and diagnostics</summary>

| Data | Location |
| --- | --- |
| Switcher settings | `~/.config/claude-switcher/config.json` |
| Cached usage | `~/.config/claude-switcher/usage-cache.json` |
| Added Code profiles | `~/.claude-accounts/<profile-id>` |
| Terminal launch documents | `~/Library/Application Support/Claude Switcher/Launchers` |
| Added Desktop profiles | `~/Library/Application Support/Claude-<profile-id>` |

Settings and cached usage use file permissions `0600`; launcher directories and launch documents use `0700`.

The installed binary provides JSON diagnostics:

```sh
APP="/Applications/Claude Switcher.app/Contents/MacOS/claude-switcher"
"$APP" --accounts  # Account identities and sign-in status
"$APP" --usage     # Usage percentages and reset timestamps
"$APP" --dry-run   # Desktop launch plans; launches nothing
```

Diagnostics can contain email addresses and local paths. Redact them before posting an issue.

</details>

## Compatibility

Verified with **Claude Code 2.1.283** and **Claude Desktop 2.9939.2** on 27 September 2026. Account usage was checked with three independently signed-in Max accounts.

The credential-directory selector, structured usage request, and Desktop profile internals are undocumented Claude behavior. Claude updates may require changes here. Desktop usage comes from local history and has estimated reset times; the main menu reads current account usage through the CLI.

## Development

```sh
swift test
swift build -c release
CODESIGN_IDENTITY=- scripts/bundle.sh
```

The current suite has 292 passing tests covering account isolation, identity mismatches, usage parsing, timeouts, and Desktop profile handling. See [CONTRIBUTING.md](CONTRIBUTING.md) for the code layout and contribution notes.

## Credits and license

Maintained by [Paperfoot](https://github.com/paperfoot). Forked from [Kevin Chau’s Claude Switcher](https://github.com/kevinchau/claude-switcher), with its original history and attribution preserved.

This fork adds isolated Claude Code accounts, verified email labels, and compact live usage gauges. Licensed under [MIT](LICENSE). Not affiliated with Anthropic.
