#!/bin/bash
set -e

VERSION="${1}"
NOTES="${2:-CursorDeck update}"

if [ -z "$VERSION" ]; then
  echo "Usage: ./scripts/release.sh <version> [release_notes]"
  echo "Example: ./scripts/release.sh 1.1 \"Added new features and bug fixes\""
  exit 1
fi

echo "========================================"
echo "  Deploying CursorDeck v$VERSION"
echo "========================================"

# 1. Update version in UpdateManager.swift
sed -i '' "s/public static let currentVersion = \".*\"/public static let currentVersion = \"$VERSION\"/" Sources/CursorDeckCore/UpdateManager.swift

# 2. Build Universal Release Binary
echo "Building universal release binary..."
swift build -c release --triple arm64-apple-macosx
swift build -c release --triple x86_64-apple-macosx

# 3. Create app bundle & codesign
mkdir -p CursorDeck.app/Contents/MacOS
lipo -create -output CursorDeck.app/Contents/MacOS/CursorDeckApp \
  .build/arm64-apple-macosx/release/CursorDeckApp \
  .build/x86_64-apple-macosx/release/CursorDeckApp
codesign --force --deep -s - CursorDeck.app

# 4. Package zip for in-app auto-updater
echo "Creating CursorDeck.zip..."
rm -f CursorDeck.zip
ditto -c -k --sequesterRsrc --keepParent CursorDeck.app CursorDeck.zip

# 5. Build DMG and PKG
echo "Building DMG & PKG..."
rm -rf .dmg_staging && mkdir -p .dmg_staging
cp -R CursorDeck.app .dmg_staging/
ln -s /Applications .dmg_staging/Applications
rm -f "CursorDeck-v$VERSION.dmg" "CursorDeck-v1.0.dmg"
hdiutil create -volname "CursorDeck" -srcfolder .dmg_staging -ov -format UDZO "CursorDeck-v$VERSION.dmg"
cp "CursorDeck-v$VERSION.dmg" "CursorDeck-v1.0.dmg"
rm -rf .dmg_staging

mkdir -p .pkg-scripts
cat << 'EOF' > .pkg-scripts/postinstall
#!/bin/sh
xattr -cr /Applications/CursorDeck.app 2>/dev/null || true
open /Applications/CursorDeck.app 2>/dev/null || true
exit 0
EOF
chmod +x .pkg-scripts/postinstall
rm -f CursorDeck-Installer.pkg
pkgbuild --root CursorDeck.app --identifier com.cursordeck.app --version "$VERSION" --install-location /Applications/CursorDeck.app --scripts .pkg-scripts CursorDeck-Installer.pkg
rm -rf .pkg-scripts

# 6. Commit version bump
git add .
git commit -m "Release v$VERSION: $NOTES" || true
git push origin main || true

# 7. Create/Upload GitHub Release
echo "Publishing GitHub Release v$VERSION..."
gh release create "v$VERSION" \
  "CursorDeck-v$VERSION.dmg" \
  CursorDeck-Installer.pkg \
  --title "CursorDeck v$VERSION" \
  --notes "$NOTES" \
  --latest

echo "========================================"
echo "✓ Release v$VERSION published to GitHub!"
echo "All users will now receive the update!"
echo "========================================"
