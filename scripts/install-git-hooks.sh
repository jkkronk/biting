#!/usr/bin/env bash
# Install an opt-in pre-commit hook that runs SwiftLint (strict) on staged Swift files.
# Usage: bash scripts/install-git-hooks.sh   (or: make hooks)
set -euo pipefail

cd "$(dirname "$0")/.."
HOOK=".git/hooks/pre-commit"

cat > "$HOOK" <<'EOF'
#!/usr/bin/env bash
# Auto-installed by scripts/install-git-hooks.sh
set -euo pipefail
if ! command -v swiftlint >/dev/null 2>&1; then
  echo "swiftlint not installed; skipping lint (brew install swiftlint to enable)."
  exit 0
fi
staged=$(git diff --cached --name-only --diff-filter=ACM | grep -E '\.swift$' || true)
[ -z "$staged" ] && exit 0
echo "Running swiftlint on staged files…"
swiftlint lint --strict --quiet
EOF

chmod +x "$HOOK"
echo "Installed pre-commit hook → $HOOK"
