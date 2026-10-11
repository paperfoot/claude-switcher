# Claude Desktop Code history

Claude Desktop keeps a separate Code sidebar for each signed-in account. History sharing carries your local Code conversations across the Desktop accounts configured in the switcher.

Type `history` in the palette and turn on **Share Code history**. It needs Node.js 22 or newer at `~/.local/bin/node`, `/opt/homebrew/bin/node` or `/usr/local/bin/node`.

## What happens

After a verified Desktop sign-in, the switcher waits for open Code processes to close. It then quits Claude normally, copies the missing sidebar entries and reopens the same Desktop profile.

- Existing entries in both accounts are kept.
- Project paths, conversation IDs, transcripts and sidecars stay where they are.
- Sharing follows the account signed in to Desktop. Selecting a Chrome or Claude Code account does not sign Desktop in.

## What is copied

Only accounts already configured in the switcher take part. Missing transcripts are skipped. Changed or conflicting records and scheduled sessions stop the transfer. Cloud chats and Cowork sessions are excluded.

History from a removed project folder stays available. Restore or select that folder before you resume work in it.

New copies use your `permissions.defaultMode` from `~/.claude/settings.json`, or Manual if it is unset. Account-specific connector grants and Remote Control links are cleared. Desktop also remembers permission modes per folder and per session, and Bypass needs the account's **Allow bypass permissions mode** setting. See [permission defaults](permissions.md) and [Claude's permission modes](https://code.claude.com/docs/en/permission-modes#switch-permission-modes).

## Terminal sessions

Sessions that never appeared in Desktop can be imported with Claude's **Help → Troubleshooting → Import Claude Code CLI Sessions…**. Claude imports eligible local transcripts and refreshes its sidebar. The switcher can then carry those entries across your Desktop accounts.

## Retry and undo

**Sync history now** retries a sync that stopped. Recovery records live privately in `~/.config/claude-switcher/desktop-history`.

**Undo last history sync** removes the entries added by the latest sync while Claude is closed, then turns automatic sharing off. Undo refuses destination records that have changed since. Original entries and newer transcript content stay intact.

## Source

Syncing copies small local records without rescanning conversation contents. Atomic writes, process checks, locking and legacy recovery use code adapted from [claude-transplant 4.1.0](https://github.com/vitaliyhayda/claude-transplant). See the [pinned source and local changes](../ThirdParty/ClaudeTransplant-NOTICE.md).
