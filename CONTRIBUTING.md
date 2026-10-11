# Contributing

Small, focused changes are welcome. For a bug, include your macOS and Claude Code versions, what you expected, and what happened. Redact email addresses, local paths, and any credentials from screenshots or logs. Use example addresses such as `work@example.com` in code, tests, docs and screenshots.

## Make a change

1. Fork the repository and create a branch.
2. Make the change. Add or update tests when behavior changes, and add a line to [CHANGELOG.md](CHANGELOG.md) for anything a user will notice.
3. Run the checks listed under **Development** in the README, then open a pull request with the problem, the fix, and how you checked it.

Use disposable profiles for account and launch testing. Do not exercise sign-in or destructive Desktop update behavior against someone’s real accounts.

## Code layout

- `Sources/ClaudeSwitcher/`: AppKit menu, drawing, actions, and diagnostics.
- `Sources/ClaudeSwitcherCore/`: account isolation, usage parsing, palette matching, configuration, and Desktop profile logic.
- `Tests/ClaudeSwitcherTests/`: fixtures and tests for the core library.
- `browser-extension/`: Claude.ai session switching and popup.
- `bridge/`: local native messaging and coordinated Code switching.
- `history/`: Claude Desktop Code history sharing (Node.js).
- `extension-adapter/`: an experimental local patch for the official Claude extension. The installer does not use it.
- `skills/`: the agent skill for `claude-accounts`.
- `scripts/`: setup, app bundling, signing, disk images, and notarization.

Keep the menu bar menu short; new commands belong in the command palette. Account identity must come from Claude Code, and usage must belong to the displayed account. Unknown or expired usage must never appear as a fresh zero. Old readings must be marked as old, and a passed reset must show as due until a fresh reading arrives.

## Local build

```sh
swift test
swift build -c release
CODESIGN_IDENTITY=- scripts/bundle.sh
open "build/Claude Switcher.app"
```

The default bundle signature is suitable for a local build. Distributing a notarized app requires a Developer ID certificate and Apple notarization credentials; never commit either.
