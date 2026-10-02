# Version 0.9.2 verification

Checked on 2 October 2026.

## Changes

New history syncs copy missing Desktop sidebar entries. They retain source entries and leave shared transcripts and sidecars in place. Existing destination titles and record IDs stay unchanged. Duplicate conversations are matched by CLI session ID and project path; conflicting Desktop IDs are refused. Account-specific connector configuration and grants are cleared from new entries.

The previous engine scanned conversation contents and sidecars, compared histories, then repeated that work before writing. It exceeded the helper timeout with a library of 996 sessions. New syncs check small records and transcript locations instead. Legacy transfer receipts remain available for undo.

Writes are exclusive and atomic, with a journal written first and a process lock shared with legacy transfers. Interrupted copies can be undone before retry. Fresh account evidence is checked again after Claude closes. Code workers are scoped to the configured app path, so tests using isolated fake app paths do not depend on real Desktop activity.

## Checks

- 15 copy tests passed, including a 1,000-record fixture, repeat sync, existing destination titles, duplicate CLI IDs, collisions, identity changes, expired plans, interrupted-copy recovery and undo after transcript growth.
- 15 legacy history tests passed.
- 56 Swift tests, release build, Developer ID signature and native menu refresh checks passed.
- Live plan found 996 missing entries in about 2.4 seconds.
- After the user's current Code task became idle, the live copy added 996 entries in about 3.9 seconds. All 998 pre-existing records across the configured accounts were byte-identical afterward.
- The signed-in account now has 997 local sessions across 160 project folders. The live Code sidebar displayed the project groups and the user's existing Repository history review conversation.
- One old record still lacks a recoverable CLI transcript and was skipped.
- Version 0.9.2 is installed; macOS reports startup at login enabled. Codex authentication and processes were unchanged.
