# Releases

Releases are prepared on `release/vX.Y.Z`, reviewed through a pull request to `main`, and tagged on the merged commit. Do not retag or replace a published release.

1. Update `ClipboardApp/Info.plist`, `CHANGELOG.md`, and `docs/releases/vX.Y.Z.md`.
2. Update screenshots using native fixtures only. Never publish personal clipboard history.
3. Run `Scripts/test.sh`, compile fixture UI tests, and run `Scripts/package.sh`.
4. Review signing status, release notes, tests, compatibility gaps, and artifacts. Merge the release pull request after validation succeeds.
5. Create an annotated `vX.Y.Z` tag on the merged commit, then push that tag. The release workflow validates the tag against the bundle version, runs tests, builds the app for both architectures, and publishes a GitHub release with ZIP, DMG, SHA256SUMS, BUILD-INFO.json, and a signed appcast.xml.

The release build signs update archives and the appcast using the `SPARKLE_EDDSA_PRIVATE_KEY` repository secret. Only tag builds can access this secret; validation never uses it. The public key is pinned in Info.plist. Never regenerate or replace it casually: existing installations trust that key. Archive authentication is separate from Developer ID signing and notarization.

The workflow uses read-only build permissions and grants release-write access only to the publishing job. It publishes an ad-hoc signed build with an explicit disclosure. It never has signing credentials in pull-request jobs. If automatic publication fails, inspect the run before retrying; never overwrite an existing published release.

## Local packaging

```sh
Scripts/package.sh
```

Artifacts are written under `.build/release`. `Clipboard.zip` remains available as a local compatibility filename; publish the versioned files. `BUILD-INFO.json` records the exact Git commit and whether the checkout was clean.

The script supports an installed Developer ID identity via `CLIPBOARD_SIGN_IDENTITY` and an existing notarytool Keychain profile via `CLIPBOARD_NOTARY_PROFILE`. It signs with Hardened Runtime, notarizes and staples when those are configured. Keep certificates, passwords, private keys, and Keychain data out of Git. Signed releases require an appropriately provisioned trusted build host and release notes updated to match their signing status.

See [Verification](../VERIFICATION.md) for uncompleted runtime and performance checks. Never describe pending measurements as certified results.

## Update signing

Sparkle is pinned to 2.10.0, with the resolved package revision committed. `Scripts/sparkle-tools.sh` verifies the official tool archive’s pinned SHA-256 before extraction. `Scripts/appcast.sh` generates and signs the GitHub Releases feed after packaging, then runs `Scripts/verify-updates.py` to check version/URLs and verify that tampered archives and feeds are rejected. Locally, it uses the `local.clipboard.Clipboard` Keychain account; CI reads the repository secret via standard input. Never print or commit the private key.

Each release must increment **CFBundleVersion**, retain SUPublicEDKey, and publish appcast.xml with the matching ZIP. The app fetches `/releases/latest/download/appcast.xml`. Published releases and their signed assets must remain immutable. Store a secure recovery copy of the signing key outside Git; losing it prevents signing updates trusted by existing installations.

Automatic checks are daily by default, profiling is disabled, and installation requires a user action. Fixtures never initialize the updater. The release workflow fails closed when the signing secret is absent. The initial updater release must be installed manually by v1.0.0 users.
