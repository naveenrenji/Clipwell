#!/bin/bash
# Synthetic benchmark on a throwaway database. Usage: ./Scripts/bench.sh [item-count]
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

SRC=Sources/Clipwell
swiftc -O -o "$OUT/bench" \
    "$SRC/Classifier.swift" "$SRC/Store.swift" "$SRC/Support.swift" \
    Tests/Bench/main.swift
"$OUT/bench" "${1:-10000}"
