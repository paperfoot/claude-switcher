# Switching the official Claude Chrome extension

Investigated 2 October 2026 against the official Claude extension, ID `fcoeoabgfenejglbffodgkkbkcdhcgfn`, version 1.0.98. The installed Chrome profiles contain the same extension; they now run version 1.0.100. Recheck the details below against each new vendor version.

## Current behavior

| Surface | What changes today |
| --- | --- |
| Claude Code's default CLI account | The switcher changes saved credentials. Existing processes retain their current session. |
| Claude.ai in Chrome | The companion restores and verifies cookies in every connected regular profile. A profile that was closed or failed catches up when it reconnects. |
| Official Claude Chrome extension | Its account remains separate. |
| Claude Desktop | Its account remains separate. |

The official extension uses OAuth with PKCE. Its access and refresh tokens are stored in the extension's `chrome.storage.session`; its saved account identity is in `chrome.storage.local`. These stores belong to each Chrome profile. The extension has no `cookies` permission or listener that follows a Claude.ai cookie replacement.

Its refresh token renews the current OAuth account independently of web cookies. Silent reauthentication sends the previously saved account as `login_hint`. Changing the website account or restarting the extension therefore does not establish that it switched accounts.

The installed manifest accepts external messages from Claude web origins, with no extension IDs allowed. The external handler supports an OAuth callback only when a matching sign-in is already in progress. It exposes no account-switch command for the companion. Chrome documents this isolation in [externally_connectable](https://developer.chrome.com/docs/extensions/reference/manifest/externally-connectable).

## Our side

Each Chrome profile runs its own native host with its own private socket under `~/.config/claude-switcher/browsers/`. A switch contacts every connected profile and restores the profiles already changed if another one rejects the selection. Each profile remembers, in its own extension storage, the newest selection it applied; it stores no cookies or email addresses there. A profile that was closed during a switch, or was restored because another profile failed, adopts the selection when it reconnects. A later manual sign-in in that profile, including through **Add another account**, or a Chrome-only switch is kept instead.

## What remains for the official extension

1. The official extension's normal sign-in flow in each profile, followed by verification of its account. The installed extension exposes no supported headless switch API.
2. Reconnection of Claude Code's browser integration after an account change, followed by selection and verification of the intended browser profile.

UI automation could perform step 1, but this remains an untested integration and may require visible OAuth approval. A cookie-only success must never be reported as an extension switch. An earlier prototype patched a copy of the official extension pinned to version 1.0.98; it has been removed because it no longer matches the installed version. Editing Chrome's live storage or shipping a patched copy of Anthropic's extension would introduce corruption, token-refresh, and update risks. The official extension keeps its own sign-in.

## Current reports

[Anthropic's setup guide](https://support.claude.com/en/articles/12012173-get-started-with-claude-in-chrome) requires signing into the extension itself. The installed source agrees.

[Issue #98621](https://github.com/anthropics/claude-code/issues/98621), opened 1 October, reports that matching accounts were still disconnected after a CLI account switch on macOS. Reconnecting the Claude-in-Chrome MCP server and selecting the browser restored access for that reporter. This recovery needs testing here before being automated.

[Issue #94764](https://github.com/anthropics/claude-code/issues/94764) reports stale pairing after moving from a personal account to Teams. It is evidence that account identity and browser pairing both need verification, not a reason to reinstall the extension during every switch.

This investigation inspected static extension code and the switcher, and checked current documentation and user reports. It did not change browser logins, inspect private token storage, or validate a complete multi-profile switch of the official extension.
