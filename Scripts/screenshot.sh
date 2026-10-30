#!/bin/bash
# Renders the history window with made-up demo data (never your real history).
#   ./Scripts/screenshot.sh docs/screenshot.png ["search text"]
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

SRC=Sources/Clipwell
swiftc -O -o "$OUT/shot" \
    "$SRC/Classifier.swift" "$SRC/Store.swift" "$SRC/Support.swift" "$SRC/Settings.swift" \
    "$SRC/Caret.swift" "$SRC/Paster.swift" "$SRC/HistoryPanel.swift" "$SRC/HistoryViews.swift" \
    Tests/Screenshot/main.swift
"$OUT/shot" "$@"
