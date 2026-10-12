# Switching the official Claude Chrome extension

Official Claude extension, ID `fcoeoabgfenejglbffodgkkbkcdhcgfn`. Last checked 12 October 2026 against version 1.0.100. Recheck the details below against each new vendor version.

## Current behavior

| Surface | What changes today |
| --- | --- |
| Claude Code's default CLI account | The switcher changes saved credentials. Existing processes retain their current session. |
| Claude.ai in Chrome | The companion restores and verifies cookies in every connected regular profile. A profile that was closed or failed catches up when it reconnects. |
| Official Claude Chrome extension | Follows each successful Chrome switch through its own sign-in (below). |
| Claude Desktop | Its account remains separate. |

## Why the official extension must follow

Claude Code's browser tools and the extension meet on Anthropic's bridge (`wss://bridge.claudeusercontent.com/chrome/<account>`). Claude Code connects with its own login each time; the extension connects with the account it signed in to. When the two differ, `list_connected_browsers` is empty and agents cannot use Chrome.

The extension keeps its OAuth tokens only in `chrome.storage.session`. Chrome clears that store on restart, update, or when the extension is turned off. The extension then attempts a silent re-login with `prompt=none` and `login_hint` set to the account it had before. If Claude.ai in that profile now uses a different account, the server answers `login_required`; the extension records this as a definitive account mismatch and stays signed out. Observed on 12 October 2026 (version 1.0.100): after an earlier switch and a Chrome restart, the extension was signed out and Claude Code saw no browser.

## How the switcher makes it follow

After every profile reports the selected account, the coordinator asks each one to prepare the extension:

1. The companion confirms that Claude.ai in that profile uses the selected account, then turns the official extension off and on with `chrome.management`. Only the session store is cleared; shortcuts, scheduled tasks and other local data stay. Clicking the extension's **Log out** would erase them, so the switcher never does.
2. The companion opens the extension's options page in a new background window. If the extension already belonged to the selected account, its silent re-login succeeds and the page shows the signed-in view.
3. Otherwise the page shows **Log in**. The menu app presses it through macOS Accessibility (`claude-switcher --chrome-extension-login`), because another extension cannot script that page. Accessibility is requested once.
4. The extension opens Anthropic's consent page. The companion clicks **Authorize** only for the official client ID and callback, and only when the page says it is logged in as the selected email. Any other consent page is left alone.
5. The extension finishes its own sign-in and opens `claude.ai/chrome/installed`. The companion closes that tab, reloads the options page and closes the window.

This step runs after the switch is verified and cannot undo it. Results carry `extensionReady` and, on failure, `extensionError` (for example `accessibility_needed`). `claude-accounts extension EMAIL` repeats only this step.

The extension's tokens never pass through the switcher. The step depends on the extension's options page, button labels and consent page, so a vendor update can require changes here.

## Earlier investigation

Investigated 2 October 2026 against version 1.0.98. The extension uses OAuth with PKCE; the external message handler accepts an OAuth callback only for a sign-in it started, and exposes no account-switch command. An earlier prototype patched a copy of the extension to add one; it was removed because editing or shipping Anthropic's extension risks token-refresh, corruption and update problems.

## Current reports

[Anthropic's setup guide](https://support.claude.com/en/articles/12012173-get-started-with-claude-in-chrome) requires signing into the extension itself. The installed source agrees.

[Issue #98621](https://github.com/anthropics/claude-code/issues/98621), opened 1 October, reports that matching accounts were still disconnected after a CLI account switch on macOS. Reconnecting the Claude-in-Chrome MCP server and selecting the browser restored access for that reporter. Here the cause was the extension being signed out after a switch; signing it in to the selected account restored access without reconnecting the MCP server.

[Issue #94764](https://github.com/anthropics/claude-code/issues/94764) reports stale pairing after moving from a personal account to Teams. It is evidence that account identity and browser pairing both need verification, not a reason to reinstall the extension during every switch.

The 12 October check read the extension's published code and signed it in on one profile through its own Log in and consent pages. It did not read private token storage. A multi-profile switch of the official extension has not been verified yet.
