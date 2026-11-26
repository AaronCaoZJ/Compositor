#!/bin/bash
# Lists the strings the app shows that Compositor/Resources/Localizable.xcstrings has no entry for, without Xcode:
# the sources are compiled far enough for the compiler to write out every localizable string it sees (the same
# .stringsdata an Xcode build leaves in its derived data, which scripts/check-localizations.py reads). The list is
# printed and left in build/missing-keys.json. Strings looked up at run time through L10n.string aren't seen.
# Run scripts/build-macos15.sh once first: it fetches Sparkle, which the sources import.
cd "$(dirname "$0")/.."
rm -rf build/strings; mkdir -p build/strings
SP=build/deps/sparkle-2.10.0/Sparkle.xcframework/macos-arm64_x86_64
xcrun swiftc -emit-module -emit-module-path build/strings/Compositor.swiftmodule -Onone -wmo -sdk "$(xcrun --show-sdk-path)" -target arm64-apple-macos15.4 -swift-version 5 \
  -default-isolation MainActor -enable-upcoming-feature DisableOutwardActorInference -enable-upcoming-feature GlobalActorIsolatedTypesUsability \
  -enable-upcoming-feature InferIsolatedConformances -enable-upcoming-feature InferSendableFromCaptures \
  -enable-upcoming-feature NonisolatedNonsendingByDefault -enable-upcoming-feature MemberImportVisibility \
  -F $SP -import-objc-header Compositor/Compositor-Bridging-Header.h -module-name Compositor \
  -emit-localized-strings -emit-localized-strings-path build/strings $(find Compositor -name '*.swift') > build/strings.log 2>&1 || { echo "compile failed"; exit 1; }
python3 -I - <<'PY'
import json, subprocess, pathlib
catalog = json.load(open("Compositor/Resources/Localizable.xcstrings"))["strings"]
missing = {}; total = set()
for path in sorted(pathlib.Path("build/strings").glob("*.stringsdata")):
    data = json.loads(subprocess.check_output(["plutil", "-convert", "json", "-o", "-", str(path)]))
    for entries in data.get("tables", {}).values():
        for e in entries:
            total.add(e["key"])
            if e["key"] not in catalog: missing.setdefault(e["key"], []).append(path.stem)
json.dump({k: sorted(set(v)) for k, v in missing.items()}, open("build/missing-keys.json", "w"), ensure_ascii=False, indent=1)
print(f"extracted {len(total)} keys; missing from the catalog: {len(missing)}")
for key in missing: print("  ", repr(key))
PY
