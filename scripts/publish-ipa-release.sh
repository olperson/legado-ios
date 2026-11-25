#!/usr/bin/env bash
set -euo pipefail

dist=$1
tag=$2
[[ $tag =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Expected a vX.Y.Z tag" >&2; exit 1; }
repo=${GITHUB_REPOSITORY:?}
shopt -s nullglob
ipas=("$dist"/legado-ios-"$tag"-build*-unsigned.ipa)
[[ ${#ipas[@]} == 1 ]] || { echo "Expected one IPA for $tag" >&2; exit 1; }
name=$(basename "${ipas[0]}")
(cd "$dist" && sha256sum "$name") | cmp - "$dist/SHA256SUMS"

commit=$(git rev-parse HEAD)
ref="refs/tags/$tag"
if git ls-remote --exit-code --refs origin "$ref" > /dev/null; then
    git fetch --no-tags origin "$ref"
    [[ $(git rev-parse 'FETCH_HEAD^{commit}') == "$commit" ]] || {
        echo "$tag already points to a different commit." >&2; exit 1;
    }
else
    status=$?
    [[ $status == 2 ]] || exit "$status"
    if [[ $GITHUB_EVENT_NAME != workflow_dispatch ]]; then
        subject=$(git show -s --format=%B HEAD)
        [[ $GITHUB_EVENT_NAME == push && $GITHUB_REF == refs/heads/main &&
           ${subject%%$'\n'*} == "发布 IPA $tag" ]] || exit 1
        [[ $(git ls-remote --refs origin refs/heads/main | cut -f1) == "$commit" ]] || {
            echo "A newer main commit has superseded this release request." >&2; exit 1;
        }
    fi
    gh api --method POST "repos/$repo/git/refs" -f ref="$ref" -f sha="$commit" > /dev/null
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

if ! gh release view "$tag" -R "$repo" --json isDraft,assets > "$work/release.json"; then
    awk -v version="${tag#v}" '/^## / {
        if (found) exit
        found = (index($0, "## " version "（") == 1 || $0 == "## " version)
        next
    } found { print }' CHANGELOG.md > "$work/notes.md"
    printf '\n下载附件中的未签名 IPA，使用 AltStore、SideStore 或其他签名工具安装。\n' >> "$work/notes.md"
    gh release create "$tag" -R "$repo" --verify-tag --draft --title "小浣熊阅读 $tag" --notes-file "$work/notes.md"
    gh release view "$tag" -R "$repo" --json isDraft,assets > "$work/release.json"
fi

draft=$(jq -r '.isDraft' "$work/release.json")
has_asset() { jq -e --arg name "$1" 'any(.assets[]; .name == $name and (.state | ascii_downcase) == "uploaded")' "$work/release.json" > /dev/null; }
upload_missing() {
    local file=$1 asset
    asset=$(basename "$file")
    [[ $draft == true ]] || { echo "Published release $tag is missing $asset" >&2; exit 1; }
    local flags=()
    # An interrupted GitHub upload can leave a same-name placeholder in a draft.
    if jq -e --arg name "$asset" 'any(.assets[]; .name == $name)' "$work/release.json" > /dev/null; then
        flags+=(--clobber)
    fi
    gh release upload "$tag" -R "$repo" "${flags[@]}" "$file"
}

# Resume a draft using the IPA already on GitHub. Rebuilt ZIP timestamps can differ.
if has_asset "$name"; then
    gh release download "$tag" -R "$repo" --pattern "$name" --dir "$work"
else
    upload_missing "${ipas[0]}"
    cp "${ipas[0]}" "$work/$name"
fi
(cd "$work" && sha256sum "$name" > expected)
if has_asset SHA256SUMS; then
    gh release download "$tag" -R "$repo" --pattern SHA256SUMS --dir "$work"
    cmp "$work/expected" "$work/SHA256SUMS"
else
    cp "$work/expected" "$work/SHA256SUMS"
    upload_missing "$work/SHA256SUMS"
fi
if [[ $draft == true ]]; then
    gh release edit "$tag" -R "$repo" --draft=false
fi
gh release view "$tag" -R "$repo" --json url --jq .url
