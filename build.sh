#!/bin/zsh
set -euo pipefail
TASK_ROOT="${0:A:h}"
APP_NAME='Playmelt'
BUNDLE_ID='com.robtech.metalmaxgaminghub'
RELEASE_BUILD=0
for argument in "$@"; do
  case "$argument" in
    --preview) APP_NAME='MetalMax Preview'; BUNDLE_ID='com.robtech.metalmaxgaminghub.preview' ;;
    --release) RELEASE_BUILD=1 ;;
    *) print -u2 "Unknown argument: $argument"; exit 2 ;;
  esac
done
PRODUCT="$TASK_ROOT/Products.noindex/$APP_NAME.app"
mkdir -p "$PRODUCT/Contents/MacOS" "$PRODUCT/Contents/Resources"
swiftc -O -target arm64-apple-macos15.0 -module-name MetalMax "$TASK_ROOT/OwnedProcess.swift" "$TASK_ROOT/EpicConnector.swift" "$TASK_ROOT/RuntimeSetup.swift" "$TASK_ROOT/D3DMetalStore.swift" "$TASK_ROOT/D3DMetalRuntime.swift" "$TASK_ROOT/Core.swift" "$TASK_ROOT/LibraryScan.swift" "$TASK_ROOT/SteamAuthenticationLifetime.swift" "$TASK_ROOT/SteamInstallObserver.swift" "$TASK_ROOT/SteamInstallCoordinator.swift" "$TASK_ROOT/SteamWindowsBootstrap.swift" "$TASK_ROOT/SelfTests.swift" "$TASK_ROOT/main.swift" -o "$PRODUCT/Contents/MacOS/MetalMax" -framework AppKit -framework WebKit -framework Metal
cp "$TASK_ROOT/index.html" "$PRODUCT/Contents/Resources/index.html"
cp "$TASK_ROOT/scripts/epic-worker.py" "$PRODUCT/Contents/Resources/epic-worker.py"
cp "$TASK_ROOT/Resources/SteamLibraryReader.js" "$PRODUCT/Contents/Resources/SteamLibraryReader.js"
for image in PlaymeltLogo.png PlaymeltIcon.png; do
  if [[ -f "$TASK_ROOT/Resources/$image" ]]; then
    cp "$TASK_ROOT/Resources/$image" "$PRODUCT/Contents/Resources/$image"
  fi
done
if [[ -f "$TASK_ROOT/Resources/AppIcon.icns" ]]; then
  cp "$TASK_ROOT/Resources/AppIcon.icns" "$PRODUCT/Contents/Resources/AppIcon.icns"
fi
cat > "$PRODUCT/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleDisplayName</key><string>$APP_NAME</string>
<key>CFBundleExecutable</key><string>MetalMax</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
<key>CFBundleName</key><string>$APP_NAME</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>2.0.0</string>
<key>CFBundleVersion</key><string>2</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
if [[ "$RELEASE_BUILD" == 0 ]]; then
  /usr/libexec/PlistBuddy -c "Add :MetalMaxSourceDirectory string $TASK_ROOT" "$PRODUCT/Contents/Info.plist"
fi
printf '%s\n' "$PRODUCT"
