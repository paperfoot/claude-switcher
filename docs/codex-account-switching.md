# Codex account switching: source review

Checked on 28 September 2026 against the installed Codex CLI, `0.158.0-alpha.2.1`, inside `/Applications/ChatGPT.app`.

## Original recommendation and implemented approach

Add a Codex section to the existing menu, using the installed official Codex runtime. Save each account after its first authorization. Selecting an email should save the outgoing login, quit Codex normally, activate and verify the selected account, then reopen Codex. Reuse the compact usage gauges and progress feedback.

The closest source foundation is [liuzhao1225/codex-account-switcher](https://github.com/liuzhao1225/codex-account-switcher/tree/7312cfac3184b77e756a704748a9dab04b443ef8). Its normal-quit policy is preferable for a Mac with concurrent agent work. It still needs adaptation and live verification; this review does not establish that a complete switch works on this Mac.

A seamless change of the running desktop user without reopening the app is **not verified**. Version 0.8.0 now implements the normal-reopen approach in the existing menu, with Keychain storage, aliases, compact usage, and failure recovery. See [0.8.0 verification](verification-0.8.0.md). The user requested that the running Codex session remain untouched during development.

## What the installed runtime actually supports

- OpenAI's [account-switching documentation](https://help.openai.com/en/articles/20001068-use-multiple-accounts-with-account-switching) says its built-in account switcher is available on ChatGPT web, not Codex desktop.
- Generated the experimental JSON schema from the installed binary. It exposes `account/login/start`, `account/read`, and `account/rateLimits/read`, but no `account/sessions/switch` or `account/reload`.
- Started the installed app server with a temporary, empty `CODEX_HOME` and file-only credential storage. With experimental API support enabled, `account/sessions/list` returned `unknown variant`; `account/read` returned no signed-in account. The probe did not use the live account.
- The matching [official source](https://github.com/openai/codex/blob/rust-v0.158.0-alpha.2.1/codex-rs/login/src/auth/manager.rs) caches authentication. Refreshing a token only reloads stored credentials when their account ID matches the cached account. Replacing `auth.json` alone therefore does not reliably switch an existing client.
- The desktop bundle honors `CODEX_CLI_PATH`. The normal desktop sign-in uses the app-server OAuth flow. Experimental external token injection is a protocol capability for a host that owns authentication; it is not a ready-made desktop account switcher.

## Projects inspected

| Project and reviewed revision | Actual approach | Assessment |
| --- | --- | --- |
| [liuzhao1225/codex-account-switcher](https://github.com/liuzhao1225/codex-account-switcher/tree/7312cfac3184b77e756a704748a9dab04b443ef8) | Native Swift UI; stop desktop, save outgoing auth, replace auth, verify using app server, reopen | Best foundation for a normal restart. Aborts if a normal quit does not finish; no force-kill. |
| [4LAU/codex-profile-switcher](https://github.com/4LAU/codex-profile-switcher/tree/4f2f313b5156be84341f21ce43a73b501ff5dc3a) | Native menu, Keychain vault, credential transaction, desktop restart | Useful vault and rollback code. Shutdown escalates to SIGKILL; unsuitable unchanged for active agent work. |
| [lordydord/Codex-Account-Switcher](https://github.com/lordydord/Codex-Account-Switcher/tree/b223b24b05398f51a5194d253df2ba3aff05af81) | Wraps codex-auth; restarts desktop | Forceful process termination and optional automatic rotation add behavior this tool does not need. |
| [Loongphy/codex-auth](https://github.com/Loongphy/codex-auth/tree/1c1c623da4d9d64cf19723a24ac0a800cd18d387) | Credential management; standard clients require restart | Useful command API. Its experimental no-restart desktop mode substitutes the codext runtime. |
| [Loongphy/codext](https://github.com/Loongphy/codext/commit/813c7c61fc841699f8750b9b6334080937e5cf9e) | Adds idle-time auth reload, transition locking, transport invalidation and account notifications | A real implementation of hot switching, but its latest release is based on 0.157.0, older than this Mac's installed runtime. Desktop compatibility is untested. |
| [thibautrey/multivibe](https://github.com/thibautrey/multivibe/tree/d35061a688778d6e9a3b1744b625a84368d21392) | Local gateway with routing and a dashboard | Broader than the required account menu; routing requests is not the same as switching the desktop's signed-in user. |

## Checks and remaining implementation work

The native switcher's unchanged core sources passed their isolated test run (runner reported 42 tests; five transport tests were disabled without fixtures). Separately enabled its installed-CLI transport test: it passed against this Mac's runtime using an empty temporary Codex home, confirming the client can communicate with the installed binary. This does not test a real signed-in account. The complete macOS package test attempt stalled downloading its Sparkle binary dependency and was stopped, so this is not a full-app build result.

Implementation requirements identified during this review:

1. Store saved accounts in Keychain; keep only account labels and usage cache on disk. Preserve refreshed outgoing credentials and serialize switches against usage refreshes.
2. Preflight the target before asking desktop to quit. On failure after quitting, restore the prior credential and reopen the app. The reviewed native implementation can leave the desktop closed on several error paths.
3. Use ordinary app termination and never force-kill working agents. If quitting is blocked, keep the prior account selected and show a short actionable message.
4. Keep the ordinary Codex home so local projects and history are not accidentally replaced with empty profile homes. Cloud account data remains account-specific.
5. Treat credential verification and desktop verification as different checks. The reviewed implementation checks a separate app-server process before reopening; it does not prove which account the reopened desktop used.
6. Verify every saved account and switch pair on this Mac. Include expired login, offline refresh, double click, cancelled quit, failed reopen, and credentials changed by another Codex process.

The three requested accounts have since been saved through the official runtime, with the existing active account kept in place. Existing terminal processes also cache auth: a new or resumed CLI process can use the selected account, while already-running processes cannot be advertised as switched without separate verification.
