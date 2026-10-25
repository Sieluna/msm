#!/usr/bin/env bash
set -Eeuo pipefail
export LC_ALL=C
project=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)
version=$(sed -n 's/^MSM_VERSION=//p' "$project/lib/common.sh")
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { printf 'Invalid MSM_VERSION.\n' >&2; exit 1; }
output=${1:?Usage: package.sh OUTPUT_DIRECTORY [AUTH_DISTRIBUTION]}
auth=${2:-$project/auth/dist}
[[ -d $auth && ! -L $auth && -f $auth/auth-manifest.json && ! -L $auth/auth-manifest.json ]] || {
    printf 'Build the auth distribution before packaging.\n' >&2; exit 1;
}
jq -e '.schema==1 and (.mc|type=="string" and test("^[0-9]+\\.[0-9]+(\\.[0-9]+)?$")) and
    (.version|type=="string" and test("^[0-9]+\\.[0-9]+\\.[0-9]+$")) and
    (.mods|type=="array" and length==2) and ([.mods[].loader]|sort)==["fabric","neoforge"] and
    (.mc as $mc | all(.mods[]; .filename==("auth-"+.loader+"-"+$mc+".jar") and
        (.size|type=="number" and floor==. and .>0 and .<=134217728) and
        (.sha512|type=="string" and test("^[0-9a-f]{128}$"))))' "$auth/auth-manifest.json" >/dev/null || {
    printf 'Invalid auth distribution manifest.\n' >&2; exit 1;
}
auth_files=()
while IFS=$'\t' read -r name size hash; do
    [[ -f $auth/$name && ! -L $auth/$name && $(stat -c %s "$auth/$name") == "$size" ]] || {
        printf 'Missing or invalid auth artifact: %s\n' "$name" >&2; exit 1;
    }
    [[ $(sha512sum "$auth/$name" | cut -d' ' -f1) == "$hash" ]] || {
        printf 'Auth artifact checksum mismatch: %s\n' "$name" >&2; exit 1;
    }
    unzip -tqq "$auth/$name" >/dev/null || { printf 'Invalid auth JAR: %s\n' "$name" >&2; exit 1; }
    auth_files+=("$name")
done < <(jq -r '.mods[]|[.filename,.size,.sha512]|@tsv' "$auth/auth-manifest.json")
mkdir -p -- "$output"
output=$(cd -- "$output" && pwd -P)
[[ ! -e $output/msm-$version.tar.gz && ! -e $output/install.sh && ! -e $output/SHA256SUMS ]] || {
    printf 'Release output already exists.\n' >&2; exit 1;
}
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
mkdir "$work/msm-$version"
cp -a -- "$project/bin" "$project/lib" "$project/libexec" "$project/systemd" \
    "$project/templates" "$project/install.sh" "$project/README.md" "$work/msm-$version/"
mkdir "$work/msm-$version/bundled"
for name in auth-manifest.json "${auth_files[@]}"; do
    [[ ! -e $output/$name && ! -L $output/$name ]] || { printf 'Release asset already exists: %s\n' "$name" >&2; exit 1; }
    cp -- "$auth/$name" "$work/msm-$version/bundled/$name"
    cp -- "$auth/$name" "$output/$name"
done
epoch=$(git -C "$project" log -1 --format=%ct)
tar --sort=name --mtime="@$epoch" --owner=0 --group=0 --numeric-owner \
    -czf "$output/msm-$version.tar.gz" -C "$work" "msm-$version"
digest=$(sha256sum "$output/msm-$version.tar.gz" | cut -d' ' -f1)
sed -e "s/@MSM_VERSION@/$version/g" -e "s/@MSM_SHA256@/$digest/g" \
    "$project/.github/scripts/bootstrap.sh" > "$output/install.sh"
chmod 755 "$output/install.sh"
(cd -- "$output" && sha256sum "msm-$version.tar.gz" install.sh auth-manifest.json "${auth_files[@]}" > SHA256SUMS)
printf 'Packaged msm %s in %s\n' "$version" "$output"
