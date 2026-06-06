#!/usr/bin/env bash
# scripts/coverage.sh <result-bundle.xcresult>
# Prints overall + per-target coverage and optionally gates on a floor.
# See plans/06-testing-ci.md.
set -euo pipefail

BUNDLE="${1:-TestResults.xcresult}"
# Floor applied to the app target's line coverage. Start at 0 (non-blocking),
# ratchet up as the suite matures (target: pure-logic layer >= 85%).
FLOOR="${COVERAGE_FLOOR:-0}"

if [[ ! -d "$BUNDLE" ]]; then
  echo "::error::Result bundle not found: $BUNDLE (run 'make test' first)"
  exit 1
fi

echo "== Coverage report ($BUNDLE) =="
xcrun xccov view --report --only-targets "$BUNDLE" || true

# Extract Shoo.app line coverage as a percentage for the summary line.
PCT=$(xcrun xccov view --report --json "$BUNDLE" | python3 -c '
import json, sys
d = json.load(sys.stdin)
t = [x for x in d.get("targets", []) if x["name"].startswith("Shoo.app")]
print(round((t[0]["lineCoverage"] if t else 0.0) * 100, 1))
')
echo "Shoo.app line coverage: ${PCT}%"

# Surface to the GitHub job summary when running in Actions.
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  echo "### Coverage: Shoo.app ${PCT}%" >> "$GITHUB_STEP_SUMMARY"
fi

# Gate (only if a floor is configured).
if awk "BEGIN { exit !($PCT < $FLOOR) }"; then
  echo "::error::Coverage ${PCT}% is below floor ${FLOOR}%"
  exit 1
fi
