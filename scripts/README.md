# Release scripts

Everything needed to go from a clean checkout to a notarized DMG with Sparkle auto-updates.

## Prerequisites (one-time setup)

```bash
brew install librsvg create-dmg xcpretty
```

- librsvg (`rsvg-convert`) renders the app icon from `design/icon.svg`.
- create-dmg builds the installer volume.
- xcpretty makes `xcodebuild` output readable.

## 1. Generate the app icon

```bash
./scripts/generate_icons.sh
```

This exports all 10 PNG sizes into `Pointless/Assets.xcassets/AppIcon.appiconset/` and writes the matching `Contents.json`. Re-run whenever `design/icon.svg` changes.

For macOS 26's tinted/clear/dark icon variants, open Xcode, right-click `AppIcon` > **Add Icon Variants** and drop in your variant PNGs. Apple's [Icon Composer](https://developer.apple.com/design/icon-composer/) can generate them from the same source.

## 2. Developer ID signing

The Xcode project is already configured with:

- `ENABLE_HARDENED_RUNTIME = YES`
- `ENABLE_APP_SANDBOX = NO` (required for `CGEvent` cursor / click posting)
- `CODE_SIGN_ENTITLEMENTS = Pointless/Pointless.entitlements`
- `OTHER_CODE_SIGN_FLAGS = --timestamp --options=runtime`

Make sure you have a **Developer ID Application** certificate in the keychain. If you need to switch to manual signing, edit the build settings accordingly.

## 3. App Store Connect API key

Create an API key with `App Manager` role at [App Store Connect → Users and Access → Keys](https://appstoreconnect.apple.com/access/users). Download the `.p8` file and keep it somewhere safe (e.g. `~/.private_keys/AuthKey_XXXX.p8`).

Export these to your shell before running `release.sh`:

```bash
export AC_API_KEY_ID=XXXXXXXX
export AC_API_ISSUER=XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX
export AC_API_KEY_PATH=~/.private_keys/AuthKey_XXXXXXXX.p8
```

## 4. Sparkle 2

Add Sparkle to the Xcode project:

1. In Xcode: `File > Add Package Dependencies…`
2. URL: `https://github.com/sparkle-project/Sparkle`
3. Version: `2.6.0` or newer, `Up to Next Major Version`
4. Add the `Sparkle` library to the Pointless target.

Generate an EdDSA signing key pair once per product:

```bash
$SPARKLE_TOOLS_PATH/generate_keys
```

This writes an `ed_private_key` and prints the public key. Copy the public key into `Info.plist` under `SUPublicEDKey`. Keep the private key off GitHub.

Then in your shell:

```bash
export SPARKLE_TOOLS_PATH=/path/to/Sparkle/bin
export SPARKLE_PRIVATE_KEY=/path/to/ed_private_key
```

## 5. Cut a release

```bash
./scripts/release.sh 1.0.1 45
```

Outputs:

- `build/dmg/Pointless-1.0.1.dmg` — notarized and stapled
- `dist/releases/Pointless-1.0.1.dmg`
- `dist/releases/appcast.xml` (if Sparkle is configured)

Upload the DMG + appcast.xml to your CDN (or GitHub Releases / S3 / Cloudflare R2) and make sure the `SUFeedURL` in `Info.plist` points to the published appcast.

## 6. Smoke test

After uploading:

```bash
xcrun stapler validate build/dmg/Pointless-1.0.1.dmg
spctl --assess --type execute --verbose build/export/Pointless.app
```

Both should say "accepted".
