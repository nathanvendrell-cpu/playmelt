#!/bin/zsh
set -euo pipefail
TASK_ROOT="${0:A:h}"
APP_NAME='Playmelt'
BUNDLE_ID='com.robtech.metalmaxgaminghub'
RELEASE_BUILD=0
OWNER_BUILD=0
PLAYMELT_VERSION="${PLAYMELT_VERSION:-2.2.1}"
PLAYMELT_BUILD_NUMBER="${PLAYMELT_BUILD_NUMBER:-31}"
for argument in "$@"; do
  case "$argument" in
    --preview) APP_NAME='MetalMax Preview'; BUNDLE_ID='com.robtech.metalmaxgaminghub.preview' ;;
    --release) RELEASE_BUILD=1 ;;
    --owner) OWNER_BUILD=1 ;;
    *) print -u2 "Unknown argument: $argument"; exit 2 ;;
  esac
done
[[ "$RELEASE_BUILD$OWNER_BUILD" != 11 ]] || { print -u2 'Internal owner and commercial release modes are exclusive.'; exit 2; }
ACCOUNT_MODE="$RELEASE_BUILD"
if [[ "$OWNER_BUILD" == 1 ]]; then ACCOUNT_MODE=owner; fi
if [[ "$RELEASE_BUILD" == 1 ]]; then
  [[ "${PLAYMELT_ACCOUNT_VERIFIED:-0}" == 1 ]] || { print -u2 'Verify hosted account and native device authorization before client release.'; exit 2; }
  [[ "$PLAYMELT_VERSION" != 2.1.0 ]] || { print -u2 'Commercial release requires a new coordinated version.'; exit 2; }
fi
python3 "$TASK_ROOT/scripts/configure_account_bundle.py" --check "$TASK_ROOT/config/native-account.json" "$ACCOUNT_MODE"
if [[ "$RELEASE_BUILD$OWNER_BUILD" != 00 || -d "$TASK_ROOT/Dependencies.noindex/client-python" ]]; then
  python3 "$TASK_ROOT/scripts/prepare_portable_python.py" --check
fi
if ! command -v x86_64-w64-mingw32-g++ >/dev/null; then
  print -u2 'Spider-Man 2 compatibility helpers require the x86_64 MinGW compiler.'
  exit 1
fi
PRODUCTS_ROOT="${PLAYMELT_PRODUCTS_ROOT:-$TASK_ROOT/Products.noindex}"
PRODUCTS_ROOT="${PRODUCTS_ROOT:A}"
case "$PRODUCTS_ROOT" in
  "$TASK_ROOT/Products.noindex"|"$TASK_ROOT/Products.noindex/"*) ;;
  *) print -u2 'Build products must remain under Products.noindex.'; exit 2 ;;
esac
PRODUCT="$PRODUCTS_ROOT/$APP_NAME.app"
SPARKLE_ROOT="$TASK_ROOT/Dependencies.noindex/sparkle-2.10.1"
mkdir -p "$PRODUCT/Contents/MacOS" "$PRODUCT/Contents/Resources" "$PRODUCT/Contents/Frameworks"
clang -dynamiclib -arch x86_64 -arch arm64 -mmacosx-version-min=15.0 -Wall -Wextra -Werror "$TASK_ROOT/probes/display-guard.c" -framework CoreGraphics -o "$PRODUCT/Contents/Resources/libPlaymeltDisplayGuard.dylib"
/usr/bin/codesign --force --sign - --timestamp=none "$PRODUCT/Contents/Resources/libPlaymeltDisplayGuard.dylib"
swiftc -j 1 -O -target arm64-apple-macos15.0 -module-name MetalMax "$TASK_ROOT/OwnedProcess.swift" "$TASK_ROOT/PortablePythonRuntime.swift" "$TASK_ROOT/EpicSessionStore.swift" "$TASK_ROOT/EpicConnector.swift" "$TASK_ROOT/XboxConnector.swift" "$TASK_ROOT/XboxWebSession.swift" "$TASK_ROOT/XboxRecentGames.swift" "$TASK_ROOT/GOGConnector.swift" "$TASK_ROOT/GOGInstallObserver.swift" "$TASK_ROOT/InstallOperations.swift" "$TASK_ROOT/GameMediaCatalog.swift" "$TASK_ROOT/GameMediaPlayer.swift" "$TASK_ROOT/SteamClientLifecycle.swift" "$TASK_ROOT/RuntimeSetup.swift" "$TASK_ROOT/D3DMetalStore.swift" "$TASK_ROOT/NvidiaBridgeStore.swift" \
		"$TASK_ROOT/GameDockRuntime.swift" "$TASK_ROOT/D3DMetalRuntime.swift" "$TASK_ROOT/GraphicsMemoryBudget.swift" "$TASK_ROOT/GraphicsFeatureContract.swift" "$TASK_ROOT/GraphicsFrameAdapter.swift" "$TASK_ROOT/MetalFXFrameAdapter.swift" "$TASK_ROOT/MetalFXRayReconstructionAdapter.swift" "$TASK_ROOT/GameDisplayMetadata.swift" "$TASK_ROOT/GameSettings.swift" "$TASK_ROOT/GamePerformanceRuntime.swift" "$TASK_ROOT/LocalGameImport.swift" "$TASK_ROOT/Core.swift" "$TASK_ROOT/LibraryScan.swift" "$TASK_ROOT/SteamAuthenticationLifetime.swift" "$TASK_ROOT/SteamInstallObserver.swift" "$TASK_ROOT/SteamInstallCoordinator.swift" "$TASK_ROOT/SteamBootstrapPackage.swift" "$TASK_ROOT/SteamWindowsBootstrap.swift" "$TASK_ROOT/SelfTests.swift" "$TASK_ROOT/Updater.swift" "$TASK_ROOT/Entitlement.swift" "$TASK_ROOT/AccountService.swift" "$TASK_ROOT/AccountWebAuthentication.swift" "$TASK_ROOT/HubFeed.swift" "$TASK_ROOT/OffersCatalog.swift" "$TASK_ROOT/ProfileProgression.swift" "$TASK_ROOT/PlayerProfile.swift" "$TASK_ROOT/IssueReports.swift" "$TASK_ROOT/Benchmarks.swift" "$TASK_ROOT/GameTheme.swift" "$TASK_ROOT/HubBrowserPanel.swift" "$TASK_ROOT/main.swift" -o "$PRODUCT/Contents/MacOS/MetalMax" -F "$SPARKLE_ROOT" -framework AppKit -framework WebKit -framework Metal -framework MetalFX -framework Security -framework LocalAuthentication -framework AuthenticationServices -framework Sparkle -Xlinker -rpath -Xlinker "@executable_path/../Frameworks"
cp "$TASK_ROOT/index.html" "$PRODUCT/Contents/Resources/index.html"
cp "$TASK_ROOT/Resources/GameMedia.js" "$PRODUCT/Contents/Resources/GameMedia.js"
cp "$TASK_ROOT/Resources/Account.js" "$TASK_ROOT/Resources/Onboarding.js" "$TASK_ROOT/Resources/Settings.js" "$TASK_ROOT/Resources/Artwork.js" "$TASK_ROOT/Resources/Experience.js" "$TASK_ROOT/Resources/Discover.js" "$TASK_ROOT/Resources/Experience.css" "$TASK_ROOT/Resources/PlatformThemes.css" "$PRODUCT/Contents/Resources/"
cp "$TASK_ROOT/Resources/AccountLogin.js" "$TASK_ROOT/Resources/AccountLogin.css" "$TASK_ROOT/Resources/Finish.css" "$PRODUCT/Contents/Resources/"
cp "$TASK_ROOT/Resources/AppIntro.js" "$TASK_ROOT/Resources/AppIntro.css" "$TASK_ROOT/Resources/PlaymeltMark.png" "$TASK_ROOT/Resources/PlaymeltMarkInk.png" "$TASK_ROOT/Resources/PlaymeltMarkOrange.png" "$TASK_ROOT/Resources/PlaymeltWordmark.png" "$TASK_ROOT/Resources/GoogleG.png" "$PRODUCT/Contents/Resources/"
cp "$TASK_ROOT/scripts/epic-worker.py" "$PRODUCT/Contents/Resources/epic-worker.py"
cp "$TASK_ROOT/scripts/steam-installer.py" "$PRODUCT/Contents/Resources/steam-installer.py"
cp "$TASK_ROOT/scripts/steam_appinfo.py" "$PRODUCT/Contents/Resources/steam_appinfo.py"
cp "$TASK_ROOT/scripts/steam_install_plan.py" "$PRODUCT/Contents/Resources/steam_install_plan.py"
cp "$TASK_ROOT/scripts/steam_prerequisites.py" "$PRODUCT/Contents/Resources/steam_prerequisites.py"
cp "$TASK_ROOT/scripts/steam_reuse.py" "$PRODUCT/Contents/Resources/steam_reuse.py"
cp "$TASK_ROOT/Resources/SteamRendererProfiles.json" "$PRODUCT/Contents/Resources/SteamRendererProfiles.json"
for script in game_display_quality.py local_game_import.py session_benchmark.py metal_performance_capture.py analyze_metal_performance.py spiderman2_profile.py m3_private_supervisor.py m3_private_supervisor_policy.py m3_reuse_diagnostic.py gpu_hardwareid_transaction.py m3_hardwareid_experiment.py; do
  cp "$TASK_ROOT/scripts/$script" "$PRODUCT/Contents/Resources/$script"
done
x86_64-w64-mingw32-g++ -std=c++17 -O2 -Wall -Wextra -Werror -static -Wl,--no-insert-timestamp -o "$PRODUCT/Contents/Resources/setupapi-hardwareid-cas.exe" "$TASK_ROOT/probes/setupapi-hardwareid-cas.cpp" -ladvapi32
x86_64-w64-mingw32-g++ -std=c++17 -O2 -Wall -Wextra -Werror -static -Wl,--no-insert-timestamp -o "$PRODUCT/Contents/Resources/setupapi-identity-probe.exe" "$TASK_ROOT/probes/setupapi-identity-probe.cpp" -lsetupapi -luuid -luser32
x86_64-w64-mingw32-g++ -std=c++17 -O2 -Wall -Wextra -Werror -static -Wl,--no-insert-timestamp -o "$PRODUCT/Contents/Resources/spiderman-retina-default.exe" "$TASK_ROOT/probes/spiderman-retina-default.cpp" -ladvapi32
x86_64-w64-mingw32-g++ -std=c++17 -O2 -Wall -Wextra -Werror -static -Wl,--no-insert-timestamp -o "$PRODUCT/Contents/Resources/spiderman-profile-settings.exe" "$TASK_ROOT/probes/spiderman-profile-settings.cpp" -ladvapi32 -ldxgi -ldxguid
cas_hash="$(shasum -a 256 "$PRODUCT/Contents/Resources/setupapi-hardwareid-cas.exe" | awk '{print $1}')"
probe_hash="$(shasum -a 256 "$PRODUCT/Contents/Resources/setupapi-identity-probe.exe" | awk '{print $1}')"
retina_hash="$(shasum -a 256 "$PRODUCT/Contents/Resources/spiderman-retina-default.exe" | awk '{print $1}')"
settings_hash="$(shasum -a 256 "$PRODUCT/Contents/Resources/spiderman-profile-settings.exe" | awk '{print $1}')"
swiftc -j 1 -O -target arm64-apple-macos15.0 "$TASK_ROOT/OwnedProcess.swift" "$TASK_ROOT/PortablePythonRuntime.swift" "$TASK_ROOT/EpicSessionStore.swift" "$TASK_ROOT/EpicConnector.swift" "$TASK_ROOT/XboxConnector.swift" "$TASK_ROOT/XboxWebSession.swift" "$TASK_ROOT/XboxRecentGames.swift" "$TASK_ROOT/GOGConnector.swift" "$TASK_ROOT/GOGInstallObserver.swift" "$TASK_ROOT/InstallOperations.swift" "$TASK_ROOT/SteamClientLifecycle.swift" "$TASK_ROOT/RuntimeSetup.swift" "$TASK_ROOT/D3DMetalStore.swift" "$TASK_ROOT/NvidiaBridgeStore.swift" \
		"$TASK_ROOT/GameDockRuntime.swift" "$TASK_ROOT/D3DMetalRuntime.swift" "$TASK_ROOT/GraphicsMemoryBudget.swift" "$TASK_ROOT/GraphicsFeatureContract.swift" "$TASK_ROOT/GraphicsFrameAdapter.swift" "$TASK_ROOT/MetalFXFrameAdapter.swift" "$TASK_ROOT/MetalFXRayReconstructionAdapter.swift" "$TASK_ROOT/GameDisplayMetadata.swift" "$TASK_ROOT/GameSettings.swift" "$TASK_ROOT/GamePerformanceRuntime.swift" "$TASK_ROOT/LocalGameImport.swift" "$TASK_ROOT/Core.swift" "$TASK_ROOT/LibraryScan.swift" "$TASK_ROOT/SteamAuthenticationLifetime.swift" "$TASK_ROOT/SteamInstallObserver.swift" "$TASK_ROOT/SteamInstallCoordinator.swift" "$TASK_ROOT/SteamBootstrapPackage.swift" "$TASK_ROOT/SteamWindowsBootstrap.swift" "$TASK_ROOT/scripts/m3_private_plan.swift" -o "$PRODUCT/Contents/Resources/m3-private-plan" -framework AppKit -framework WebKit -framework Metal -framework MetalFX -framework Security -framework LocalAuthentication
plan_hash="$(shasum -a 256 "$PRODUCT/Contents/Resources/m3-private-plan" | awk '{print $1}')"
printf '{"cas":"%s","probe":"%s","retina":"%s","settings":"%s","plan":"%s"}\n' "$cas_hash" "$probe_hash" "$retina_hash" "$settings_hash" "$plan_hash" > "$PRODUCT/Contents/Resources/spiderman-runtime-hashes.json"
cat "$TASK_ROOT/THIRD_PARTY_NOTICES.md" "$SPARKLE_ROOT/LICENSE" > "$PRODUCT/Contents/Resources/ThirdPartyNotices.txt"
mkdir -p "$PRODUCT/Contents/Resources/ThirdPartyLicenses"
cp "$TASK_ROOT/Resources/ThirdPartyLicenses/"*.txt "$PRODUCT/Contents/Resources/ThirdPartyLicenses/"
cp "$TASK_ROOT/Resources/SteamLibraryReader.js" "$PRODUCT/Contents/Resources/SteamLibraryReader.js"
# Not used by the app: do not redistribute the vendor Steam DLL.
# Preserve the source copy; remove only a stale generated bundle artifact.
if [[ -f "$PRODUCT/Contents/Resources/steam_api64.dll" ]]; then
  rm "$PRODUCT/Contents/Resources/steam_api64.dll"
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
<key>CFBundleShortVersionString</key><string>$PLAYMELT_VERSION</string>
<key>CFBundleVersion</key><string>$PLAYMELT_BUILD_NUMBER</string>
<key>CFBundleURLTypes</key><array><dict><key>CFBundleURLName</key><string>fr.playmelt.account</string><key>CFBundleURLSchemes</key><array><string>playmelt</string></array></dict></array>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>SUFeedURL</key><string>https://7agency.fr/Playmelt/appcast.xml</string>
<key>SUPublicEDKey</key><string>EpYsQMEo5yPGHpY7Q03Y4a35eLsBh/7Y0mW04TtJ5hs=</string>
<key>SUEnableAutomaticChecks</key><true/>
<key>SUAllowsAutomaticUpdates</key><true/>
<key>SUAutomaticallyUpdate</key><true/>
<key>SUScheduledCheckInterval</key><integer>86400</integer>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
python3 "$TASK_ROOT/scripts/configure_account_bundle.py" --write "$TASK_ROOT/config/native-account.json" "$ACCOUNT_MODE" "$PRODUCT/Contents/Info.plist"

if [[ "$RELEASE_BUILD$OWNER_BUILD" == 00 ]]; then
  /usr/libexec/PlistBuddy -c "Add :MetalMaxSourceDirectory string $TASK_ROOT" "$PRODUCT/Contents/Info.plist"
fi
# Embed Sparkle (framework keeps its own release signature; sealed by the outer bundle below).
rm -rf "$PRODUCT/Contents/Frameworks/Sparkle.framework"
cp -R "$SPARKLE_ROOT/Sparkle.framework" "$PRODUCT/Contents/Frameworks/Sparkle.framework"
if [[ -d "$TASK_ROOT/Dependencies.noindex/client-python" ]]; then
  python3 "$TASK_ROOT/scripts/embed_portable_python.py" "$TASK_ROOT/Dependencies.noindex/client-python" "$PRODUCT/Contents/Resources/Python"
fi
# Seal the completed bundle, including Info.plist and every copied resource.
/usr/bin/codesign --force --sign - --timestamp=none "$PRODUCT"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$PRODUCT"
printf '%s\n' "$PRODUCT"
