#!/bin/bash
# Que release script. Copyright (c) 2026 Spandan Mahajan. PolyForm Noncommercial 1.0.0 (see LICENSE).
set -e

VERSION="${1}"
NOTES="${2:-Que update}"

if [ -z "$VERSION" ]; then
  echo "Usage: ./scripts/release.sh <version> [release_notes]"
  echo "Example: ./scripts/release.sh 1.1 \"Added new features and bug fixes\""
  exit 1
fi

echo "========================================"
echo "  Deploying Que v$VERSION"
echo "========================================"

# 0. Tests must pass before anything is built or published (asserts only run in debug builds)
echo "Running tests..."
swift build
QUE_LIVE_TESTS=1 .build/debug/que-tests   # includes the live Pinterest checks

# 1. Update the version in UpdateManager.swift, then build the Que.app skeleton from packaging/ with it.
#    (No "|| true": a version that silently stays old makes every user see this update again and again.)
sed -i '' "s/public static let currentVersion = \".*\"/public static let currentVersion = \"$VERSION\"/" Sources/QueCore/UpdateManager.swift
grep -q "public static let currentVersion = \"$VERSION\"" Sources/QueCore/UpdateManager.swift \
  || { echo "Couldn't set currentVersion to $VERSION in UpdateManager.swift"; exit 1; }
./scripts/make-app.sh

# 2. Build Universal Release Binary
echo "Building universal release binary..."
swift build -c release --triple arm64-apple-macosx
swift build -c release --triple x86_64-apple-macosx

# 3. Create app bundle & codesign
lipo -create -output Que.app/Contents/MacOS/Que \
  .build/arm64-apple-macosx/release/Que \
  .build/x86_64-apple-macosx/release/Que
codesign --force --deep -s - Que.app

# 4. Package zip for in-app auto-updater (Que.app only; the CursorDeck.app copy for CursorDeck 1.x updaters was
# dropped after 2.0.0 — those few users reinstall from the DMG).
echo "Creating Que.zip..."
rm -f Que.zip
ditto -c -k --sequesterRsrc --keepParent Que.app Que.zip
ZIPPED_VERSION="$(unzip -p Que.zip Que.app/Contents/Info.plist | plutil -extract CFBundleShortVersionString raw -o - -)"
[ "$ZIPPED_VERSION" = "$VERSION" ] || { echo "Que.zip says version '$ZIPPED_VERSION', expected $VERSION. Stopping."; exit 1; }

# Seal Que.zip (see UpdateSignature.swift): apps from 2.9.0 on install only a zip whose Que.zip.sig matches.
# The private key stays in the Keychain item "Que release signing key"; it's handed to que-sign for this one call only.
rm -f Que.zip.sig
QUE_SIGNING_KEY="$(security find-generic-password -s "Que release signing key" -a que -w)" \
  .build/debug/que-sign sign Que.zip > Que.zip.sig \
  || { echo "Couldn't sign Que.zip (is the Keychain item \"Que release signing key\" there?). Stopping."; exit 1; }
.build/debug/que-sign verify Que.zip Que.zip.sig

# 5. Build DMG (Standard Drag-and-Drop Disk Image — No Admin Password Required)
echo "Building DMG..."
rm -rf .dmg_staging && mkdir -p .dmg_staging
cp -R Que.app .dmg_staging/
ln -s /Applications .dmg_staging/Applications
# Fixed name (no version) so https://github.com/spandanmahajan-rgb/que/releases/latest/download/Que.dmg always works.
rm -f Que.dmg
hdiutil create -volname "Que" -srcfolder .dmg_staging -ov -format UDZO Que.dmg
rm -rf .dmg_staging

# 6. Commit version bump
# Only the published files: private notes (CLAUDE.md, .claude/) must never ride along, even from a fresh clone.
git add Sources Package.swift README.md QUE_MASTER_DOC.md LICENSE AppIcon.icns .gitignore scripts packaging
git commit -m "Release v$VERSION" -m "$NOTES" || true   # notes are "- " bullet lines, so they go in the body
# Stop here if the push fails: publishing a release on top of an un-pushed commit would tag old code.
git push origin main

# 7. Create/Upload GitHub Release
echo "Publishing GitHub Release v$VERSION..."
gh release create "v$VERSION" \
  Que.dmg \
  Que.zip \
  Que.zip.sig \
  --title "Que v$VERSION" \
  --notes "$NOTES" \
  --latest

echo "========================================"
echo "✓ Release v$VERSION published to GitHub!"
echo "All users will now receive the update!"
echo "========================================"
