#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
mkdir -p 'Build.noindex/Record Room.app/Contents/MacOS' 'Build.noindex/Record Room.app/Contents/Resources' work.noindex/cache
swiftc Source/main.swift -o 'Build.noindex/Record Room.app/Contents/MacOS/RecordRoom' -framework Cocoa -framework SceneKit -framework ServiceManagement -O -target arm64-apple-macosx14.0 -module-cache-path "$PWD/work.noindex/scenekit-cache-v2"
# Package the shared Record Room app icon.
cp Assets/RecordRoom.icns 'Build.noindex/Record Room.app/Contents/Resources/RecordRoom.icns'
cp Assets/PrivacyInfo.xcprivacy 'Build.noindex/Record Room.app/Contents/Resources/PrivacyInfo.xcprivacy'
find 'Build.noindex/Record Room.app/Contents/Resources' -type f -name '*.png' -delete
cp Info.plist 'Build.noindex/Record Room.app/Contents/Info.plist'
codesign --force --sign - 'Build.noindex/Record Room.app'
echo 'Built Record Room.app in Build.noindex'
