#!/usr/bin/env bash
# scripts/package.sh
# Builds a Release Shoo.app, ad-hoc signs it (free, no Apple Developer account),
# and zips it for a GitHub release. The result is unsigned/un-notarized, so users
# clear the quarantine flag on first launch — see the README "Download" section.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

PROJECT="Shoo.xcodeproj"
SCHEME="Shoo"
APP="build/Shoo.app"
ENTITLEMENTS="Shoo/Shoo.entitlements"

# Marketing version is the single source of truth in project.yml.
VERSION="$(sed -n 's/.*MARKETING_VERSION:[[:space:]]*"\{0,1\}\([0-9.]*\)"\{0,1\}.*/\1/p' project.yml | head -1)"
VERSION="${VERSION:-0.0.0}"
ZIP="build/Shoo-${VERSION}.zip"

echo "== Generating project =="
xcodegen generate

echo "== Building Release (unsigned) into build/ =="
rm -rf "$APP" "$ZIP"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
  -destination 'platform=macOS' \
  CONFIGURATION_BUILD_DIR="$REPO_ROOT/build" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  build

if [[ ! -d "$APP" ]]; then
  echo "::error::Expected app not found at $APP after build"
  exit 1
fi

echo "== Ad-hoc signing (hardened runtime + entitlements) =="
codesign --force --deep --options runtime \
  --entitlements "$ENTITLEMENTS" \
  --sign - "$APP"
codesign -dv "$APP" 2>&1 | sed 's/^/  /' || true

echo "== Zipping =="
ditto -c -k --keepParent "$APP" "$ZIP"

echo
echo "Done: $ZIP"
echo "Publish with:  gh release create v${VERSION} \"$ZIP\" --title \"Shoo ${VERSION}\" --notes \"...\""
