# Version 0.9.1 verification

Checked on 1 October 2026.

## Fixes

- MCP connector wrappers no longer count as active Desktop Code workers. They had prevented automatic history transfers.
- Local transfers inspect destination histories from relevant project folders and matching session IDs or fork parents. This avoids rescanning hundreds of unrelated imports; existing destination records remain available for collision checks.
- Removed project folders no longer block transfer of saved conversations. Their original paths are preserved.
- The installed executable accepts `--login-item on|off|status` through macOS ServiceManagement.

## Verified

- Release build and Developer ID signature passed.
- Fifteen isolated history tests passed, including connector wrappers, actual SDK workers, unrelated imported projects, removed project folders, transfer and undo.
- Claude's built-in importer added 989 eligible local CLI sessions. Its ownership checks excluded seven histories already registered to other Desktop accounts.
- The corrected switcher moved those seven histories into the signed-in Desktop account. The completed receipt reports successful verification and no failures. Original sidebar records have a private backup and a recovery journal.
- Claude reopened and logged 996 loaded Code sessions. The live Code sidebar showed the restored project groups; an older Desktop conversation opened with its saved messages and prompt field. No new prompt was sent.
- One old Desktop record has no recoverable CLI transcript and was left in place.
- Version 0.9.1 is installed. macOS reports the login item as `enabled`.
- Codex authentication and processes were not changed.
