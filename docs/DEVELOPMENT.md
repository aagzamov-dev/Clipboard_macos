# Development

## Local workflow

Run `Scripts/local.sh` to build one current local app and ZIP in `.build/local`. After a successful build it removes obsolete generated Clipboard app bundles and installers from this workspace, while preserving history, settings, running copies, and source code. It does not update or remove the installed app in Applications.

Local builds use the current Mac’s architecture. Keep the installed app in one fixed location when testing macOS permission grants.

## Build and run

Open `Clipboard.xcodeproj` in Xcode 27.0 and run the shared **Clipboard** scheme, or run:

```sh
Scripts/build.sh
open .build/xcode/Build/Products/Debug/Clipboard.app
```

The app lives in the menu bar. Choose **Start local history** to consent to capture. Opening the app does not capture existing clipboard contents. The initial shortcut is **Option–Command–V**; conflicts can be changed in Settings. Launch at login is off until enabled.

For an isolated demo, run the Debug executable with `--fixtures`. This uses temporary history, does not start monitoring or register the global shortcut, does not persist real preferences or start the updater, and writes only to a private pasteboard. Release builds ignore fixture flags.

## Tests and architecture

```sh
Scripts/test.sh
```

The local `ClipboardCore` package owns models, SQLite/FTS5, payload validation, drafts/selection, retention, attachment consistency, and archives. The root Swift package is a test harness compiling the app’s platform integration files. Integration tests use only named private pasteboards and simulated fixture paste behavior. They require a macOS login session with the pasteboard service available.

AppKit UI tests are in `Tests/ClipboardUITests.swift`:

```sh
xcodebuild -project Clipboard.xcodeproj -scheme Clipboard \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/ui-tests CODE_SIGN_IDENTITY=- test
```

macOS may require the developer to authenticate or enable UI testing. The app’s own clipboard capture and Accessibility permissions are not required for fixture tests. Do not bypass system security prompts to run automation.

`Scripts/create-project.py` deterministically regenerates the checked-in Xcode project after adding native source files. Builds do not require running the generator.

## Releases

See [Release process](RELEASING.md) for versioning, signing, tagging, and automated GitHub publishing.
