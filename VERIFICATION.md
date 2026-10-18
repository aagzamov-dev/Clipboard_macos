# Verification and release gates

This is a development candidate. Building successfully is not sufficient to claim that all release criteria have passed.

## Automated coverage

- Core storage/retrieval, literal FTS queries, Unicode, pagination, and a synthetic 10,000-entry dataset.
- Editable combined-copy drafts, original-history preservation, Revert, combined/individual draft budget, explicit save, rich-representation removal, Command/Shift selection, and consecutive capture deduplication rules.
- Pinned retention/count limits, deletion Undo and expiration, managed image/file references, orphan cleanup, missing images, and original-file preservation.
- Private storage permissions, symlink rejection, future schema refusal, corrupt database preservation, and failed writes preserving existing records.
- Plain/encrypted archive round-trips, repeated import, conflicting UUIDs, wrong passwords, encrypted tampering, traversal rejection, cancellation, invalid images, oversized text, empty text, and embedded NUL text.
- Native popup layout at list/preview widths, focus-loss dismissal with draft preservation, and automatic capture resuming after starting inside an excluded app.
- Actual AppKit representation conversion using named private pasteboards, confidential markers, unknown/explicit sources, multi-file references, self-generated write suppression, and fixture paste without event posting.

The latest development run passed 27 core tests and 9 platform tests. Test output is recorded in `.build/compact-tests.log`; repeat `Scripts/test.sh` before release.

The selected-item blank-window failure was reproduced with a native fixture render. The preview background was filling an invalidation rectangle outside its view bounds. Drawing is now bounded explicitly, with a pixel-level paint-spill regression test. Native single/bulk fixture renders and compact/large resize checks pass; this does not replace full interactive UI automation.

## Performance procedure

Use a Release build on an 8 GB Apple Silicon Mac. Record model, OS version, Xcode version, dataset, and power mode. Test a text-dominant 10,000-entry dataset and a separate mixed-image/file dataset. Measure at least 30 warm openings and search queries.

- Instruments Points of Interest: `local.clipboard.Clipboard` / `History` / `Open history` measures through first-page delivery.
- Time Profiler and Core Animation: warm opening p95 <100 ms; search p95 <100 ms after debounce; smooth 60 Hz scrolling without recurring >33 ms frames.
- Allocations/Leaks: target idle physical memory approximately 20–40 MiB after closing previews, no retained decoded-image growth after repeated selection, bounded 500-summary page cache.
- Energy Log/Activity Monitor: five minutes idle, target mean CPU <0.5% of one core. Verify no payload reads or database writes for an unchanged clipboard. Do not confuse nominal 500 ms polling with a zero-wakeup claim.
- Stress: rapid clipboard changes, repeated image previews, 2 MiB edits/Undo, concurrent capture/export, cancellation, and disk pressure. Validate responsiveness and cleanup.

A development Debug test on the available Mac queried the end of the 10,000-entry FTS dataset in approximately 5.4 ms. This is a single synthetic query measurement, not the required p95, memory, or energy certification.

## Manual compatibility and permission matrix

Before public release, complete and record results for:

- macOS 14 and current macOS on Apple Silicon; Intel runtime smoke tests. Cross-compiling x86_64 does not establish Intel runtime compatibility.
- VoiceOver, keyboard-only use, contrast, transparency, light/dark appearance, resizing, display changes, Spaces, and full-screen applications.
- Clipboard privacy default/allowed/denied states, repeated-prompt suspension, revoked paste permission, shortcut conflicts, login-item approval/revocation, system sleep, display sleep, and session changes.
- Automatic paste into representative apps with permission; target disappearance/focus changes; manual Copy fallback. Never claim successful text insertion solely from event dispatch.
- Draft editing during background capture, switching filters, Save/Revert, close/quit Save all/Discard/Cancel, bulk confirmation, pinned deletion, 10-second Undo, and permanent clear.
- Invalid and cancelled imports, near-full disk, interrupted attachment writes, migration failure, missing attachments, and snapshot/export consistency.

Local Xcode UI automation encountered a macOS authentication requirement. UI tests compile, but an unattended passing UI-test run must be obtained in an authorized macOS development session. A native fixture window and its bulk text-preview accessibility state were inspected; this does not replace the complete matrix above.

## Distribution gate

Use `Scripts/package.sh` to prepare a universal candidate. Developer ID signing, notarization/stapling, clean-machine Gatekeeper installation, approved release notes, and all compatibility/performance gates remain mandatory before a public release. No release, push, branch, or Git repository settings were created by the implementation process.

Compact layout checks cover 40/60 pane proportions at multiple sizes, resetting a previously enlarged popup to 720 × 440 points, portrait/landscape image fitting, downsampling to a 1024-pixel edge, and releasing the image on dismissal. Native fixture renders were inspected for both image orientations and editable combined text. Performance targets still require Instruments measurements.
