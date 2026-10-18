#!/bin/bash
# Builds "Peeky Folders.app" (host app + embedded Quick Look extension).
# No Xcode project needed: swiftc for the code, actool for the icon
# (Resources/AppIcon.icon, editable in Icon Composer). Ad-hoc signed.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Peeky Folders.app"
APPEX="$APP/Contents/PlugIns/PeekyFoldersPreview.appex"
SDK="$(xcrun --show-sdk-path)"
ARCH="$(uname -m)"
COMMON=(-sdk "$SDK" -target "$ARCH-apple-macos13.0" -swift-version 5 -O
        -import-objc-header Sources/Shared/libarchive_shim.h -larchive)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APPEX/Contents/MacOS"

echo "• Compiling icon"
ICON_OUT="build/icon"
rm -rf "$ICON_OUT"; mkdir -p "$ICON_OUT"
xcrun actool Resources/AppIcon.icon --compile "$ICON_OUT" --platform macosx \
  --minimum-deployment-target 13.0 --app-icon AppIcon \
  --output-partial-info-plist "$ICON_OUT/partial.plist" >/dev/null
cp "$ICON_OUT/Assets.car" "$ICON_OUT/AppIcon.icns" "$APP/Contents/Resources/"

echo "• Compiling Quick Look extension"
swiftc "${COMMON[@]}" -module-name PeekyFoldersPreview -application-extension \
  -Xlinker -e -Xlinker _NSExtensionMain \
  -framework QuickLookUI -framework QuickLookThumbnailing \
  Sources/Shared/*.swift Sources/Extension/*.swift \
  -o "$APPEX/Contents/MacOS/PeekyFoldersPreview"

echo "• Compiling app"
swiftc "${COMMON[@]}" -module-name PeekyFolders \
  -framework QuickLookThumbnailing \
  Sources/Shared/*.swift Sources/App/main.swift \
  -o "$APP/Contents/MacOS/PeekyFolders"

cp Resources/Extension-Info.plist "$APPEX/Contents/Info.plist"
cp Resources/App-Info.plist "$APP/Contents/Info.plist"

echo "• Signing (ad-hoc)"
codesign --force --sign - --entitlements Resources/Extension.entitlements "$APPEX"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
echo "✓ Built $APP"
