# Claude Desktop permission defaults

Verified on 2 October 2026 against Claude Desktop 2.19675.0, its installed JavaScript bundle, and the current Anthropic documentation.

## Why prompts can return

Desktop reads `permissions.defaultMode` from Claude Code settings. A mode remembered for a folder, or saved in an existing Desktop session, can override that default. Desktop also requires a separate per-account opt-in before Bypass is available. An unavailable Bypass mode falls back to Accept edits in the installed app.

Before switcher 0.9.3, history copies were assigned Manual mode. Version 0.9.3 instead uses the explicit user default from `~/.claude/settings.json`; it retains Manual as the fallback. Existing destination records are preserved. Connector grants are still cleared when copying between accounts.

The Bash sandbox is independent of the permission mode. Its user-level setting is `sandbox.enabled`. Project and managed settings can override user settings.

Sources: [permission modes](https://code.claude.com/docs/en/permission-modes#switch-permission-modes), [Desktop](https://code.claude.com/docs/en/desktop#choose-a-permission-mode), [sandboxing](https://code.claude.com/docs/en/sandboxing).

## Desktop storage

The installed app stores account opt-ins and folder choices under `preferences` in `~/Library/Application Support/Claude/claude_desktop_config.json`. It caches that file in memory. Editing the file while Desktop is running can lose changes when the app next saves its preferences. Use the app's settings or close Desktop before editing.

Session records have their own `permissionMode`. Changing the global default does not change the mode of a running task. The mode picker updates both the live process and the saved record.

## Remaining prompts

Bypass does not remove every approval. Browser safety checks, macOS permissions, explicit ask rules, managed connector policy, and some destructive-operation checks remain separate.

Recent feedback corroborates this limitation:

- [GitHub #96096](https://github.com/anthropics/claude-code/issues/96096), reported 22 September: repeated Chrome tool approvals in Bypass mode on Windows. This is a user report, not a verified macOS reproduction.
- [GitHub #91495](https://github.com/anthropics/claude-code/issues/91495): built-in browser approvals despite an allowed-site setting.
- [X, @jdnoc, 2 October](https://x.com/jdnoc/status/2105818097668272556): continued approval prompts with Bypass selected. The post does not identify a version or platform.

The older [Desktop settings issue #29026](https://github.com/anthropics/claude-code/issues/29026) describes builds that ignored `settings.json`. Current documentation and installed source now confirm settings support; the old local-storage workaround is not needed for the default itself.

## Switcher verification

All 32 history tests pass, including copying with an explicit Bypass default and rejecting a prepared copy if that default changes before application. The 0.9.3 bundle passes code-signature verification. These checks do not establish that every browser approval can be suppressed.
