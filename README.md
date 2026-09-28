# Claude Switcher

**Choose an account once. Use it in Chrome and Claude Code.**

A small native macOS menu bar app with compact five-hour and weekly usage gauges. Selecting an email changes the account used by your next ordinary `claude` or `claude --resume` command. The Chrome companion switches Claude.ai in the same browser profile.

<p>
  <img src="assets/usage-light.png" width="320" alt="Compact Claude account usage gauges in light appearance">
  <img src="assets/usage-dark.png" width="320" alt="Compact Claude account usage gauges in dark appearance">
</p>

<sub>Usage-view previews with example accounts. The coordinated menu adds an active-account checkmark and Chrome connection status.</sub>

## The workflow

1. Choose an email in the menu bar.
2. Claude.ai uses that account in your connected Chrome profile.
3. In your existing Ghostty, iTerm2, or other terminal, stop Code when ready and run `claude --resume` or `claude --continue`.

Switching does not open a terminal. Your working directory, normal `~/.claude` history, and setup stay in place. Already-running Code sessions are not stopped; restarting them is the reliable way to use the selected account immediately. Claude's own credential cache can delay changes inside a running process.

The menu-bar icon spins during a switch. A green check appears for three seconds after success. A red warning stays visible after failure; amber means Code switched but Chrome still needs attention. The selected account updates as soon as the switch is verified.

Code and Chrome have separate credentials. The switcher coordinates them; it does not run `/login` on every switch. Initial authorization is required once per account, and expired or revoked logins may need authorization again.

## Install

Requires **macOS 14+**, a **Swift 6 toolchain**, [Claude Code](https://code.claude.com/docs/en/setup), and [uv](https://docs.astral.sh/uv/getting-started/installation/) for the account backend.

```sh
git clone https://github.com/paperfoot/claude-switcher.git
cd claude-switcher
uv tool install 'claude-swap==0.26.0'
CODESIGN_IDENTITY=- make install
python3 scripts/setup-coordinated.py
open -a "Claude Switcher"
```

Quit an older copy before replacing it. This is a local build, signed on your Mac; this fork does not currently provide a notarized download.

The setup script imports the Code accounts already configured in `~/.config/claude-switcher/config.json`. It registers the local Chrome companion host and leaves the active Code account unchanged. It never overwrites an account already saved in the backend. Existing authenticated profiles can be configured with `expectedEmail` and `credDir`; both Claude directory selectors must refer to the directory used when that profile signed in.

### Connect Chrome once

Chrome requires a user to load an unpacked extension. The installer does not change browser policies or force-install anything.

1. Open `chrome://extensions`, enable **Developer mode**, and choose **Load unpacked**.
2. Select `~/Library/Application Support/Claude Switcher/BrowserExtension`.
3. Sign in to a configured account at Claude.ai. The companion saves it automatically; its popup shows the detected email and also offers **Save this Claude login**.
4. Choose **Add another account** in the companion, then sign in to the next account. This clears the browser session locally without calling Claude’s logout endpoint, so saved sessions are not intentionally revoked. Repeat once per configured account.

Pin the companion if you want to switch from Chrome too. **Settings → Set up switching…** opens the setup guide.

After updating the app and rerunning the setup script, open `chrome://extensions` and click **Reload** on **Claude Switcher Companion**. Chrome can retain an unpacked extension's old code even after a browser restart. Your saved accounts stay in Keychain.

If Chrome is closed, selection switches Code immediately. When the companion reconnects, it restores the pending selection from the saved browser login. If that login has expired, sign in again through **Add another account**. The app only reports **Chrome and Code switched** after both sides verify the selected email. If the companion rejects a selection, the coordinator tries to restore the previous Code account and reports the failure.

## Usage at a glance

Tiny battery gauges show **percentage consumed**, with reset times in your timezone. Green is below 70%, amber is 70–89%, and red is 90% or higher.

Readings refresh in the background about every five minutes and when due after wake. Cached values survive restarts and stay visible in gray while refreshing. A passed reset is marked **Previous · reset passed**, rather than inventing a fresh zero. Cached readings expire after seven days.

## How switching works

- **Code:** [claude-swap 0.26.0](https://github.com/realiti4/claude-swap/releases/tag/v0.26.0) saves and restores the default Claude Code credentials and account metadata, cooperating with Claude's credential locks. Code keeps using its usual history directory. The backend handles token refresh and usage collection.
- **Chrome:** a Manifest V3 extension saves Claude.ai sessions in the Mac's **Keychain**, through a local native-messaging host. It verifies the current email before saving, checks the restored email after switching, and restores the previous cookies if switching fails. No cookies are saved in extension storage or exported by diagnostics.
- **Connection:** a private local Unix socket connects the menu app to Chrome's native host. The host accepts the companion's exact extension origin. There is no listening network port or remote debugging connection.

The extension touches Claude.ai cookies only. It does not switch Google accounts, Gmail, or unrelated sites. All Claude.ai tabs within the connected Chrome profile share the selected login; switching can reload them. Claude Desktop still has a separate sign-in and remains under the Desktop submenu.

Claude's cookie and credential formats are not public compatibility contracts. Changes in Claude can require maintenance. Chrome switching is supported for one connected regular browser profile at a time.

## Diagnostics

```sh
APP="/Applications/Claude Switcher.app/Contents/MacOS/claude-switcher"
"$APP" --switch person@example.com
"$APP" --switch-status
"$APP" --accounts
```

Diagnostics contain account emails and usage, not tokens or cookies. Redact personal details before posting an issue. An `ok: true` result with `browserReady: false` means Code switched and Chrome still needs setup.

Settings and usage cache live in `~/.config/claude-switcher/`, with private file permissions. The installed companion lives in `~/Library/Application Support/Claude Switcher/`. The Code backend manages its own account store under `~/.claude-swap-backup/`.

## Development

```sh
swift test
node --test browser-extension/*.test.js
python3 -m unittest discover -s bridge -p 'test_*.py'
swift build -c release
CODESIGN_IDENTITY=- scripts/bundle.sh
```

Tests cover account isolation, usage caching, identity verification, cookie restoration, rollback, concurrent selections, and native-message framing. See [CONTRIBUTING.md](CONTRIBUTING.md).

## Credits and license

Maintained by [Paperfoot](https://github.com/paperfoot). Forked from [Kevin Chau's Claude Switcher](https://github.com/kevinchau/claude-switcher), with original history and MIT attribution preserved. Coordinated Code switching uses [Onur Cetinkol's claude-swap](https://github.com/realiti4/claude-swap), also MIT licensed.

Licensed under [MIT](LICENSE). Not affiliated with Anthropic.
