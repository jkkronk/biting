#!/usr/bin/env bash
# Bootstrap the Shoo Xcode project from project.yml using XcodeGen.
#
# Usage: bash scripts/bootstrap.sh
set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen not found."
  if command -v brew >/dev/null 2>&1; then
    echo "Installing via Homebrew…"
    brew install xcodegen
  else
    echo "Homebrew is not installed. Install XcodeGen manually:"
    echo "  https://github.com/yonaskolb/XcodeGen#installing"
    exit 1
  fi
fi

# Optional dev tooling for `make lint` / nicer CI-parity output. Non-fatal if
# Homebrew is missing or installs fail.
if command -v brew >/dev/null 2>&1; then
  for tool in swiftlint xcbeautify; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      echo "Installing $tool (optional)…"
      brew install "$tool" || echo "  (skipped $tool; install manually if you want it)"
    fi
  done
fi

echo "Generating Shoo.xcodeproj from project.yml…"
xcodegen generate

echo "Done. Open with: open Shoo.xcodeproj"
