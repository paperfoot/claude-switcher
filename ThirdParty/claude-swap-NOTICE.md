# claude-swap

`engine/switch_engine` began as [realiti4/claude-swap](https://github.com/realiti4/claude-swap) version 0.26.0, tag `v0.26.0` (commit `0d2176d`), and is maintained here as Claude Switcher's own account engine. Upstream changes are not merged in.

MIT license: [claude-swap-LICENSE](claude-swap-LICENSE).

Local changes:

- The package is `switch_engine` and runs as `claude-switcher-engine`, from the app bundle, on the standard library alone. Saved accounts, Keychain items and settings keep claude-swap's locations and names, so an existing claude-swap store carries over untouched.
- Removed: the Textual dashboard (`tui`), the rumps menu-bar app and its launch agent, export and import, self-upgrade and the update check, and terminal theme detection. With them go the `textual` and `rumps` dependencies.
- `truststore` is replaced by `system_trust.py`, which adds the macOS system root certificates to Python's default HTTPS context through `/usr/bin/security`.
- The test suite keeps every upstream test for the code that remains; it needs only `pytest`.
