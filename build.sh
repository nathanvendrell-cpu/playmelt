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
if ! command -v x86_64-w64-mingw32-g++ >/dev/null; then
  print -u2 'Spider-Man 2 compatibility helpers require the x86_64 MinGW compiler.'
  exit 1
fi
PRODUCT="$TASK_ROOT/Products.noindex/$APP_NAME.app"
mkdir -p "$PRODUCT/Contents/MacOS" "$PRODUCT/Contents/Resources"
swiftc -j 1 -O -target arm64-apple-macos15.0 -module-name MetalMax "$TASK_ROOT/OwnedProcess.swift" "$TASK_ROOT/EpicSessionStore.swift" "$TASK_ROOT/EpicConnector.swift" "$TASK_ROOT/RuntimeSetup.swift" "$TASK_ROOT/D3DMetalStore.swift" "$TASK_ROOT/D3DMetalRuntime.swift" "$TASK_ROOT/GraphicsMemoryBudget.swift" "$TASK_ROOT/GraphicsFeatureContract.swift" "$TASK_ROOT/GraphicsFrameAdapter.swift" "$TASK_ROOT/GameDisplayMetadata.swift" "$TASK_ROOT/GameSettings.swift" "$TASK_ROOT/Core.swift" "$TASK_ROOT/LibraryScan.swift" "$TASK_ROOT/SteamAuthenticationLifetime.swift" "$TASK_ROOT/SteamInstallObserver.swift" "$TASK_ROOT/SteamInstallCoordinator.swift" "$TASK_ROOT/SteamWindowsBootstrap.swift" "$TASK_ROOT/SelfTests.swift" "$TASK_ROOT/main.swift" -o "$PRODUCT/Contents/MacOS/MetalMax" -framework AppKit -framework WebKit -framework Metal -framework Security -framework LocalAuthentication
cp "$TASK_ROOT/index.html" "$PRODUCT/Contents/Resources/index.html"
cp "$TASK_ROOT/scripts/epic-worker.py" "$PRODUCT/Contents/Resources/epic-worker.py"
cp "$TASK_ROOT/scripts/steam-installer.py" "$PRODUCT/Contents/Resources/steam-installer.py"
for script in spiderman2_profile.py m3_private_supervisor.py m3_private_supervisor_policy.py m3_reuse_diagnostic.py gpu_hardwareid_transaction.py m3_hardwareid_experiment.py; do
  cp "$TASK_ROOT/scripts/$script" "$PRODUCT/Contents/Resources/$script"
done
x86_64-w64-mingw32-g++ -std=c++17 -O2 -Wall -Wextra -Werror -static -Wl,--no-insert-timestamp -o "$PRODUCT/Contents/Resources/setupapi-hardwareid-cas.exe" "$TASK_ROOT/probes/setupapi-hardwareid-cas.cpp" -ladvapi32
x86_64-w64-mingw32-g++ -std=c++17 -O2 -Wall -Wextra -Werror -static -Wl,--no-insert-timestamp -o "$PRODUCT/Contents/Resources/setupapi-identity-probe.exe" "$TASK_ROOT/probes/setupapi-identity-probe.cpp" -lsetupapi -luuid -luser32
x86_64-w64-mingw32-g++ -std=c++17 -O2 -Wall -Wextra -Werror -static -Wl,--no-insert-timestamp -o "$PRODUCT/Contents/Resources/spiderman-retina-default.exe" "$TASK_ROOT/probes/spiderman-retina-default.cpp" -ladvapi32
x86_64-w64-mingw32-g++ -std=c++17 -O2 -Wall -Wextra -Werror -static -Wl,--no-insert-timestamp -o "$PRODUCT/Contents/Resources/spiderman-profile-settings.exe" "$TASK_ROOT/probes/spiderman-profile-settings.cpp" -ladvapi32
cas_hash="$(shasum -a 256 "$PRODUCT/Contents/Resources/setupapi-hardwareid-cas.exe" | awk '{print $1}')"
probe_hash="$(shasum -a 256 "$PRODUCT/Contents/Resources/setupapi-identity-probe.exe" | awk '{print $1}')"
retina_hash="$(shasum -a 256 "$PRODUCT/Contents/Resources/spiderman-retina-default.exe" | awk '{print $1}')"
settings_hash="$(shasum -a 256 "$PRODUCT/Contents/Resources/spiderman-profile-settings.exe" | awk '{print $1}')"
swiftc -j 1 -O -target arm64-apple-macos15.0 "$TASK_ROOT/OwnedProcess.swift" "$TASK_ROOT/EpicSessionStore.swift" "$TASK_ROOT/EpicConnector.swift" "$TASK_ROOT/RuntimeSetup.swift" "$TASK_ROOT/D3DMetalStore.swift" "$TASK_ROOT/D3DMetalRuntime.swift" "$TASK_ROOT/GraphicsMemoryBudget.swift" "$TASK_ROOT/GraphicsFeatureContract.swift" "$TASK_ROOT/GraphicsFrameAdapter.swift" "$TASK_ROOT/GameDisplayMetadata.swift" "$TASK_ROOT/GameSettings.swift" "$TASK_ROOT/Core.swift" "$TASK_ROOT/LibraryScan.swift" "$TASK_ROOT/SteamAuthenticationLifetime.swift" "$TASK_ROOT/SteamInstallObserver.swift" "$TASK_ROOT/SteamInstallCoordinator.swift" "$TASK_ROOT/SteamWindowsBootstrap.swift" "$TASK_ROOT/scripts/m3_private_plan.swift" -o "$PRODUCT/Contents/Resources/m3-private-plan" -framework AppKit -framework WebKit -framework Metal -framework Security -framework LocalAuthentication
plan_hash="$(shasum -a 256 "$PRODUCT/Contents/Resources/m3-private-plan" | awk '{print $1}')"
printf '{"cas":"%s","probe":"%s","retina":"%s","settings":"%s","plan":"%s"}\n' "$cas_hash" "$probe_hash" "$retina_hash" "$settings_hash" "$plan_hash" > "$PRODUCT/Contents/Resources/spiderman-runtime-hashes.json"
cp "$TASK_ROOT/Resources/SteamLibraryReader.js" "$PRODUCT/Contents/Resources/SteamLibraryReader.js"
if [[ -f "$TASK_ROOT/Resources/steam_api64.dll" ]]; then
  cp "$TASK_ROOT/Resources/steam_api64.dll" "$PRODUCT/Contents/Resources/steam_api64.dll"
fi
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
# Seal the completed bundle, including Info.plist and every copied resource.
/usr/bin/codesign --force --sign - --timestamp=none "$PRODUCT"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$PRODUCT"
printf '%s\n' "$PRODUCT"
