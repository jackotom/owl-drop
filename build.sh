#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build/module-cache 'build/Owl Drop.app/Contents/MacOS' 'build/Owl Drop.app/Contents/Resources' build/AppIcon.iconset
swiftc -swift-version 5 -parse-as-library -target arm64-apple-macos13.0 -module-cache-path build/module-cache Sources/OwlDropApp.swift Sources/LANReceiver.swift -o 'build/Owl Drop.app/Contents/MacOS/OwlDrop'
swift -module-cache-path build/module-cache Tools/Icon.swift build/icon.png
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" build/icon.png --out "build/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
    doubled=$((size * 2))
    sips -z "$doubled" "$doubled" build/icon.png --out "build/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns build/AppIcon.iconset -o 'build/Owl Drop.app/Contents/Resources/AppIcon.icns'
cp Info.plist 'build/Owl Drop.app/Contents/Info.plist'
codesign --force --sign - 'build/Owl Drop.app'
codesign --verify --strict 'build/Owl Drop.app'
printf 'Built and ad-hoc signed: build/Owl Drop.app\n'
