#!/bin/bash
# One-time GitHub repository setup for the maintainer: topics, discussions, security features,
# labels, branch protection and a set of starter issues for new contributors.
#
# Needs the GitHub CLI logged in as the repository owner:  gh auth login
# Safe to re-run (it updates settings and skips starter issues once any issue exists).
#
#   ./Scripts/setup-github.sh [owner/repo]
set -euo pipefail

REPO="${1:-naveenrenji/Clipwell}"

if ! gh auth status >/dev/null 2>&1; then
    echo "Not logged in. Run: gh auth login" >&2
    exit 1
fi

echo "== Repository settings"
gh repo edit "$REPO" \
    --description "Fast, private, open-source macOS menu-bar clipboard manager with search inside screenshots (on-device OCR), multi-item paste and secret masking." \
    --add-topic macos,clipboard-manager,clipboard-history,clipboard,swift,swiftui,menu-bar,ocr,privacy,sqlite,productivity,open-source \
    --enable-issues \
    --enable-discussions \
    --enable-wiki=false \
    --enable-squash-merge \
    --enable-merge-commit=false \
    --enable-rebase-merge=false \
    --delete-branch-on-merge

echo "== Security features"
gh api -X PUT "repos/$REPO/private-vulnerability-reporting" >/dev/null
gh api -X PUT "repos/$REPO/vulnerability-alerts" >/dev/null
gh api -X PATCH "repos/$REPO" \
    -f 'security_and_analysis[secret_scanning][status]=enabled' \
    -f 'security_and_analysis[secret_scanning_push_protection][status]=enabled' >/dev/null

echo "== Labels"
label() { gh label create "$1" --repo "$REPO" --color "$2" --description "$3" --force >/dev/null; }
label "bug" "d73a4a" "Something is not working"
label "enhancement" "a2eeef" "New feature or improvement"
label "classification" "5319e7" "How copies are detected and tagged"
label "performance" "fbca04" "Speed or memory"
label "security" "b60205" "Privacy and security"
label "documentation" "0075ca" "Docs and README"
label "good first issue" "7057ff" "Good for newcomers"
label "help wanted" "008672" "Extra attention is welcome"
label "needs-triage" "ededed" "Not reviewed yet"
label "question" "d876e3" "Further information is requested"
label "skip-changelog" "ffffff" "Leave out of release notes"

echo "== Branch protection for main"
# The maintainer (admin) can still push; contributors go through reviewed pull requests with passing CI.
gh api -X PUT "repos/$REPO/branches/main/protection" --input - >/dev/null <<'JSON'
{
  "required_status_checks": { "strict": true, "contexts": ["macos-15", "macos-latest"] },
  "enforce_admins": false,
  "required_pull_request_reviews": {
    "required_approving_review_count": 1,
    "require_code_owner_reviews": true,
    "dismiss_stale_reviews": true
  },
  "restrictions": null,
  "required_linear_history": true,
  "allow_force_pushes": false,
  "allow_deletions": false,
  "required_conversation_resolution": true
}
JSON

echo "== Starter issues"
if [ -z "$(gh issue list --repo "$REPO" --state all --limit 1 --json number --jq '.[].number')" ]; then
    issue() { gh issue create --repo "$REPO" --title "$1" --label "$2" --body "$3" >/dev/null; echo "  created: $1"; }

    issue "Classify phone numbers, dates and street addresses" "enhancement,classification,good first issue" \
"Clipwell labels copies as text, URL, email, colour, code, JSON, number, path, image or files. Add detection for phone numbers, dates and street addresses.

Where: \`Sources/Clipwell/Classifier.swift\` (pure functions) and a test in \`Tests/SelfTest/main.swift\`.
Done when: new kinds show in the kind filter with an icon and label, and tests cover typical and tricky inputs."

    issue "Improve code detection for more languages" "classification,good first issue" \
"Code detection scores common tokens (\`func\`, \`def\`, \`{ }\`, \`=>\`). Add markers for more languages (Go, Rust, Python, Ruby, shell, YAML) and add tests that include prose which must stay text.

Where: \`looksLikeCode\` in \`Sources/Clipwell/Classifier.swift\`."

    issue "README: add screenshots and a short demo GIF" "documentation,good first issue" \
"The README has no screenshots. Add images of the history window (use made-up clipboard items, never real history) and a short GIF of searching, pasting and ⌘M multi-paste."

    issue "Configurable global shortcut" "enhancement,good first issue" \
"The history opens with ⌃⌥V, hard-coded in \`AppDelegate\`. Let users choose another shortcut (stored in \`Settings\`) and handle conflicts."

    issue "Add a settings window" "enhancement,help wanted" \
"Everything is configured from the menu bar today. Add a proper settings window (shortcut, history size, secret expiry, image limit, excluded apps, launch at login)."

    issue "Per-app rules (for example always paste as plain text in Terminal)" "enhancement" \
"Let users set per-app behaviour: plain text only, never record, never auto-paste. The exclusion list and the no-auto-paste list in \`Settings\` are a starting point."

    issue "Preserve rich text (RTF/HTML) when pasting" "enhancement,help wanted" \
"Only plain text, images and files are stored. Store RTF/HTML alongside the text and restore it on paste, with ⇧ still giving plain text."

    issue "Encrypt the database and images at rest" "security,help wanted" \
"Data is owner-only on disk but not encrypted beyond FileVault. Encrypt the database and image files with a key held in the Keychain. Discuss the design (SQLCipher or file-level encryption, and what it does to full-text search) in this issue before starting."

    issue "Notarized releases and a Homebrew tap" "enhancement,help wanted" \
"Set up Developer ID signing and notarization (see docs/RELEASING.md) and publish a Homebrew cask so people can install without a toolchain."

    issue "Localization" "enhancement,help wanted" \
"Move user-visible strings into localizable resources and add the first translations."
else
    echo "  issues already exist; skipping"
fi

echo "Done. Next: git tag v0.1.0 && git push origin main --tags  (publishes the first release)"
