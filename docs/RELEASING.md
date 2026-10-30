# Releasing Clipwell

Releases are built by [`.github/workflows/release.yml`](../.github/workflows/release.yml) when a version tag is pushed.

## Cut a release

1. Move the entries under `## [Unreleased]` in `CHANGELOG.md` to a new `## [x.y.z] - date` heading.
2. Commit, then tag and push:

   ```bash
   git tag v0.2.0
   git push origin main --tags
   ```

3. The workflow runs the self-test, builds a universal (Apple silicon + Intel) app, zips it, writes a SHA-256 checksum and publishes a GitHub Release with generated notes. Tags containing a dash (`v0.2.0-beta.1`) are marked as pre-releases.

## Signed and notarized builds (recommended)

Without these secrets the app is ad-hoc signed and macOS asks users to approve it once (System Settings → Privacy & Security → Open Anyway). With an Apple Developer ID ($99/year) it opens without warnings.

Add these repository secrets (Settings → Secrets and variables → Actions):

| Secret | Value |
|---|---|
| `MACOS_CERTIFICATE` | Base64 of your "Developer ID Application" certificate exported as `.p12` (`base64 -i cert.p12 \| pbcopy`) |
| `MACOS_CERTIFICATE_PASSWORD` | The password you set when exporting the `.p12` |
| `APPLE_ID` | Your Apple ID email |
| `APPLE_TEAM_ID` | Your 10-character team id |
| `APPLE_APP_PASSWORD` | An app-specific password from appleid.apple.com |

The workflow then signs with the Developer ID, submits to Apple's notary service, staples the ticket and re-zips. This path has not yet been exercised on GitHub's runners, so the first signed release deserves a careful check: download the zip on a clean Mac and confirm it opens without a warning (`spctl -a -vv Clipwell.app` should say "accepted, source=Notarized Developer ID").

## Homebrew

Create a tap repository named `homebrew-clipwell` and copy [`packaging/homebrew/clipwell.rb`](../packaging/homebrew/clipwell.rb) to `Casks/clipwell.rb`. After each release update `version` and `sha256`. Users then install with:

```bash
brew install --cask naveenrenji/clipwell/clipwell
```

## Local test of the packaging

```bash
INSTALL=0 UNIVERSAL=1 OUT_DIR=dist ./Scripts/bundle.sh
lipo -archs dist/Clipwell.app/Contents/MacOS/Clipwell   # x86_64 arm64
```
