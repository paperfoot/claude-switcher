# Version 0.9.0 verification

Checked on 1 October 2026.

## Changes

- The main menu contains accounts, usage, temporary status and Settings. Connection and Desktop controls moved into Settings.
- Optional Claude Desktop Code history sharing follows a freshly verified Desktop login. It waits for Code workers to close, quits Claude normally, transfers local sidebar records and reopens the same profile.
- Original transcript files and sidecars remain in place. Transfers have private recovery records and an undo action. Connector settings, permission grants and Remote Control links are cleared in destination records.
- Codex account switching is unchanged. No live Codex login, logout, account handoff, quit or restart was used for this update.

## Checks

- Swift tests: 56 passed.
- Native AppKit menu regression passed: stable size, row identity, selection, usage and accessibility during refreshes.
- History wrapper: 12 tests passed, including identity evidence, allowlisting, path checks, worker deferral, expired tokens, conflicting records, same-profile and cross-profile transfer, timestamp updates during quit, undo refusal and preservation of newer transcript content.
- Copied-data transfer and undo passed: eight Desktop records, seven matching histories, one missing history, seven unchanged transcript hashes, 1,623 unchanged sidecar files and eight byte-identical restored records. All eight live records were unchanged.
- Release build passed; bundle signed with the existing Developer ID. Version 0.9.0 is installed, one Switcher process is running, and history sharing is enabled. Only the Switcher was restarted.
- The installed read-only history plan returned `desktop_not_ready`; no live history was moved.
- On-screen menu verification was blocked by the locked Mac. The native offscreen menu geometry checks passed.

The history tests operate on isolated temporary files. Claude Desktop is currently signed out or closed, so transfer into a real signed-in Desktop sidebar has not yet been verified. The helper rejects cached account IDs without a successful initialization in the current Desktop process.

## Codex investigation

The installed Desktop source handles `account/updated` internally, but its exposed request allowlist does not offer login or reload. The official app-server supports login through a connection owned by its host; a new helper app-server does not change the one already running inside Desktop. Replacing stored credentials alone is insufficient to guarantee a live Desktop switch. `refreshToken` also checks that the saved account matches the cached account and refuses a different identity, so account reads cannot be used as a cross-account reload command.

Sources: [OpenAI app-server](https://learn.chatgpt.com/docs/app-server), [auth manager](https://github.com/openai/codex/blob/main/codex-rs/login/src/auth/manager.rs), [account processor](https://github.com/openai/codex/blob/main/codex-rs/app-server/src/request_processors/account_processor.rs).
