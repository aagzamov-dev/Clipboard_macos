# Verification and release gates

v1.0.2 is distributed with an ad-hoc signature and explicit limitations in the release notes. Developer ID signing/notarization, full runtime compatibility coverage, authenticated UI automation, and Instruments performance certification remain outstanding. Building successfully does not establish those results.

## Automated coverage

- Core storage/retrieval, literal FTS queries, Unicode, pagination, and a synthetic 10,000-entry dataset.
- Editable combined-copy drafts, original-history preservation, Revert, combined/individual draft budget, explicit save, rich-representation removal, Command/Shift selection, and consecutive capture deduplication rules.
- Pinned retention/count limits, deletion Undo and expiration, managed image/file references, orphan cleanup, missing images, and original-file preservation.
- Private storage permissions, symlink rejection, future schema refusal, corrupt database preservation, and failed writes preserving existing records.
- Plain/encrypted archive round-trips, repeated import, conflicting UUIDs, wrong passwords, encrypted tampering, traversal rejection, cancellation, invalid images, oversized text, empty text, and embedded NUL text.
- Native popup layout at list/preview widths, focus-loss dismissal with draft preservation, and automatic capture resuming after starting inside an excluded app.
- Actual AppKit representation conversion using named private pasteboards, confidential markers, unknown/explicit sources, multi-file references, self-generated write suppression, and fixture paste without event posting.

The latest development run passed 27 core tests and 23 platform tests. Test output is recorded in `/tmp/clipboard-v102-tests.log`; repeat `Scripts/test.sh` before release.

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

Remaining compatibility and permission coverage:

- macOS 14 and current macOS on Apple Silicon; Intel runtime smoke tests. Cross-compiling x86_64 does not establish Intel runtime compatibility.
- VoiceOver, keyboard-only use, contrast, transparency, light/dark appearance, resizing, display changes, Spaces, and full-screen applications.
- Clipboard privacy default/allowed/denied states, repeated-prompt suspension, revoked paste permission, shortcut conflicts, login-item approval/revocation, system sleep, display sleep, and session changes.
- Automatic paste into representative apps with permission; target disappearance/focus changes; manual Copy fallback. Never claim successful text insertion solely from event dispatch.
- Draft editing during background capture, switching filters, Save/Revert, close/quit Save all/Discard/Cancel, bulk confirmation, pinned deletion, 10-second Undo, and permanent clear.
- Invalid and cancelled imports, near-full disk, interrupted attachment writes, migration failure, missing attachments, and snapshot/export consistency.

Local Xcode UI automation encountered a macOS authentication requirement. UI tests compile, but an unattended passing UI-test run must be obtained in an authorized macOS development session. A native fixture window and its bulk text-preview accessibility state were inspected; this does not replace the complete matrix above.

## Distribution gate

`Scripts/package.sh` prepares versioned universal ZIP and DMG assets, checksums, and build metadata. Tags trigger the GitHub release workflow after tests and UI-test compilation. The current release is not notarized; release notes disclose this and the uncompleted checks above. Developer ID signing and notarization remain a future distribution improvement requiring credentials.

Compact layout checks cover 40/60 pane proportions at multiple sizes, resetting a previously enlarged popup to 720 × 440 points, portrait/landscape image fitting, downsampling to a 1024-pixel edge, and releasing the image on dismissal. Native fixture renders were inspected for both image orientations and editable combined text. Performance targets still require Instruments measurements.

Automatic-paste settings now expose Accessibility status and a direct System Settings link, recheck access when the app becomes active, and retain manual Copy as a fallback. Regression coverage simulates denied, granted, and disabled states without requesting real permissions or posting events.

v1.0.1 separates disabled paste, permission denial, and unavailable destinations. Simulated activation tests cover already-frontmost targets, cooperative activation, and terminated destinations. Real destination-app acceptance still requires interactive confirmation; no test sends keystrokes to unrelated apps.

Local build 3 changes the history panel back to normal app activation while retaining its borderless popup design and accessory activation policy. The Permissions page displays capture access, event-posting access, and an in-memory last-attempt status. The local-only build script retains a single deliverable directory and skips running apps during old-build cleanup. The user confirmed automatic paste works in local build 3. The user subsequently authorized GitHub updates and the v1.0.1 release.

## v1.0.1 updater and popup checks

Sparkle 2.10.0 is pinned by exact version, resolved revision, and the upstream binary checksum. Its release tools are separately pinned by SHA-256. The app requires Ed25519 verification of the feed and archives before extraction, disables profiling, and requires a user action to install. Fixture mode does not initialize the updater. The private key stays in the local Keychain and the approved encrypted repository secret; pull-request validation receives no secret.

Regression coverage checks clicking the initially selected row and preserving the selected entry after capture refresh. A normal cached selection no longer enumerates all history IDs. The popup waits for app activation before taking keyboard focus and ignores intermediate focus loss while opening.

An actual future-version installation/relaunch and Intel/macOS 14 runtime smoke tests remain pending. Universal compilation and signed-feed checks do not substitute for these checks. Performance targets remain unmeasured.

Local candidate verification accepted the valid feed and ZIP signatures and rejected modified copies of both. The complete nested app signature, universal arm64/x86_64 binaries, ZIP/DMG checksums, and fixture UI-test compilation passed.

## v1.0.2 permissions and icon

New tests cover conflicting Accessibility/event-posting states, waiting for the source app to relinquish activation, a complete successful paste pipeline on a private board with simulated event dispatch, revocation before/after clipboard preparation, and event creation failure without retries. Automated tests do not post keystrokes to unrelated apps or read the developer's general clipboard.

The bundled paste-test app provides a separate explicit live check: a named private clipboard carries known test text; the receiver confirms the paste action and text through a private temporary result file. The main app sends only one command, terminates its helper, releases the named board, and removes the temporary files. A successful live result establishes delivery to that test app, not acceptance by every destination app.

The installed v1.0.1 designated requirement is tied to code hashes and no Developer ID identity is available locally. Reauthorization after an ad-hoc update remains necessary on systems where macOS invalidates the old grant. Settings now states this limit instead of presenting an enabled Accessibility switch as proof of access.

The icon is generated at native sizes and bundled as AppIcon.icns. Both the paste helper and icon are checked in the release bundle. The user requested delivery through the existing updater instead of installing a local test copy. Live v1.0.2 paste verification remains unconfirmed; the explicit Permissions test is available after updating.

## v1.0.3 interaction changes

The release adds one-click row paste, separate 36-point Preview/Copy buttons, first-mouse acceptance, opening-event filtering, popup-session checks for delayed focus loss, and cancellation of pending paste on dismissal/reopening. Selection/navigation alone does not paste. Refresh retains displayed rows until new results arrive, preserves scroll position, skips full ID enumeration for first-page selections, and avoids hidden detail loading.

New regression tests cover independent Preview/Copy actions, duplicate-click suppression, cancellation before writing, and repeated reopening with an older focus-loss callback pending. Existing layout/image tests now explicitly invoke Preview. Core tests and build-for-testing run locally without launching the built app; native integration tests and universal packaging run in GitHub validation. No local install or app replacement is performed. Full interactive destination-app acceptance and Instruments measurements remain pending.

## v1.0.4 restart recovery

Restart Clipboard is available in permission controls and returns to Permissions after relaunch. A private readiness pipe prevents the parent from quitting before its helper is ready. The helper runs before AppKit application initialization, verifies its parent PID, waits for that process to exit, then asks Launch Services to open the same bundle once. A timeout leaves the original process alone and does not open a duplicate. Unsaved drafts use the existing close-confirmation flow; active archive operations and paste tests block the restart button.

Six targeted regression tests exercise button routing/busy state, parent validation, readiness failure, delayed exit, timeout, and failed launch without retry. These use injected process checks and launch callbacks; they do not restart the running app. App/UI-test compilation is separate from live relaunch verification. Full tests and universal packaging run remotely. This change does not solve the ad-hoc signing identity limitation; Developer ID credentials are deferred at the user's request.
