# Releasing

A release is a notarized `Pal-<version>.dmg` plus an `appcast.xml` on a GitHub release. Installed copies update themselves through Sparkle from `releases/latest/download/appcast.xml`.

## From your Mac

```bash
scripts/release.sh 0.3.0            # build, sign, DMG, notarize, appcast, publish
scripts/release.sh 0.3.0 --dry-run  # everything except notarizing and publishing
```

The build number is the commit count, so it always goes up. Each step is its own script (`build-release.sh`, `make-dmg.sh`, `notarize.sh`, `appcast.sh`) if you want to run or change one.

**One-time setup**
- **Signing:** a *Developer ID Application* certificate in your keychain, plus `DEVELOPMENT_TEAM` in `Config/Local.xcconfig` (see the README).
- **Notarization:** store credentials under the profile name `pal-notary`:
  ```bash
  xcrun notarytool store-credentials pal-notary --apple-id <apple id> --team-id <team id>
  ```
  To use an App Store Connect API key instead, set `NOTARY_KEY_PATH`, `NOTARY_KEY_ID` and `NOTARY_ISSUER`.
- **Update signing:** the Sparkle key lives in your login keychain under the account `pal`. Its public half is `PAL_SPARKLE_PUBLIC_KEY` in `project.yml`. If you lose the private key, installed copies can't verify new updates.

## From GitHub

Go to **Actions › Release › Run workflow**, enter a version, and it runs the same `scripts/release.sh`. It needs these repository secrets:

| Secret | What |
| --- | --- |
| `MACOS_CERTIFICATE` | Developer ID Application `.p12`, base64: `base64 -i cert.p12 \| gh secret set MACOS_CERTIFICATE` |
| `MACOS_CERTIFICATE_PASSWORD` | Password of that `.p12` |
| `APPLE_TEAM_ID` | Your team ID |
| `NOTARY_KEY`, `NOTARY_KEY_ID`, `NOTARY_ISSUER` | App Store Connect API key (`.p8` contents, key ID, issuer ID) |
| `SPARKLE_PRIVATE_KEY` | `generate_keys --account pal -x key.txt`, then `gh secret set SPARKLE_PRIVATE_KEY < key.txt` and delete the file |

`generate_keys` is in `build/SourcePackages/artifacts/sparkle/Sparkle/bin/` after any build.
