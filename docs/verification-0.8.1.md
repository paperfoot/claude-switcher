# Version 0.8.1 verification

Checked on 28 September 2026.

## Change

Background account and usage refreshes previously replaced the complete open menu. Version 0.8.1 updates the existing rows instead. Structural changes, account labels and badges are applied before the next opening. Long accessibility descriptions now live on the custom views instead of menu-item titles. Status messages use a fixed-width view.

The usage labels now align with account names, section headings have stronger contrast, the footer has a little more breathing room, and Claude-specific footer actions are named explicitly. Account switching and credential handling are unchanged.

## Checks

- Release build passed.
- `scripts/check-menu-refresh.sh` passed. It compiles the real menu components and measures native AppKit menu sizes offscreen. Repeated refreshes preserve menu sizes, custom-view frames, item counts, and item/view identity. It covers 0/9/99/100% readings, fresh/cached/missing data, changed selection, busy states, long messages, reset-date changes, live accessibility labels, and structural changes on the next opening.
- Light and dark component previews passed visual review for alignment, contrast, padding and clipping.
- Installed bundle signature verified; only the switcher was restarted. No live account handoff or Codex restart was performed for this UI update.

The AppKit regression measures the real menu classes, but does not automate the user's on-screen menu. Component previews are illustrative, not screenshots of a live account switch.
