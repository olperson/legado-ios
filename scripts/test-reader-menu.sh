#!/usr/bin/env bash
set -euo pipefail

result=${1:?Pass a path for the XCTest result bundle}
sdk=$(xcrun --sdk iphonesimulator --show-sdk-version)
device=$(xcrun simctl list devices available -j | python3 -c '
import json, re, sys

sdk = tuple(map(int, sys.argv[1].split(".")))
devices = []
for runtime, models in json.load(sys.stdin)["devices"].items():
    match = re.fullmatch(r"com\.apple\.CoreSimulator\.SimRuntime\.iOS-([\d-]+)", runtime)
    if match:
        version = tuple(map(int, match[1].split("-")))
        if version[:2] <= sdk[:2]:
            devices.extend((version, model["name"], model["udid"]) for model in models
                           if model["isAvailable"] and model["name"].startswith("iPhone"))
if not devices:
    sys.exit("No iPhone simulator available for SDK " + sys.argv[1])
print(max(devices)[2])
' "$sdk")
xcrun simctl bootstatus "$device" -b
xcodebuild -project Legado.xcodeproj -scheme LegadoReaderUITests -configuration Debug \
    -destination "platform=iOS Simulator,id=$device" \
    -onlyUsePackageVersionsFromResolvedFile -parallel-testing-enabled NO \
    -resultBundlePath "$result" \
    -only-testing:LegadoReaderUITests/ReaderScrollGestureTests/testCenterTapOpensFontColorPickerBesideFontSize \
    CODE_SIGNING_ALLOWED=NO test
