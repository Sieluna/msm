#!/usr/bin/env bash
# Publish one rolling release after the master-branch test matrix passes.
set -Eeuo pipefail
export LC_ALL=C
project=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)
version=$(sed -n 's/^MSM_VERSION=//p' "$project/lib/common.sh")
repository=${GH_REPO:?GH_REPO must identify the target repository}
commit=${RELEASE_COMMIT:?RELEASE_COMMIT must identify the tested commit}
distribution=${1:?Usage: publish-release.sh DISTRIBUTION_DIRECTORY}
[[ $repository =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ && $commit =~ ^[0-9a-f]{40}$ ]]
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
for file in install.sh SHA256SUMS "msm-$version.tar.gz" auth-manifest.json; do
    [[ -s $distribution/$file && ! -L $distribution/$file ]]
done
jq -e '.schema==1 and (.mc|type=="string" and test("^[0-9]+\\.[0-9]+(\\.[0-9]+)?$")) and
    (.version|type=="string" and test("^[0-9]+\\.[0-9]+\\.[0-9]+$")) and
    (.mods|type=="array" and length==2) and ([.mods[].loader]|sort)==["fabric","neoforge"] and
    (.mc as $mc | all(.mods[]; .filename==("auth-"+.loader+"-"+$mc+".jar")))' "$distribution/auth-manifest.json" >/dev/null
assets=("msm-$version.tar.gz" SHA256SUMS auth-manifest.json)
while IFS= read -r file; do
    [[ -s $distribution/$file && ! -L $distribution/$file ]]
    assets+=("$file")
done < <(jq -r '.mods[].filename' "$distribution/auth-manifest.json")
checksum_names=$(awk '{sub(/^[*]/,"",$2); print $2}' "$distribution/SHA256SUMS" | sort)
expected_names=$(printf '%s\n' "msm-$version.tar.gz" install.sh auth-manifest.json "${assets[@]:3}" | sort)
[[ $checksum_names == "$expected_names" ]] || { printf 'Release checksum manifest is incomplete.\n' >&2; exit 1; }
(cd -- "$distribution" && sha256sum --check SHA256SUMS)
head=$(gh api "repos/$repository/git/ref/heads/master" --jq '.object.sha')
if [[ $head != "$commit" ]]; then
    printf 'Skipping an older commit; master has advanced.\n'
    exit 0
fi
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
printf 'Tested source: https://github.com/%s/commit/%s\n\n' "$repository" "$commit" > "$work/notes"
printf 'Automatically published after regression, auth storage and Vanilla/Fabric/NeoForge integration tests passed.\n' >> "$work/notes"
printf 'MSM version: %s. The latest assets replace the previous build.\n' "$version" >> "$work/notes"
printf 'Auth version: %s for Minecraft %s; Fabric and NeoForge artifacts are bundled and available separately.\n' \
    "$(jq -r .version "$distribution/auth-manifest.json")" "$(jq -r .mc "$distribution/auth-manifest.json")" >> "$work/notes"

# GitHub Releases require a tag. CI owns this single moving reference.
if gh api "repos/$repository/git/ref/tags/latest" --silent 2>/dev/null; then
    gh api --method PATCH "repos/$repository/git/refs/tags/latest" -f sha="$commit" -F force=true --silent
else
    gh api --method POST "repos/$repository/git/refs" -f ref=refs/tags/latest -f sha="$commit" --silent
fi
if gh release view latest --repo "$repository" >/dev/null 2>&1; then
    uploads=()
    for file in "${assets[@]}"; do uploads+=("$distribution/$file"); done
    gh release upload latest "${uploads[@]}" --clobber --repo "$repository"
    gh release upload latest "$distribution/install.sh" --clobber --repo "$repository"
    gh release edit latest --title 'Latest' --notes-file "$work/notes" --draft=false --prerelease=false --latest --repo "$repository"
else
    uploads=("$distribution/install.sh")
    for file in "${assets[@]}"; do uploads+=("$distribution/$file"); done
    gh release create latest "${uploads[@]}" --verify-tag --title 'Latest' --notes-file "$work/notes" --latest --repo "$repository"
fi

# Remove old build assets and any other releases, including historical drafts.
gh api "repos/$repository/releases/tags/latest" --jq '.assets[] | [.id,.name] | @tsv' > "$work/assets"
while IFS=$'\t' read -r id name; do
    keep=false
    for file in install.sh "${assets[@]}"; do [[ $name != "$file" ]] || keep=true; done
    [[ $keep == false ]] || continue
    [[ $id =~ ^[0-9]+$ ]]
    gh api --method DELETE "repos/$repository/releases/assets/$id" --silent
done < "$work/assets"
gh api "repos/$repository/releases" --paginate --jq '.[] | select(.tag_name != "latest") | .id' > "$work/releases"
while IFS= read -r id; do
    [[ $id =~ ^[0-9]+$ ]]
    gh api --method DELETE "repos/$repository/releases/$id" --silent
done < "$work/releases"
