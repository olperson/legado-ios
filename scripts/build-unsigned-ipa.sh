#!/bin/bash
set -euo pipefail

fail() { printf '%s\n' "$*" >&2; exit 1; }

[[ $# == 2 && -n $1 ]] || fail "Usage: bash $0 OUTPUT_DIRECTORY vX.Y.Z"
output_dir=$1
tag=$2
[[ $tag =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "Invalid release tag: $tag (expected vX.Y.Z)"
[[ $output_dir == /* ]] || output_dir="$PWD/$output_dir"

project_root=$(cd "$(dirname "$0")/.." && pwd)
cd "$project_root"
project=Legado.xcodeproj
[[ -s "$project/project.xcworkspace/xcshareddata/swiftpm/Package.resolved" ]] || fail "Missing Xcode package lock"

work_dir=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/legado-release.XXXXXXXX")
staging_dir=''
cleanup() {
    rm -rf "$work_dir"
    if [[ -n $staging_dir ]]; then rm -rf "$staging_dir"; fi
}
trap cleanup EXIT

xcodebuild -project "$project" -scheme Legado -configuration Release \
    -sdk iphoneos -destination 'generic/platform=iOS' \
    -derivedDataPath "$work_dir/DerivedData" -onlyUsePackageVersionsFromResolvedFile \
    ARCHS=arm64 CODE_SIGNING_ALLOWED=NO build

app="$work_dir/DerivedData/Build/Products/Release-iphoneos/Legado.app"
info="$app/Info.plist"
[[ -s $info ]] || fail "Missing Release device app at $app"
version=$(plutil -extract CFBundleShortVersionString raw -o - "$info")
build=$(plutil -extract CFBundleVersion raw -o - "$info")
bundle_id=$(plutil -extract CFBundleIdentifier raw -o - "$info")
platform=$(plutil -extract CFBundleSupportedPlatforms.0 raw -o - "$info")
[[ v$version == "$tag" ]] || fail "Built app version $version does not match $tag"
[[ $build =~ ^[1-9][0-9]*$ ]] || fail "Invalid app build number: $build"
[[ $bundle_id == com.epiboly.legado ]] || fail "Unexpected bundle identifier: $bundle_id"
[[ $platform == iPhoneOS ]] || fail "Unexpected app platform: $platform"

# The release and the AltStore source both use this app without extensions or signing resources.
unexpected=$(find "$app" \( -name embedded.mobileprovision -o -name _CodeSignature -o -name '*.appex' \) -print)
[[ -z $unexpected ]] || fail "Unexpected content in the unsigned build: $unexpected"

shopt -s nullglob
for bundle in "$app" "$app"/Frameworks/*.framework; do
    executable=$(plutil -extract CFBundleExecutable raw -o - "$bundle/Info.plist")
    [[ -n $executable && $executable != */* && -f $bundle/$executable ]] || fail "Invalid executable in $bundle"
    archs=$(xcrun lipo -archs "$bundle/$executable")
    [[ $archs == arm64 ]] || fail "Unexpected architecture in $executable: $archs"
    platform=$(xcrun vtool -show-build "$bundle/$executable" | awk '$1 == "platform" { print $2 }')
    [[ $platform == IOS ]] || fail "Expected an iOS device executable in $bundle, found: $platform"
done

name="legado-ios-$tag-build$build-unsigned.ipa"
mkdir -p "$work_dir/Payload" "$output_dir"
mv "$app" "$work_dir/Payload/Legado.app"
# Stage on the output filesystem so the verified archive appears in one rename.
staging_dir=$(mktemp -d "$output_dir/.legado-ipa.XXXXXXXX")
(cd "$work_dir" && zip -qry "$staging_dir/$name" Payload)
unzip -tq "$staging_dir/$name"
mv -f "$staging_dir/$name" "$output_dir/$name"
printf 'Built %s\n' "$output_dir/$name"
