# Contributing

Small, focused changes are welcome. For a bug, include your macOS and Claude Code versions, what you expected, and what happened. Redact email addresses, local paths, and any credentials from screenshots or logs.

## Make a change

1. Fork the repository and create a branch.
2. Make the change. Add or update tests when behavior changes.
3. Run `swift test` and `swift build -c release`, then open a pull request with the problem, the fix, and how you checked it.

Use disposable profiles for account and launch testing. Do not exercise sign-in or destructive Desktop update behavior against someone’s real accounts.

## Code layout

- `Sources/ClaudeSwitcher/`: AppKit menu, drawing, actions, and diagnostics.
- `Sources/ClaudeSwitcherCore/`: account isolation, usage parsing, configuration, and Desktop profile logic.
- `Tests/ClaudeSwitcherTests/`: fixtures and tests for the core library.
- `scripts/`: app bundling, signing, disk images, and notarization.

Keep the main menu short. Account identity must come from Claude Code, and usage must belong to the displayed account. Unknown or expired usage must never appear as a fresh zero. Cached values must be labeled, and passed resets must be shown as previous usage.

## Local build

```sh
swift test
swift build -c release
CODESIGN_IDENTITY=- scripts/bundle.sh
open "build/Claude Switcher.app"
```

The default bundle signature is suitable for a local build. Distributing a notarized app requires a Developer ID certificate and Apple notarization credentials; never commit either.
