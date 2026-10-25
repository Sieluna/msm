#!/usr/bin/env bash
# Real release packaging and bootstrap, with isolated downloads/install targets.
set -Eeuo pipefail
project=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
version=$(sed -n 's/^MSM_VERSION=//p' "$project/lib/common.sh")
mkdir -p "$work/auth-fixture/input" "$work/auth-fixture/dist"
printf '{"id":"auth","environment":"server"}\n' > "$work/auth-fixture/input/fabric.mod.json"
mkdir "$work/auth-fixture/input/META-INF"
printf 'modLoader="javafml"\n' > "$work/auth-fixture/input/META-INF/neoforge.mods.toml"
for loader in fabric neoforge; do
    (cd "$work/auth-fixture/input" && zip -q "$work/auth-fixture/dist/auth-$loader-26.3.jar" fabric.mod.json META-INF/neoforge.mods.toml)
done
jq -n --arg fabric_hash "$(sha512sum "$work/auth-fixture/dist/auth-fabric-26.3.jar" | cut -d' ' -f1)" \
    --arg neo_hash "$(sha512sum "$work/auth-fixture/dist/auth-neoforge-26.3.jar" | cut -d' ' -f1)" \
    --argjson size "$(stat -c %s "$work/auth-fixture/dist/auth-fabric-26.3.jar")" \
    '{schema:1,mc:"26.3",version:"0.1.0",mods:[
      {loader:"fabric",filename:"auth-fabric-26.3.jar",size:$size,sha512:$fabric_hash},
      {loader:"neoforge",filename:"auth-neoforge-26.3.jar",size:$size,sha512:$neo_hash}]}' > "$work/auth-fixture/dist/auth-manifest.json"
bash "$project/.github/scripts/package.sh" "$work/dist" "$work/auth-fixture/dist"
(cd "$work/dist" && sha256sum --check SHA256SUMS)
tar -tzf "$work/dist/msm-$version.tar.gz" > "$work/members"
if grep -Eq '/(tests|docs|\.github|auth|\.gradle|build)/|/(TEST-RESULTS.txt|VALIDATION.txt|SHA256SUMS|gradlew)$' "$work/members"; then
    printf 'Non-runtime files found in release.\n' >&2; exit 1
fi
mkdir "$work/actual"
tar -xzf "$work/dist/msm-$version.tar.gz" -C "$work/actual"
for file in auth-manifest.json auth-fabric-26.3.jar auth-neoforge-26.3.jar; do
    cmp "$work/actual/msm-$version/bundled/$file" "$work/dist/$file"
done
[[ $(wc -l < "$work/dist/SHA256SUMS") == 5 ]]
[[ $(bash "$work/actual/msm-$version/bin/msm" --version) == "$version" ]]
bash "$work/actual/msm-$version/bin/msm" --help > /dev/null
bash "$work/actual/msm-$version/install.sh" --help > /dev/null
bash "$work/dist/install.sh" --help > /dev/null
printf 'PASS release payload, checksums, version and help\n'

printf damaged >> "$work/auth-fixture/dist/auth-fabric-26.3.jar"
if bash "$project/.github/scripts/package.sh" "$work/invalid-dist" "$work/auth-fixture/dist" > "$work/package-error" 2>&1; then
    printf 'Packaging accepted a changed auth artifact.\n' >&2; exit 1
fi
[[ ! -e $work/invalid-dist/msm-$version.tar.gz ]]
printf 'PASS bundled auth integrity and runtime-only packaging\n'

# Substitute only the installed operation; exercise the real download/hash/extract flow.
mkdir -p "$work/fixture/msm-$version"
cat > "$work/fixture/msm-$version/install.sh" <<'FIXTURE'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$MSM_TEST_RECEIPT"
FIXTURE
tar -czf "$work/fixture.tar.gz" -C "$work/fixture" "msm-$version"
digest=$(sha256sum "$work/fixture.tar.gz" | cut -d' ' -f1)
sed -e "s/@MSM_VERSION@/$version/g" -e "s/@MSM_SHA256@/$digest/g" \
    "$project/.github/scripts/bootstrap.sh" > "$work/bootstrap.sh"
export MSM_TEST_ARCHIVE=$work/fixture.tar.gz MSM_TEST_RECEIPT=$work/receipt
export MSM_TEST_VERSION=$version MSM_TEST_MODE=success
wget() {
    [[ ${!#} == "https://github.com/Sieluna/msm/releases/download/latest/msm-$MSM_TEST_VERSION.tar.gz" ]] || return 90
    local destination=
    while (( $# )); do
        if [[ $1 == -qO ]]; then destination=$2; shift 2; else shift; fi
    done
    case $MSM_TEST_MODE in
        fail) return 8 ;;
        corrupt) printf 'damaged archive' > "$destination" ;;
        success) cp -- "$MSM_TEST_ARCHIVE" "$destination" ;;
    esac
}
export -f wget
if bash "$work/bootstrap.sh" > "$work/error" 2>&1; then
    printf 'Installer accepted a missing EULA flag.\n' >&2; exit 1
fi
[[ ! -e $MSM_TEST_RECEIPT ]]
bash "$work/bootstrap.sh" --accept-eula --version 1.21.1 --no-start
printf '%s\n' --accept-eula --version 1.21.1 --no-start > "$work/expected"
cmp "$work/expected" "$MSM_TEST_RECEIPT"
rm -- "$MSM_TEST_RECEIPT"
for MSM_TEST_MODE in corrupt fail; do
    export MSM_TEST_MODE
    if bash "$work/bootstrap.sh" --accept-eula > "$work/error" 2>&1; then
        printf 'Installer accepted %s download.\n' "$MSM_TEST_MODE" >&2; exit 1
    fi
    [[ ! -e $MSM_TEST_RECEIPT ]]
done
printf 'PASS bootstrap arguments, EULA guard, checksum rejection and download failure\n'

# The rolling publisher must not mutate releases for a superseded commit.
export GH_REPO=Sieluna/msm RELEASE_COMMIT=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
export MSM_TEST_GH_LOG=$work/gh-calls MSM_TEST_PUBLISH=existing
gh() {
    printf '%s\n' "$*" >> "$MSM_TEST_GH_LOG"
    case "$*" in
        'api repos/Sieluna/msm/git/ref/heads/master --jq .object.sha')
            if [[ $MSM_TEST_PUBLISH == stale ]]; then printf '%040d\n' 0; else printf '%s\n' "$RELEASE_COMMIT"; fi ;;
        'api repos/Sieluna/msm/git/ref/tags/latest --silent') [[ $MSM_TEST_PUBLISH != new ]] ;;
        'release view latest --repo Sieluna/msm') [[ $MSM_TEST_PUBLISH != new ]] ;;
        'api repos/Sieluna/msm/releases/tags/latest --jq '*) printf '101\told-build.tar.gz\n102\tinstall.sh\n103\tauth-fabric-26.3.jar\n104\tauth-neoforge-26.3.jar\n105\tauth-manifest.json\n' ;;
        'api repos/Sieluna/msm/releases --paginate --jq '*) printf '201\n202\n' ;;
        'api --method PATCH '*|'api --method POST '*|'api --method DELETE '*|'release upload '*|'release edit '*|'release create '*) ;;
        *) printf 'Unexpected gh fixture command: %s\n' "$*" >&2; return 99 ;;
    esac
}
export -f gh
cp "$work/dist/SHA256SUMS" "$work/complete-checksums"
grep -v 'auth-fabric-26.3.jar' "$work/complete-checksums" > "$work/dist/SHA256SUMS"
: > "$MSM_TEST_GH_LOG"
if bash "$project/.github/scripts/publish-release.sh" "$work/dist" > "$work/publish-error" 2>&1; then
    printf 'Publisher accepted incomplete auth checksums.\n' >&2; exit 1
fi
[[ ! -s $MSM_TEST_GH_LOG ]]
cp "$work/complete-checksums" "$work/dist/SHA256SUMS"
for MSM_TEST_PUBLISH in existing new stale; do
    export MSM_TEST_PUBLISH
    : > "$MSM_TEST_GH_LOG"
    bash "$project/.github/scripts/publish-release.sh" "$work/dist" > "$work/publish-output"
    if [[ $MSM_TEST_PUBLISH == stale ]]; then
        [[ $(wc -l < "$MSM_TEST_GH_LOG") == 1 ]]
    else
        grep -Fq 'api --method DELETE repos/Sieluna/msm/releases/assets/101 --silent' "$MSM_TEST_GH_LOG"
        ! grep -Fq 'releases/assets/102' "$MSM_TEST_GH_LOG"
        ! grep -Eq 'releases/assets/10[345]' "$MSM_TEST_GH_LOG"
        grep -Fq 'api --method DELETE repos/Sieluna/msm/releases/201 --silent' "$MSM_TEST_GH_LOG"
        grep -Fq 'api --method DELETE repos/Sieluna/msm/releases/202 --silent' "$MSM_TEST_GH_LOG"
        if [[ $MSM_TEST_PUBLISH == existing ]]; then
            grep -Fq 'release upload latest ' "$MSM_TEST_GH_LOG"
            grep -Fq 'api --method PATCH repos/Sieluna/msm/git/refs/tags/latest ' "$MSM_TEST_GH_LOG"
            ! grep -Fq 'release create ' "$MSM_TEST_GH_LOG"
        else
            grep -Fq 'release create latest ' "$MSM_TEST_GH_LOG"
            grep -Fq 'api --method POST repos/Sieluna/msm/git/refs ' "$MSM_TEST_GH_LOG"
            ! grep -Fq 'release upload ' "$MSM_TEST_GH_LOG"
        fi
        grep -Fq "$work/dist/auth-fabric-26.3.jar" "$MSM_TEST_GH_LOG"
        grep -Fq "$work/dist/auth-neoforge-26.3.jar" "$MSM_TEST_GH_LOG"
    fi
done
printf 'PASS rolling release create/update, old-release cleanup and stale-commit guard\n'
