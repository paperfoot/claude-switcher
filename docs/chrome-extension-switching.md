# Switching the official Claude Chrome extension

Investigated 2 October 2026. Both installed Chrome profiles, `Default` and `Profile 2`, contain the same official Claude extension, version 1.0.98, ID `fcoeoabgfenejglbffodgkkbkcdhcgfn`.

## Current behavior

| Surface | What changes today |
| --- | --- |
| Claude Code's default CLI account | The switcher changes saved credentials. Existing processes retain their current session. |
| Claude.ai in Chrome | The companion restores and verifies cookies in one connected regular profile. |
| Official Claude Chrome extension | Its account remains separate. |
| Claude Desktop | Its account remains separate. |

The official extension uses OAuth with PKCE. Its access and refresh tokens are stored in the extension's `chrome.storage.session`; its saved account identity is in `chrome.storage.local`. These stores belong to each Chrome profile. The extension has no `cookies` permission or listener that follows a Claude.ai cookie replacement.

Its refresh token renews the current OAuth account independently of web cookies. Silent reauthentication sends the previously saved account as `login_hint`. Changing the website account or restarting the extension therefore does not establish that it switched accounts.

The installed manifest accepts external messages from Claude web origins, with no extension IDs allowed. The external handler supports an OAuth callback only when a matching sign-in is already in progress. It exposes no account-switch command for the companion. Chrome documents this isolation in [externally_connectable](https://developer.chrome.com/docs/extensions/reference/manifest/externally-connectable).

Our own native bridge is another limitation: `bridge/native_transport.py` owns one socket and rejects another native-host instance. Its messages have no profile ID. `browser-extension/background.js` changes cookies in the current profile only.

## What a complete implementation needs

1. A separate connection and stable ID for each enrolled Chrome profile, including reconnect after Chrome closes.
2. Verified website switching in each profile, with per-profile results and recovery after partial failure.
3. The official extension's normal sign-in flow in each profile, followed by verification of its account. The installed extension exposes no supported headless switch API.
4. Reconnection of Claude Code's browser integration after an account change, followed by selection and verification of the intended browser profile.

UI automation could perform step 3, but this remains an untested integration and may require visible OAuth approval. A cookie-only success must never be reported as an extension switch. Editing Chrome's live storage or shipping a patched copy of Anthropic's extension would introduce corruption, token-refresh, and update risks.

## Current reports

[Anthropic's setup guide](https://support.claude.com/en/articles/12012173-get-started-with-claude-in-chrome) requires signing into the extension itself. The installed source agrees.

[Issue #98621](https://github.com/anthropics/claude-code/issues/98621), opened 1 October, reports that matching accounts were still disconnected after a CLI account switch on macOS. Reconnecting the Claude-in-Chrome MCP server and selecting the browser restored access for that reporter. This recovery needs testing here before being automated.

[Issue #94764](https://github.com/anthropics/claude-code/issues/94764) reports stale pairing after moving from a personal account to Teams. It is evidence that account identity and browser pairing both need verification, not a reason to reinstall the extension during every switch.

This investigation inspected static extension code and the switcher, and checked current documentation and user reports. It did not change browser logins, inspect private token storage, or validate a complete multi-profile account switch.
