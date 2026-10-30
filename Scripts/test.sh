#!/bin/bash
# Compiles the core sources with the self-test and runs it. No Xcode or XCTest needed.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

SRC=Sources/Clipwell
swiftc -O -o "$OUT/selftest" \
    "$SRC/Classifier.swift" "$SRC/Store.swift" "$SRC/Support.swift" \
    Tests/SelfTest/main.swift
"$OUT/selftest"
