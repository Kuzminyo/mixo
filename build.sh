#!/bin/bash
# Builds Mixo.app into ./build.
#   ./build.sh          build for this Mac
#   ./build.sh install  also copy it to /Applications and launch
#   ./build.sh dist     universal (Apple Silicon + Intel) build, zipped into ./dist for sharing
set -euo pipefail
cd "$(dirname "$0")"

if [ "${1:-}" = "dist" ]; then
    swift build -c release --arch arm64 --arch x86_64
    BINARY="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/Mixo"
else
    swift build -c release
    BINARY=.build/release/Mixo
fi

if [ ! -f Resources/AppIcon.icns ]; then
    ICONSET="$(mktemp -d)/AppIcon.iconset"
    swift scripts/make-icon.swift "$ICONSET"
    iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
fi

APP=build/Mixo.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
codesign --force --sign - "$APP"
echo "Built $APP"

if [ "${1:-}" = "install" ]; then
    pkill -x Mixo || true
    rm -rf /Applications/Mixo.app
    cp -R "$APP" /Applications/
    open /Applications/Mixo.app
    echo "Installed to /Applications/Mixo.app"
fi

if [ "${1:-}" = "dist" ]; then
    VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
    rm -rf dist
    mkdir -p dist
    ditto -c -k --keepParent "$APP" "dist/Mixo-$VERSION.zip"
    zip -qr "dist/Mixo-$VERSION-source.zip" Package.swift build.sh README.md LICENSE .gitignore Sources Resources scripts
    echo "Packaged:"
    ls -lh dist
fi
