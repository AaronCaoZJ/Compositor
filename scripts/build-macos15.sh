#!/bin/bash
# Builds Compositor for macOS 15 with the Command Line Tools alone, no Xcode: swiftc and clang for the sources,
# iconutil for the icon, a generated Info.plist, and an ad-hoc signature like the project's own local builds.
#
#   scripts/build-macos15.sh [release|debug]     →  build/macos15/<config>/Compositor.app
#
# Settings that Xcode would take from the project (version, bundle identifier) are read from project.pbxproj,
# so a merge from upstream carries them along. Sparkle is the version Package.resolved pins, checked against the
# checksum its Package.swift declares, as Swift Package Manager does.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
case "$CONFIG" in release|debug) ;; *) echo "usage: $0 [release|debug]" >&2; exit 2 ;; esac

SDK="$(xcrun --show-sdk-path)"
PBX=Compositor.xcodeproj/project.pbxproj
setting() { /usr/bin/grep -m1 "[[:space:]]$1 = " "$PBX" | sed -E "s/.*[[:space:]]$1 = \"?([^\";]*)\"?;.*/\1/"; }
# 15.4, not 15.0: below it, Swift 6.2.0 crashes optimizing the deinit of a generic class under MainActor default
# isolation (IndicatorlessScrollView.Container).
MINIMUM="$(setting MACOSX_DEPLOYMENT_TARGET)"
TARGET="arm64-apple-macos$MINIMUM"
VERSION="$(setting MARKETING_VERSION)"
BUILD_NUMBER="$(setting CURRENT_PROJECT_VERSION)"
BUNDLE_ID="$(setting PRODUCT_BUNDLE_IDENTIFIER)"

SPARKLE_VERSION=2.10.0
SPARKLE_SHA256=17e28312b8e18ab7cdbbe09a6fb28cc55a5479ec6c371dbc07cdecd2a14fd959
RESOLVED=Compositor.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
if ! /usr/bin/grep -q "\"version\" : \"$SPARKLE_VERSION\"" "$RESOLVED"; then
    echo "Package.resolved no longer pins Sparkle $SPARKLE_VERSION: update SPARKLE_VERSION and SPARKLE_SHA256 here" >&2
    echo "from Sparkle's Package.swift at the pinned revision." >&2
    exit 1
fi

OUT="build/macos15/$CONFIG"
OBJ="$OUT/obj"
APP="$OUT/Compositor.app"
rm -rf "$APP" "$OBJ"
mkdir -p "$OBJ" "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"

echo "== Sparkle $SPARKLE_VERSION"
DEPS="build/deps/sparkle-$SPARKLE_VERSION"
if [ ! -d "$DEPS/Sparkle.xcframework" ]; then
    mkdir -p "$DEPS"
    curl -fsSL -o "$DEPS/Sparkle-SPM.zip" \
        "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-for-Swift-Package-Manager.zip"
    echo "$SPARKLE_SHA256  $DEPS/Sparkle-SPM.zip" | shasum -a 256 -c -
    ditto -x -k "$DEPS/Sparkle-SPM.zip" "$DEPS"
fi
SPARKLE="$DEPS/Sparkle.xcframework/macos-arm64_x86_64"

if [ "$CONFIG" = release ]; then
    C_FLAGS=(-O3)
    SWIFT_MODE=(-O -wmo -num-threads 8)
else
    C_FLAGS=(-O0 -g -DDEBUG=1)
    SWIFT_MODE=(-Onone -g -DDEBUG)
fi

echo "== C"
C_OBJECTS=()
while IFS= read -r -d '' source; do
    object="$OBJ/$(basename "${source%.c}").o"
    xcrun clang -c -std=gnu17 -target "$TARGET" -isysroot "$SDK" "${C_FLAGS[@]}" -o "$object" "$source"
    C_OBJECTS+=("$object")
done < <(find Compositor -name '*.c' -print0)

echo "== Swift ($CONFIG)"
SWIFT_SOURCES=()
while IFS= read -r -d '' source; do SWIFT_SOURCES+=("$source"); done < <(find Compositor -name '*.swift' -print0)
# The project's Swift settings: Swift 5 mode, MainActor by default, Approachable Concurrency's five features, and
# member import visibility.
xcrun swiftc "${SWIFT_MODE[@]}" -target "$TARGET" -sdk "$SDK" -swift-version 5 -module-name Compositor \
    -default-isolation MainActor \
    -enable-upcoming-feature DisableOutwardActorInference \
    -enable-upcoming-feature GlobalActorIsolatedTypesUsability \
    -enable-upcoming-feature InferIsolatedConformances \
    -enable-upcoming-feature InferSendableFromCaptures \
    -enable-upcoming-feature NonisolatedNonsendingByDefault \
    -enable-upcoming-feature MemberImportVisibility \
    -import-objc-header Compositor/Compositor-Bridging-Header.h \
    -F "$SPARKLE" \
    -Xlinker -rpath -Xlinker @executable_path/../Frameworks -Xlinker -dead_strip \
    -o "$APP/Contents/MacOS/Compositor" \
    "${SWIFT_SOURCES[@]}" "${C_OBJECTS[@]}"

echo "== Bundle"
# Info.plist: the project's own keys, plus those GENERATE_INFOPLIST_FILE would add.
PLIST="$APP/Contents/Info.plist"
cp Config/Info.plist "$PLIST"
put() { plutil -replace "$1" "-$2" "$3" "$PLIST"; }
put CFBundleDevelopmentRegion string en
put CFBundleExecutable string Compositor
put CFBundleIdentifier string "$BUNDLE_ID"
put CFBundleInfoDictionaryVersion string 6.0
put CFBundleName string Compositor
put CFBundlePackageType string APPL
put CFBundleShortVersionString string "$VERSION"
put CFBundleVersion string "$BUILD_NUMBER"
put CFBundleIconFile string AppIcon
put LSMinimumSystemVersion string "$MINIMUM"
put LSApplicationCategoryType string public.app-category.graphics-design
put NSPrincipalClass string NSApplication
plutil -lint "$PLIST" >/dev/null

# The icon, from the asset catalog's PNGs: each point size and its @2x.
ICONSET="$OBJ/AppIcon.iconset"
ICONS=Compositor/Assets.xcassets/AppIcon.appiconset
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    cp "$ICONS/app-icon-$size.png" "$ICONSET/icon_${size}x${size}.png"
    cp "$ICONS/app-icon-$((size * 2)).png" "$ICONSET/icon_${size}x${size}@2x.png"
done
iconutil -c icns -o "$APP/Contents/Resources/AppIcon.icns" "$ICONSET"

cp Compositor/Resources/*.bin "$APP/Contents/Resources/"
# The string catalog, as the tables Xcode compiles it to: Localizable.strings for each language, which the app then
# follows macOS's language settings between (docs/localization.md).
python3 - "$APP/Contents/Resources" <<'PY'
import json, pathlib, plistlib, sys
catalog = json.load(open("Compositor/Resources/Localizable.xcstrings"))
for language in ("en", "zh-Hans"):
    table = {key: entry["localizations"][language]["stringUnit"]["value"]
             for key, entry in catalog["strings"].items() if key and language in entry.get("localizations", {})}
    folder = pathlib.Path(sys.argv[1]) / f"{language}.lproj"
    folder.mkdir(exist_ok=True)
    with open(folder / "Localizable.strings", "wb") as file:
        plistlib.dump(table, file, fmt=plistlib.FMT_BINARY)
PY
ditto "$SPARKLE/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"

echo "== Sign (ad-hoc)"
# Inside out, as Sparkle's documentation orders it. Without the hardened runtime: it is for notarized releases, and
# under it an ad-hoc app can't load an ad-hoc framework, since library validation compares Team IDs and ad-hoc
# signatures have none. The sandbox stays, so files are reached as in the released app.
sign() { codesign --force --sign - --timestamp=none "$@"; }
SPARKLE_B="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
sign "$SPARKLE_B/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$SPARKLE_B/XPCServices/Downloader.xpc"
sign "$SPARKLE_B/Autoupdate"
sign "$SPARKLE_B/Updater.app"
sign "$APP/Contents/Frameworks/Sparkle.framework"
ENTITLEMENTS="$OBJ/Compositor.entitlements"
sed 's/\$(PRODUCT_BUNDLE_IDENTIFIER)/'"$BUNDLE_ID"'/g' Config/Compositor.entitlements > "$ENTITLEMENTS"
sign --entitlements "$ENTITLEMENTS" "$APP"
codesign --verify --deep --strict "$APP"

echo "Built $APP (Compositor $VERSION, build $BUILD_NUMBER, macOS $MINIMUM or later)"
