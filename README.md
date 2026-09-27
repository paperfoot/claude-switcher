# Claude Switcher — local build

A small native macOS menu-bar app for three Claude accounts, based on
[Kevin Chau’s Claude Switcher v0.6.0](https://github.com/kevinchau/claude-switcher/tree/v0.6.0).
MIT licensed. This local version adds a direct terminal launcher and fixes account-isolation edge cases.

## Use

- Click the people icon in the menu bar.
- Click **Current account**, **Account 2**, or **Account 3** to open or focus that Claude Desktop profile.
- Choose **Open Claude Code → account** for a new Terminal window using that account.
- Sign in once in each new profile. Desktop and terminal sign-ins are separate.
- Use **Rename Profile** to replace the placeholder labels.
- **Copy terminal command** works in an existing shell and clears inherited account selectors.
- **Launch at Login** is optional.

Switching opens or focuses another profile. Running conversations continue under the account they started with.

## Account isolation

Desktop uses a separate Electron user-data directory per account. Existing default Claude data stays in place.
Terminal profiles set both `CLAUDE_CONFIG_DIR` and `CLAUDE_SECURESTORAGE_CONFIG_DIR` to the account’s directory.
This keeps credentials, displayed identity, settings and history together. New terminal profiles start with their own settings and history.
Desktop Code continues using its own app-managed account token and shared local `~/.claude` state.

The original tool changed only the terminal credential directory. Testing Claude Code 2.1.283 with dummy credentials showed
that shared config could report the previous account’s email. The local launcher isolates the config as well.

This app never reads or copies Keychain secrets. The menu checks only whether a credential item exists; that does not prove the token is valid.

## Usage display

Usage bars come from Claude Desktop’s per-profile `plan-usage-history.json`. They update while that Desktop profile is running.
They are cached observations. Reset times are labelled estimates; exact current resets need Claude’s own usage page.
Terminal-only activity is reflected when the corresponding Desktop account refreshes its history.

## Local changes

- Direct **Open Claude Code** menu action using private `.command` files and the system Terminal app. No Apple Events access needed.
- Clear inherited authentication/provider variables before selecting an account.
- Isolate terminal account metadata as well as credentials.
- Detect Desktop directory aliases and duplicate profile paths, including hand-edited config.
- Stop and restore prior state if a new profile cannot be saved.
- Ignore a late launch callback after the launch watchdog expires.
- Label Keychain detection as “credentials found” rather than claiming an authenticated session.

## Build

Requires macOS 14+ and Swift 6. No third-party packages.

```sh
swift test
swift build -c release
VERSION=0.6.1 CODESIGN_IDENTITY=- scripts/bundle.sh
```

The local build is ad-hoc signed for this Mac. It is not a notarized distribution build.
`BIN_DIR` can point `scripts/bundle.sh` at a separate Swift release build directory.

Configuration: `~/.config/claude-switcher/config.json` (mode 0600).
Terminal launch documents: `~/Library/Application Support/Claude Switcher/Launchers` (mode 0700).
New account data: `~/Library/Application Support/Claude-account-2` / `Claude-account-3` and
`~/.claude-accounts/account-2` / `account-3`.

The profile selectors and local usage format are undocumented Claude behavior. They were checked against
Claude Code 2.1.283 and Claude Desktop 2.9939.2 on 27 September 2026. A future Claude update may require an adjustment.
Account-selection tests use fake credentials with network and real Keychain access blocked. Real OAuth sign-in must still be completed by the account owner.

See the [upstream documentation](https://github.com/kevinchau/claude-switcher/blob/v0.6.0/README.md)
for the original Desktop profile implementation and update handling. Its terminal-sharing instructions differ from this build.
