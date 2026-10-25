#!/usr/bin/env bash
# Bundled auth uses the same lock and archive checks as downloaded server mods.
set -Eeuo pipefail
project=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
source "$project/lib/common.sh"
source "$project/lib/http.sh"
source "$project/lib/catalog.sh"
source "$project/lib/mods.sh"
MSM_CODE_ROOT=$work/package
mkdir -p "$MSM_CODE_ROOT/bundled" "$work/fabric" "$work/neoforge/META-INF"
printf '{"schemaVersion":1,"id":"auth","version":"0.1.0","environment":"server"}\n' > "$work/fabric/fabric.mod.json"
printf 'modLoader="javafml"\n[[mods]]\nmodId="auth"\n' > "$work/neoforge/META-INF/neoforge.mods.toml"
for loader in fabric neoforge; do
    descriptor=fabric.mod.json
    [[ $loader == fabric ]] || descriptor=META-INF/neoforge.mods.toml
    (cd "$work/$loader" && zip -q "$MSM_CODE_ROOT/bundled/auth-$loader-26.3.jar" "$descriptor")
    file=$MSM_CODE_ROOT/bundled/auth-$loader-26.3.jar
    jq -nc --arg loader "$loader" --arg filename "auth-$loader-26.3.jar" --arg sha512 "$(sha512sum "$file" | cut -d' ' -f1)" \
      --argjson size "$(stat -c %s "$file")" '{loader:$loader,filename:$filename,sha512:$sha512,size:$size}' >> "$work/records"
done
jq -ns --slurpfile mods "$work/records" '{schema:1,mc:"26.3",version:"0.1.0",mods:$mods}' > "$MSM_CODE_ROOT/bundled/auth-manifest.json"
cp "$MSM_CODE_ROOT/bundled/auth-manifest.json" "$work/original.json"
mkdir "$work/fabric-api"
printf '{"schemaVersion":1,"id":"fabric-api","version":"0.165.0+26.3","environment":"*"}\n' > "$work/fabric-api/fabric.mod.json"
(cd "$work/fabric-api" && zip -q "$work/fabric-api.jar" fabric.mod.json)
jq -n '{id:"FABRICAPI",slug:"fabric-api",project_type:"mod",server_side:"required"}' > "$work/fabric-api-project.json"
jq -n --arg hash "$(sha512sum "$work/fabric-api.jar" | cut -d' ' -f1)" --argjson size "$(stat -c %s "$work/fabric-api.jar")" \
    '{id:"FAPI1",project_id:"FABRICAPI",version_number:"0.165.0+26.3",version_type:"release",game_versions:["26.3"],loaders:["fabric"],
      environment:"server_only",date_published:"2026-10-01T00:00:00Z",dependencies:[],files:[
      {filename:"fabric-api-fixture.jar",url:"https://cdn.modrinth.com/fabric-api.jar",primary:true,size:$size,hashes:{sha512:$hash}}]}' > "$work/fabric-api-version.json"
jq '.id="FAPI0"|.version_number="0.164.0+26.3"|.date_published="2026-09-01T00:00:00Z"' "$work/fabric-api-version.json" > "$work/fabric-api-pinned.json"
jq -s . "$work/fabric-api-pinned.json" "$work/fabric-api-version.json" > "$work/fabric-api-candidates.json"
msm_get_json() {
    case $1 in
        https://api.modrinth.com/v2/project/fabric-api|https://api.modrinth.com/v2/project/FABRICAPI) cp "$work/fabric-api-project.json" "$2" ;;
        https://api.modrinth.com/v2/project/FABRICAPI/version\?*) cp "$work/fabric-api-candidates.json" "$2" ;;
        https://api.modrinth.com/v2/version/FAPI0) cp "$work/fabric-api-pinned.json" "$2" ;;
        https://api.modrinth.com/v2/version/FAPI1) cp "$work/fabric-api-version.json" "$2" ;;
        *) msm_die "Unexpected bundled-mod fixture metadata lookup: $1" ;;
    esac
}
_msm_fetch() {
    [[ $1 == https://cdn.modrinth.com/fabric-api.jar ]] || msm_die 'Unexpected bundled-mod fixture download.'
    cp "$work/fabric-api.jar" "$2"
}
reject() { if ( "$@" ) > "$work/error" 2>&1; then printf 'Unexpected success: %s\n' "$*" >&2; exit 1; fi; }

for loader in fabric neoforge; do
    jq -n --arg loader "$loader" '{schema:1,loader:$loader,auth:true,mods:[]}' > "$work/template.json"
    msm_resolve_mods "$work/template.json" 26.3 '' "$work/$loader.lock" refresh
    jq -e --arg loader "$loader" '.loader==$loader and
      (.mods|length)==(if $loader=="fabric" then 2 else 1 end) and
      ([.mods[]|select(.source=="bundled" and .project=="msm-auth" and .version==.sha512)]|length)==1' "$work/$loader.lock" > /dev/null
    if [[ $loader == fabric ]]; then
        jq -e '([.mods[]|select(.slug=="fabric-api" and .version=="FAPI1")]|length)==1' "$work/$loader.lock" > /dev/null
    fi
    msm_download_mods "$work/$loader.lock" "$work/download-$loader"
    cmp "$MSM_CODE_ROOT/bundled/auth-$loader-26.3.jar" "$work/download-$loader/auth-$loader-26.3.jar"
    msm_resolve_mods "$work/template.json" 26.3 "$work/$loader.lock" "$work/strict.lock" locked
    cmp "$work/$loader.lock" "$work/strict.lock"
    reject msm_resolve_mods "$work/template.json" 26.4 '' "$work/unsupported.lock" refresh
done
printf 'PASS bundled Fabric/NeoForge resolution, verified staging, strict locks and Minecraft compatibility\n'

jq -n '{schema:1,loader:"fabric",auth:true,mods:[{project:"FABRICAPI",enabled:true,version:"FAPI0"}]}' > "$work/pinned-template.json"
msm_resolve_mods "$work/pinned-template.json" 26.3 '' "$work/pinned.lock" refresh
jq -e '([.mods[]|select(.slug=="fabric-api" and .version=="FAPI0")]|length)==1 and (.mods|length)==2' "$work/pinned.lock" > /dev/null
printf 'PASS Fabric auth adds its API dependency and preserves explicit exact pins\n'

jq '.version="0.2.0"' "$work/original.json" > "$MSM_CODE_ROOT/bundled/auth-manifest.json"
reject msm_resolve_mods "$work/template.json" 26.3 "$work/neoforge.lock" "$work/changed.lock" locked
msm_resolve_mods "$work/template.json" 26.3 "$work/neoforge.lock" "$work/refreshed.lock" refresh
jq -e '.mods[0].version_number=="0.2.0"' "$work/refreshed.lock" > /dev/null
cp "$work/original.json" "$MSM_CODE_ROOT/bundled/auth-manifest.json"
printf 'tampered' >> "$MSM_CODE_ROOT/bundled/auth-neoforge-26.3.jar"
reject msm_download_mods "$work/neoforge.lock" "$work/tampered"
jq '.mods[0].filename="../escape.jar"' "$work/neoforge.lock" > "$work/escape.lock"
reject msm_download_mods "$work/escape.lock" "$work/escape"
jq '.mods[0].source="file"' "$work/neoforge.lock" > "$work/unknown.lock"
reject msm_download_mods "$work/unknown.lock" "$work/unknown"
jq '.mods[0] |= (del(.sha512)|.version=null|.sha1=("a"*40))' "$work/neoforge.lock" > "$work/missing-auth-hash.lock"
reject msm_download_mods "$work/missing-auth-hash.lock" "$work/missing-auth-hash"
jq '.loader="fabric"' "$work/neoforge.lock" > "$work/cross-loader.lock"
reject msm_download_mods "$work/cross-loader.lock" "$work/cross-loader"
printf '{"schemaVersion":1,"id":"different_mod","version":"0.1.0","environment":"server"}\n' > "$work/fabric/fabric.mod.json"
(cd "$work/fabric" && zip -q "$MSM_CODE_ROOT/bundled/auth-fabric-26.3.jar" fabric.mod.json)
file=$MSM_CODE_ROOT/bundled/auth-fabric-26.3.jar
jq --arg sha "$(sha512sum "$file" | cut -d' ' -f1)" --argjson size "$(stat -c %s "$file")" \
  '.mods |= map(if .source=="bundled" then .sha512=$sha | .version=$sha | .size=$size else . end)' "$work/fabric.lock" > "$work/wrong-id.lock"
reject msm_download_mods "$work/wrong-id.lock" "$work/wrong-id"
printf 'PASS changed bundles require refresh; corrupted bytes, path traversal, unknown sources and mismatched mod identities are rejected\n'

jq -n '{schema:1,loader:"vanilla",auth:true,mods:[]}' > "$work/template.json"
reject msm_resolve_mods "$work/template.json" 26.3 '' "$work/vanilla.lock" refresh
jq -n '{schema:1,loader:"fabric",auth:false,mods:[]}' > "$work/template.json"
msm_resolve_mods "$work/template.json" 26.3 '' "$work/disabled.lock" refresh
jq -e '(.mods|length)==0' "$work/disabled.lock" > /dev/null
printf 'PASS auth is optional for modded servers and rejected on Vanilla\n'
