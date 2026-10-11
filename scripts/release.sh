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
.build/debug/que-tests

# 1. Update version in UpdateManager.swift & Info.plist
sed -i '' "s/public static let currentVersion = \".*\"/public static let currentVersion = \"$VERSION\"/" Sources/QueCore/UpdateManager.swift
plutil -replace CFBundleShortVersionString -string "$VERSION" Que.app/Contents/Info.plist 2>/dev/null || true
plutil -replace CFBundleVersion -string "$VERSION" Que.app/Contents/Info.plist 2>/dev/null || true

# 2. Build Universal Release Binary
echo "Building universal release binary..."
swift build -c release --triple arm64-apple-macosx
swift build -c release --triple x86_64-apple-macosx

# 3. Create app bundle & codesign
mkdir -p Que.app/Contents/MacOS
lipo -create -output Que.app/Contents/MacOS/Que \
  .build/arm64-apple-macosx/release/Que \
  .build/x86_64-apple-macosx/release/Que
codesign --force --deep -s - Que.app

# 4. Package zip for in-app auto-updater.
# It holds the app twice: Que.app for Que's updater, and the same app as CursorDeck.app because updaters in
# CursorDeck 1.x only look for that name (they then install it and Que renames itself to Que.app on launch).
# Keep the CursorDeck.app copy until CursorDeck 1.x users have moved over (see CLAUDE.md).
echo "Creating Que.zip..."
rm -rf .zip_staging Que.zip && mkdir -p .zip_staging
ditto Que.app .zip_staging/Que.app
ditto Que.app .zip_staging/CursorDeck.app
ditto -c -k --sequesterRsrc .zip_staging Que.zip
rm -rf .zip_staging

# 5. Build DMG (Standard Drag-and-Drop Disk Image — No Admin Password Required)
echo "Building DMG..."
rm -rf .dmg_staging && mkdir -p .dmg_staging
cp -R Que.app .dmg_staging/
ln -s /Applications .dmg_staging/Applications
rm -f "Que-v$VERSION.dmg"
hdiutil create -volname "Que" -srcfolder .dmg_staging -ov -format UDZO "Que-v$VERSION.dmg"
rm -rf .dmg_staging

# 6. Commit version bump
git add .
git commit -m "Release v$VERSION: $NOTES" || true
# Stop here if the push fails: publishing a release on top of an un-pushed commit would tag old code.
git push origin main

# 7. Create/Upload GitHub Release
echo "Publishing GitHub Release v$VERSION..."
gh release create "v$VERSION" \
  "Que-v$VERSION.dmg" \
  Que.zip \
  --title "Que v$VERSION" \
  --notes "$NOTES" \
  --latest

echo "========================================"
echo "✓ Release v$VERSION published to GitHub!"
echo "All users will now receive the update!"
echo "========================================"
