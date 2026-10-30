# Roadmap

Honest list of what is missing and where help is most welcome. Ideas are tracked as issues; tick-boxes here are direction, not promises.

## Next
- [ ] **Notarized releases.** The release workflow already builds universal zips with checksums; signing with an Apple Developer ID and notarizing needs the secrets described in [docs/RELEASING.md](docs/RELEASING.md). Then publish the Homebrew tap (template in `packaging/homebrew`).
- [ ] **Encryption at rest** for the database and images, with the key in the Keychain.
- [x] README screenshots (rendered from made-up data by `Scripts/screenshot.sh`).
- [ ] A short demo GIF of searching, pasting and multi-item paste (use made-up items, never real history).
- [x] Universal binary (Apple silicon and Intel); macOS 14 is the minimum. Intel has been built but not run on real hardware yet; reports welcome.

## Soon
- [ ] **Snippets**: saved, named pieces of text that are never pruned.
- [ ] Rich text and RTF/HTML formats preserved on paste.
- [ ] A settings window (today everything is in the menu bar).
- [ ] Configurable global shortcut.
- [ ] Per-app rules (for example "always paste as plain text in Terminal").
- [ ] Export and import of history.

## Ideas
- [ ] Better classification: more languages for code detection, phone numbers, addresses, dates.
- [ ] Localization.
- [ ] Shortcuts/AppleScript actions.

## Deliberately not planned
- Cloud sync or any network feature. Clipwell stays local-only.
- Analytics or telemetry of any kind.
