# Changelog

## [1.0.7] — 2026-10-25

- Fix stretched row containers that left large gaps after image thumbnails and short text icons; keep Preview and Copy aligned to the trailing edge.
- Add spacing regression coverage across row widths, text lengths, and reused thumbnail/icon states.

## [1.0.6] — 2026-10-25

- Default to Today with previous/next-day navigation and access to All history.
- Keep browsing and drafts stable during capture; retain bounded summary caches, prefetch pages, incrementally insert recent rows, and cache matching counts.
- Check for new clipboard content on opening and remember popup frames per display.
- Include the larger popup layout and bounded row image thumbnails.
- Add plain-text paste, Command-1–9 quick paste, type-to-search, a Pinned filter, readable app names, draft text cleanup, and timed recording pauses.
- Preserve existing history, preferences, and the signed-update trust key; increase the bundle build to 9.

## [1.0.5] — 2026-10-24

- Enable automatic paste by default and remove the separate enable switch and confirmation while retaining macOS permission checks.

## [1.0.4] — 2026-10-24

- Add Restart Clipboard to permission controls, protect unsaved edits, and reopen the same app directly to Permissions after the old process exits.
- Block restart during backup/import or a paste test; explain that restarting refreshes permission recognition but does not grant access or replace Developer ID signing.

## [1.0.3] — 2026-10-24

- Paste with one row click; retain modifier-click multi-selection and keyboard navigation.
- Add always-visible 36-point Preview and Copy icon buttons on each row.
- Ignore opening events and stale focus callbacks; cancel pending paste when dismissing or reopening.
- Keep cached rows visible during refresh, preserve scroll position, avoid full-history ID reads for first-page selections, and load details only for visible previews.
- Retain existing permission settings and signed GitHub updates (build 6).

## [1.0.2] — 2026-10-24

- Add a minimal clipboard app icon with all macOS icon sizes.
- Show Accessibility trust and Command-V event access separately, refresh while Settings is active, and open paste failures directly on Permissions.
- Explain stale ad-hoc permission grants and reveal the exact running app in Finder for reauthorization.
- Add an isolated cross-app paste test that uses a named private pasteboard and never reads or replaces the user's clipboard.
- Wait until Clipboard relinquishes focus and the destination remains frontmost before pasting; recheck access during the operation and send at most one paste command.
- Retain signed GitHub updates with version 1.0.2, build 5.

## [1.0.1] — 2026-10-18

- Separate disabled automatic paste, missing event-posting permission, and unavailable destination failures.
- Replace the non-activating popup focus mode with a normally activating borderless panel; restore focus using macOS cooperative activation; skip redundant activation when the destination is already frontmost and allow the main run loop to restore keyboard focus.
- Add a Permissions page with clipboard-reading state, event-posting access, and content-free last-paste diagnostics. No additional privacy permissions are requested.
- Keep one current local build and clean obsolete workspace installers.
- Add Sparkle 2.10.0 updates from GitHub Releases, signed archives and feed verification, a daily-check preference, and manual checking.
- Wait for app activation before making the popup key; avoid dismissing during its initial focus transition.
- Open preview when clicking an already-selected row, retain the selected entry after capture refresh, and avoid full-history ID reads for cached selections.
- Protect unsaved individual and combined edits before an update restart.
- Open paste setup directly on General and add an explicit access recheck.
- Add simulated permission and activation regression tests; no unrelated app receives keystrokes during testing.

## [1.0.0] — 2026-10-18

First release of Clipboard for macOS 14 and newer.

- Compact native menu-bar popup with outside-click dismissal and a 40/60 list/preview layout.
- Text editing, image previews, row Copy, editable combined copying, and keyboard shortcuts.
- SQLite/FTS5 history, search, filters, pins, retention, deletion confirmation, and Undo.
- Local capture with confidential-marker checks, application exclusions, and recording controls.
- Optional automatic paste with Accessibility setup, permission status, and manual-copy fallback.
- Launch at login, settings export, validated history import/export, and optional encrypted backups.
- Universal ZIP/DMG downloads and SHA-256 checksums.

Distribution: ad-hoc signed; not Developer ID signed or notarized. Full UI automation, the OS/hardware compatibility matrix, and Instruments performance certification remain pending; see VERIFICATION.md.

[1.0.0]: https://github.com/aagzamov-dev/Clipboard_macos/releases/tag/v1.0.0

[1.0.1]: https://github.com/aagzamov-dev/Clipboard_macos/releases/tag/v1.0.1

[1.0.2]: https://github.com/aagzamov-dev/Clipboard_macos/releases/tag/v1.0.2
