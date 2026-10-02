# Claude Transplant

`history/transplant.mjs` is adapted from `transplant.js` in [vitaliyhayda/claude-transplant](https://github.com/vitaliyhayda/claude-transplant), version 4.1.0, commit `1b2a836` (27 September 2026).

MIT license: [ClaudeTransplant-LICENSE](ClaudeTransplant-LICENSE).

Local changes:

- Cloud client construction is disabled. The switcher uses local Desktop Code records only.
- Rehomed records clear connector settings, permission grants and Remote Control links.
- Quarantined source records use a hash of their absolute path. Records from another Desktop profile cannot escape the recovery directory or collide with matching filenames.
- A read-only worker check lets the wrapper defer while Desktop Code processes remain open.
- The worker check distinguishes Code SDK processes from MCP connector wrappers.
- Local transfers scan destination histories in relevant project folders, while retaining checks for matching session IDs and fork parents. Unrelated imported projects stay untouched.
- The process lock is exported for the smaller sidebar-copy implementation in `history/copy.mjs`. Version 0.9.2 uses that implementation for new syncs; existing move receipts remain supported for undo.

`history/history.mjs` adds the configured-account allowlist, fresh Desktop identity checks, prepared transfer tokens, path checks and the menu app's compact result format.
