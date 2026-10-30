# Contributing to Clipwell

Thanks for helping! Clipwell is a small, readable Swift codebase (about 2,200 lines, no dependencies), so most changes are easy to review.

## Ground rules

1. **Stay local-only.** No network code, telemetry or cloud services. This is the product's central promise; pull requests that add them will be declined.
2. **Protect user data.** Never log clipboard content. New files must be owner-only. Anything that stores, shows or deletes history needs a test.
3. **Keep the UI thread free.** Classification, hashing, encoding, OCR and database work run off the main thread.
4. **Match the surrounding code:** naming, comment density and style. Comments explain *why*, not *what*.

## Set up

You need macOS 14+ and the Swift toolchain (`xcode-select --install` is enough; full Xcode is not required).

```bash
git clone https://github.com/naveenrenji/Clipwell.git
cd Clipwell
swift build                # debug build
./Scripts/test.sh          # self-tests (classifier, store, search, retention, backups, migration, image codec)
./Scripts/bench.sh 10000   # optional: timings on a throwaway database
./Scripts/bundle.sh        # build and install ~/Applications/Clipwell.app
```

Use your own app identifier when testing a fork so macOS permissions do not clash: `BUNDLE_ID=com.example.Clipwell ./Scripts/bundle.sh`.

## Making a change

- Open an issue first for anything bigger than a small fix, so we agree on the approach.
- Add or update a case in `Tests/SelfTest/main.swift` for behaviour changes. The test runner needs no Xcode or XCTest.
- Run `./Scripts/test.sh` and make sure the build has no warnings.
- Keep pull requests focused: one change, with a short description of what and why.
- Never test against your real history. The benchmark and tests use throwaway databases.

## Where things live

See "How it works" in the [README](README.md). Classification rules are pure functions in `Classifier.swift`, which makes them the easiest place to start; a misclassified copy is a great first issue. Look for issues labelled **good first issue** and the [roadmap](ROADMAP.md).

## Reporting problems

Use the issue templates. For anything security-related, follow [SECURITY.md](SECURITY.md) instead of opening a public issue.
