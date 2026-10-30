# Security Policy

Clipwell handles clipboard contents, which can include passwords and keys, so security reports are taken seriously.

## Reporting a vulnerability

Please **do not open a public issue**. Use GitHub's private reporting instead: on the repository page choose **Security → Report a vulnerability**. Include what you found, how to reproduce it, and the macOS version. You can expect an acknowledgement within a few days.

## What is in scope

- Clipboard data being written somewhere readable by other users or apps, or leaving the machine
- Secrets being recorded despite the concealed/transient pasteboard flags or an excluded app
- The self-deleting "sensitive" handling failing to mask or expire values
- Crashes or data loss caused by hostile clipboard content
- Unsafe file handling (for example deleting or reading files outside the data folder)

## Design notes

- No network code. The app never contacts any server.
- Data lives in `~/Library/Application Support/Clipwell/`, owner-only (directories 0700, files 0600). It is **not encrypted at rest** beyond what FileVault provides; this is on the [roadmap](ROADMAP.md).
- Distribution is source-only for now; you build and sign it yourself, so you can audit what runs.
