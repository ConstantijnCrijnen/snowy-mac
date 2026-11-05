# Contributing to Snowy

Small, focused fixes are welcome. For a larger behavior change, open an issue first so we can agree on how the snow should feel.

## Find your way around

- `Sources/SnowCore/` — geometry, snow profiles, granular material, collisions, and power policy.
- `Sources/Snowy/` — the menu-bar app, window tracking, and Metal rendering.
- `Tests/SnowCoreTests/` — deterministic geometry and physics regressions.
- `website/` — the browser desktop and its independent JavaScript snow engine.
- `docs/architecture.md` and `DESIGN.md` — implementation limits and interaction decisions.

## Check a change

For the Mac app, use Xcode 16 or later with the Metal toolchain installed:

```sh
swift test
./scripts/build-app.sh
```

For the website, use Node.js 22 or later:

```sh
npm --prefix website test
npm --prefix website run build
```

The headless tests should remain independent of the live desktop. Add a regression for a meaningful physics failure, especially when moving supports, corners, material conservation, or storage exhaustion are involved. Don’t replace a physics failure with a looser assertion unless the intended behavior has changed.

Optional browser checks use an isolated temporary Chrome/Chromium profile. Start the website's dev server, then run `npm --prefix website run test:browser`. Set `CHROME_BIN` if the executable is not in a standard location. This checks actual window gestures, weather settings, Dock alignment after mobile scrolling, storage reloads, Reduced Motion, and terminal input handling. It never accesses your existing browser profile or launches the Mac app.

Keep allocations and per-frame work bounded. Reuse buffers, preserve unplaced material, and avoid new render clocks for a local effect. Respect Reduced Motion, background-tab suspension, pause, and sleep.

Mention manual visual checks separately from automated tests. A successful build doesn’t verify gesture feel or exact alignment with a particular macOS window shape.

## Make a release

For a local packaging check, run:

```sh
./scripts/package-release.sh
```

This writes an architecture-labelled DMG, ZIP, and their SHA-256 checksums into `build/releases/`. The DMG contains Snowy.app and an Applications shortcut over a Retina winter background. Packaging uses Python 3 with venv and pip to install two hash-pinned Finder metadata helpers in a temporary environment. It draws the artwork offscreen, writes Finder metadata directly to an owned staging image, and verifies the signed app, ZIP, disk-image checksum, background alias, and icon positions. It never opens Finder or launches Snowy.

The automated release workflow requires a [Developer ID Application certificate](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/) with its private key and credentials for Apple's notary service. For a local distribution build, set `SNOWY_CODESIGN_IDENTITY` to the Developer ID identity name or fingerprint and `SNOWY_NOTARY_PROFILE` to the name of a profile created with `xcrun notarytool store-credentials`, then run `./scripts/package-release.sh --notarize`.

For the **Release** workflow, add these GitHub Actions secrets:

- `SNOWY_DEVELOPER_ID_P12_BASE64` and `SNOWY_DEVELOPER_ID_P12_PASSWORD` for the password-protected certificate and private key export.
- `SNOWY_CODESIGN_IDENTITY` for the full Developer ID Application name or fingerprint.
- `SNOWY_NOTARY_KEY_BASE64`, `SNOWY_NOTARY_KEY_ID`, and `SNOWY_NOTARY_ISSUER_ID` for an [App Store Connect team API key](https://developer.apple.com/documentation/appstoreconnectapi/creating-api-keys-for-app-store-connect-api). The first value is the base64-encoded `.p8` file.
- `SNOWY_SPARKLE_PRIVATE_KEY` for the existing update feed and ZIP signatures.

Increase the bundle build number and version in `App/Info.plist`, push a matching `v<version>` tag, and run **Release** with that tag. The workflow signs Snowy and the bundled updater with Hardened Runtime, notarizes and staples the app and DMG, and verifies the distributed copies. It computes checksums and signs the appcast after notarization, then publishes the release. If Apple rejects a submission, inspect it with `xcrun notarytool log <submission-id> --keychain-profile <profile>` using credentials for the same team.

Keep a protected backup of the signing key and publish a new version when release assets need to change. A future purchase or license check belongs in a separate entitlement flow. The one-click updater handles compatible updates on the existing channel.

## See download counts

Run `./scripts/download-stats.sh` from the repository with GitHub CLI signed in. The report includes the website's DMG downloads and separates installer and ZIP counts by release. GitHub counts asset downloads, including repeat downloads and ZIPs fetched by the in-app updater.

## Keep it original

Only submit code and assets you have permission to share under the repository’s license. Window Sweaters is a README-style reference, not a source-code dependency. Please keep seasonal jokes light and optional; no surprise audio.

## Commit history

Use Angular-style Conventional Commit subjects: `type(scope): summary`. Describe one logical change, use an imperative summary, and use actual dates for new work.
