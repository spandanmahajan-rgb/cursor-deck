#!/bin/bash
# Que app bundle skeleton. Copyright (c) 2026 Spandan Mahajan. PolyForm Noncommercial 1.0.0 (see LICENSE).
#
#   ./scripts/make-app.sh    (re)creates ./Que.app/Contents from packaging/Info.plist and AppIcon.icns, stamped
#                            with the version in Sources/QueCore/UpdateManager.swift. The binary is added by
#                            release.sh / deploy-local.sh (lipo), then signed.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(sed -n 's/.*public static let currentVersion = "\(.*\)".*/\1/p' Sources/QueCore/UpdateManager.swift)"
[ -n "$VERSION" ] || { echo "make-app: couldn't read currentVersion from UpdateManager.swift" >&2; exit 1; }

mkdir -p Que.app/Contents/MacOS Que.app/Contents/Resources
cp packaging/Info.plist Que.app/Contents/Info.plist
cp AppIcon.icns Que.app/Contents/Resources/AppIcon.icns
plutil -replace CFBundleShortVersionString -string "$VERSION" Que.app/Contents/Info.plist
plutil -replace CFBundleVersion -string "$VERSION" Que.app/Contents/Info.plist
echo "make-app: Que.app skeleton for $VERSION"
