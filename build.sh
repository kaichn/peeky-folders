#!/bin/bash
# Builds "Peeky Folders.app" (host app + embedded Quick Look extension).
# No Xcode project needed: swiftc for the code, actool for the icon
# (Resources/AppIcon.icon, editable in Icon Composer). Ad-hoc signed.
#
#   ./build.sh            -> build/Peeky Folders.app for this Mac
#   ./build.sh install    -> build, then replace ~/Applications/Peeky Folders.app
#   ./build.sh release    -> universal (Apple silicon + Intel) build, zipped in dist/ for GitHub
set -euo pipefail
cd "$(dirname "$0")"

MODE="${1:-}"
APP="build/Peeky Folders.app"
APPEX="$APP/Contents/PlugIns/PeekyFoldersPreview.appex"
SDK="$(xcrun --show-sdk-path)"

# The app and the extension must ship with the same version.
version() { /usr/libexec/PlistBuddy -c "Print $1" "$2"; }
VERSION="$(version CFBundleShortVersionString Resources/App-Info.plist)"
if [[ "$VERSION" != "$(version CFBundleShortVersionString Resources/Extension-Info.plist)" ||
      "$(version CFBundleVersion Resources/App-Info.plist)" != "$(version CFBundleVersion Resources/Extension-Info.plist)" ]]; then
  echo "error: App-Info.plist and Extension-Info.plist have different versions" >&2; exit 1
fi

# Release builds contain both architectures so they run on every Mac with macOS 13 or later.
if [[ "$MODE" == "release" ]]; then ARCHS=(arm64 x86_64); else ARCHS=("$(uname -m)"); fi

rm -rf "$APP" build/obj
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APPEX/Contents/MacOS" build/obj

echo "• Compiling icon"
ICON_OUT="build/icon"
rm -rf "$ICON_OUT"; mkdir -p "$ICON_OUT"
xcrun actool Resources/AppIcon.icon --compile "$ICON_OUT" --platform macosx \
  --minimum-deployment-target 13.0 --app-icon AppIcon \
  --output-partial-info-plist "$ICON_OUT/partial.plist" >/dev/null
cp "$ICON_OUT/Assets.car" "$ICON_OUT/AppIcon.icns" "$APP/Contents/Resources/"

# compile <arch> <module> <output> <swiftc args...>
compile() {
  local arch="$1" module="$2" out="$3"; shift 3
  swiftc -sdk "$SDK" -target "$arch-apple-macos13.0" -swift-version 5 -O \
    -import-objc-header Sources/Shared/libarchive_shim.h -larchive \
    -module-name "$module" -module-cache-path build/obj/cache "$@" -o "$out"
}

for arch in "${ARCHS[@]}"; do
  echo "• Compiling Quick Look extension ($arch)"
  compile "$arch" PeekyFoldersPreview "build/obj/PeekyFoldersPreview-$arch" \
    -application-extension -Xlinker -e -Xlinker _NSExtensionMain \
    -framework QuickLookUI -framework QuickLookThumbnailing \
    Sources/Shared/*.swift Sources/Extension/*.swift
  echo "• Compiling app ($arch)"
  compile "$arch" PeekyFolders "build/obj/PeekyFolders-$arch" \
    -framework QuickLookThumbnailing \
    Sources/Shared/*.swift Sources/App/*.swift
done
lipo -create build/obj/PeekyFoldersPreview-* -output "$APPEX/Contents/MacOS/PeekyFoldersPreview"
lipo -create build/obj/PeekyFolders-* -output "$APP/Contents/MacOS/PeekyFolders"

cp Resources/Extension-Info.plist "$APPEX/Contents/Info.plist"
cp Resources/App-Info.plist "$APP/Contents/Info.plist"

echo "• Signing (ad-hoc)"
codesign --force --sign - --entitlements Resources/Extension.entitlements "$APPEX"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
echo "✓ Built $APP $VERSION ($(lipo -archs "$APP/Contents/MacOS/PeekyFolders"))"

if [[ "$MODE" == "install" ]]; then
  osascript -e 'quit app "Peeky Folders"' 2>/dev/null || true
  rm -rf ~/Applications/"Peeky Folders.app"
  mkdir -p ~/Applications
  cp -R "$APP" ~/Applications/
  # Launching the app once (hidden) registers the new extension build with Quick Look;
  # pluginkit -a alone doesn't.
  open -g -j ~/Applications/"Peeky Folders.app"
  sleep 3
  osascript -e 'quit app "Peeky Folders"' 2>/dev/null || true
  qlmanage -r >/dev/null 2>&1 || true
  echo "✓ Installed to ~/Applications/Peeky Folders.app"
fi

if [[ "$MODE" == "release" ]]; then
  mkdir -p dist
  ZIP="dist/PeekyFolders-$VERSION.zip"
  rm -f "$ZIP" "$ZIP.sha256"
  # ditto keeps the code signature intact (plain zip can break it); --norsrc leaves out
  # macOS file labels, which would show up as a __MACOSX folder on other systems.
  ditto -c -k --norsrc --keepParent "$APP" "$ZIP"
  (cd dist && shasum -a 256 "$(basename "$ZIP")" | tee "$(basename "$ZIP").sha256")
  echo "✓ Release archive: $ZIP"
fi
