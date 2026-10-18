# Clipboard

A small, native clipboard manager for macOS. Find what you copied, edit it, and get back to work.

**macOS 14+ · Apple Silicon & Intel · Swift + AppKit · MIT**

[Download v1.0.0](https://github.com/aagzamov-dev/Clipboard_macos/releases/tag/v1.0.0) · [All releases](https://github.com/aagzamov-dev/Clipboard_macos/releases) · [Report an issue](https://github.com/aagzamov-dev/Clipboard_macos/issues)

![Clipboard with an editable combined preview](docs/screenshots/text-preview.png)

Native app screenshots with example clipboard content.

## Quiet by design

- **A compact popup.** Open with **⌥⌘V** or the menu-bar icon. Click outside to dismiss.
- **Useful previews.** A 40% list and 60% preview in a 720 × 440-point window. Images fit without stretching the window.
- **Edit immediately.** Select text and start typing. Copy uses your draft; **⌘S** saves it to history.
- **Copy several entries.** Command-click or Shift-click, edit the combined text, then Copy. Original entries stay unchanged.
- **Find and keep.** Search, filter by date/type, and pin favorites. Unpinned history expires after 30 days by default.
- **Your Mac, your history.** No accounts, analytics, cloud sync, or background network requests. Optional password-encrypted backups.

Built with native Apple frameworks and system SQLite, with no third-party runtime dependencies. History loads in bounded pages; image previews downsample to a 1024-pixel edge and release when dismissed. Performance measurements and remaining compatibility checks are documented in [Verification](VERIFICATION.md).

<details>
<summary>Image preview</summary>

![A fitted image preview inside the compact popup](docs/screenshots/image-preview.png)

</details>

## Install

1. Download **Clipboard-v1.0.0-universal.dmg** from the [release](https://github.com/aagzamov-dev/Clipboard_macos/releases/tag/v1.0.0).
2. Open it and drag **Clipboard.app** into **Applications**. A ZIP is also available.
3. Launch Clipboard and choose **Start local history**. Recording starts automatically on future launches.

**Signing:** v1.0.0 uses an ad-hoc signature and is **not Developer ID signed or notarized**. macOS may block the first launch. Review [Apple’s guidance](https://support.apple.com/en-us/102445) before deciding whether to allow it. Checksums are included with the release; source builds are available too.

To update, quit the running copy before replacing the app. History stays in your Application Support folder.

## Automatic paste

Copy works without Accessibility access. Automatic paste is optional:

1. Open **Settings → General** and enable **Automatic paste**.
2. Choose **Open Accessibility Settings**, then allow Clipboard in **Privacy & Security → Accessibility**. If it is missing, use **+** to select the installed app in Applications.
3. Return to Clipboard. The permission status refreshes automatically. Open your destination app, then choose Paste from Clipboard.

The same setup link is available in **Settings → Privacy** and the paste fallback dialog. Clipboard sends Command-V once; the destination controls whether it accepts it.

## Shortcuts

| Shortcut | Action |
| --- | --- |
| ⌥⌘V | Toggle history; configurable in Settings |
| ↑ / ↓, ⇧↑ / ⇧↓ | Navigate or extend selection |
| ⌘C / ⌘⇧C | Copy from the list / copy the current entry or combined draft |
| Enter / ⌘Enter | Paste one selected entry / the current draft |
| ⌘S | Save an individual text draft |
| ⌘P | Pin or unpin one entry |
| ⌘F | Search |
| Delete / ⌘⌫ | Delete selected history entries |
| Escape | Clear bulk selection, close preview, then dismiss |

Text fields retain normal editing shortcuts. Unsaved drafts stay in memory while the popup is dismissed. Quitting offers to save or discard them.

## Privacy

History is local, with private file permissions, but **the database is not encrypted**. Supported confidential markers are skipped; this is not guaranteed secret detection. Original referenced files are never deleted. Read the [privacy and backup details](docs/PRIVACY.md) before storing sensitive content.

## Build and contribute

Open `Clipboard.xcodeproj` with Xcode 27.0, or run:

```sh
Scripts/build.sh
Scripts/test.sh
```

See [Development](docs/DEVELOPMENT.md), [Release process](docs/RELEASING.md), [Changelog](CHANGELOG.md), and [verification status](VERIFICATION.md).

[MIT License](LICENSE)
