# Claude account link prototype

Makes a local copy of Claude's Chrome extension follow the Claude.ai account selected by the Switcher companion. Live account testing is pending.

The patch adds one message handler for the companion's exact extension ID. It requests a fresh OAuth login for the verified website account, checks the returned identity, then uses Claude's existing token storage and account-change cleanup. Tokens stay inside the official extension. No second credential vault is added.

The first authorization for an account may still need Claude's normal consent screen. Later switches attempt the existing silent OAuth flow. Consent, expired sessions, mismatched identities and superseded requests produce explicit failures.

## Build locally

```sh
python3 extension-adapter/patch-local.py \
  "$HOME/Library/Application Support/Google/Chrome/Default/Extensions/fcoeoabgfenejglbffodgkkbkcdhcgfn/1.0.98_0" \
  build/claude-linked
node --test extension-adapter/*.test.js
```

The builder accepts only the reviewed 1.0.98 file hashes. It preserves the extension ID and existing permissions, and adds the companion to `externally_connectable.ids`. It writes to a new directory and leaves the installed source intact. A newer vendor build needs review before a patch can be produced.

Vendor files are copied from the user's installation into ignored `build/` output; they are not distributed in this repository. Loading that output as an unpacked extension is a separate installation step. The normal Switcher installer does not install it.

## Verification

18 mocked tests cover sender restrictions, OAuth state and callback checks, wrong accounts, consent-required responses, deadlines, account changes during authorization, token-refresh invalidation and concurrent requests. Generated JavaScript passes syntax checks, and the preserved manifest key yields the original extension ID. These checks do not establish that Anthropic will accept silent account switching in a real browser.
