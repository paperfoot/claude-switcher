# Claude Switcher — local build

A native macOS menu bar launcher for multiple Claude accounts, based on
[Kevin Chau’s Claude Switcher v0.6.0](https://github.com/kevinchau/claude-switcher/tree/v0.6.0).
MIT licensed. No third-party packages.

## Use

Click the people icon, then an email to open Claude Code in Terminal.
Each account keeps its own login, settings and history. Existing sessions continue as before.

- **Sign in** opens Claude’s official login flow. After signing in, choose the email again to open Code.
- **Add account…** takes an email and starts that login flow.
- **Desktop** opens or focuses separate Claude Desktop profiles.
- **Settings** contains account management, launch at login and diagnostics.

The main menu reads the email and plan from `claude auth status --json`.
It checks again before opening an account. A different or missing email cannot silently open
an account under the expected email’s label. Failed checks stay visibly distinct from signed-out accounts.

Desktop and Claude Code sign-ins are separate. A Code email does not prove the Desktop profile is
signed in to the same account. Desktop profile names can be changed under Settings.

## Isolation and status checks

Terminal profiles set both `CLAUDE_CONFIG_DIR` and `CLAUDE_SECURESTORAGE_CONFIG_DIR` to one private
account directory. Inherited authentication and provider variables are cleared before checking or
opening an account. Default Claude data stays in place.

The app asks the official CLI for its account summary. Tiny battery gauges beneath each email
show the five-hour and weekly percentage **used**, alongside the exact reset time. Usage comes
from Claude Code's structured `/usage` request. The CLI owns authentication and refresh; the
switcher never reads tokens. Account identity is checked before and after each usage request.
No model prompt is sent, and hooks, tools, MCP servers and the transcript scan are disabled.

Checks run in the background when the menu opens; usage is cached for five minutes. There is
no polling timer. Failed requests back off for fifteen minutes, stale readings are hidden,
and elapsed windows show an unknown value until refreshed. Menu rows update in place.

Desktop profiles use separate Electron user-data directories. Desktop Code keeps its app-managed
account token and the default local Code data. Desktop usage bars are read from each profile’s local
`plan-usage-history.json` and shown only in the Desktop submenu. They are cached observations;
reset times there are estimates. The main menu uses exact account usage instead.

## Build

Requires macOS 14+ and Swift 6.

```sh
swift test
swift build -c release
VERSION=0.6.3 CODESIGN_IDENTITY=- scripts/bundle.sh
```

The local build is ad-hoc signed for this Mac. It is not a notarized distribution build.
`BIN_DIR` can point the bundle script at a separate release build directory.

```sh
claude-switcher --accounts  # JSON with account identity and matching status; no tokens
claude-switcher --usage     # Verified usage percentages and exact reset timestamps; no tokens
claude-switcher --dry-run   # Desktop launch plans; launches nothing
```

Configuration: `~/.config/claude-switcher/config.json` (mode 0600).
Terminal launch documents: `~/Library/Application Support/Claude Switcher/Launchers` (mode 0700).
New account data: `~/.claude-accounts/<profile-id>` and
`~/Library/Application Support/Claude-<profile-id>`.

The credential selector, structured usage request and Desktop profile internals are undocumented Claude behavior.
They were checked against Claude Code 2.1.283 and Claude Desktop 2.9939.2 on 27 September 2026.
Regression tests cover isolation, email mismatches, signed-out accounts, timeout handling and safe login commands.

See the [upstream documentation](https://github.com/kevinchau/claude-switcher/blob/v0.6.0/README.md)
for the original Desktop profile implementation and update handling. Its terminal-sharing instructions differ from this build.
