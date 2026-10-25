#!/usr/bin/env bash
set -Eeuo pipefail
export LC_ALL=C
msm_test_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
msm_test_work=$(mktemp -d "$msm_test_root/tests/.network.XXXXXXXX")
trap 'rm -rf -- "$msm_test_work"' EXIT
export TMPDIR=$msm_test_work/tmp
mkdir -p "$TMPDIR" "$msm_test_work/api"
msm_test_count=0
msm_test_loader=${MSM_TEST_LOADER:-neoforge}
[[ $msm_test_loader != vanilla ]] || msm_test_loader=neoforge
[[ $msm_test_loader == neoforge || $msm_test_loader == fabric ]]
msm_log() { printf '%s\n' "$*" >&2; }
msm_die() { msm_log "$*"; exit 1; }
msm_test_pass() { msm_test_count=$((msm_test_count + 1)); printf 'ok %s - %s\n' "$msm_test_count" "$*"; }
msm_expect_failure() { if ( "$@" ) > "$msm_test_work/error.log" 2>&1; then msm_die "Unexpected success: $*"; fi; }
source "$msm_test_root/lib/http.sh"
source "$msm_test_root/lib/catalog.sh"
source "$msm_test_root/lib/mods.sh"

_msm_url_policy 'https://cdn.modrinth.com/a.jar' modrinth
_msm_url_policy 'https://meta.fabricmc.net/v2/versions/installer' fabric
_msm_url_policy 'https://maven.fabricmc.net/net/fabricmc/installer.jar' fabric
_msm_url_policy 'https://github.com/adoptium/temurin25-binaries/releases/download/jdk-25/java.tar.gz' adoptium
for msm_bad in 'http://cdn.modrinth.com/a' 'https://user@cdn.modrinth.com/a' 'https://evil.example/a' 'https://127.0.0.1/a' 'https://cdn.modrinth.com/a#fragment'; do
    msm_expect_failure _msm_url_policy "$msm_bad"
done
msm_expect_failure _msm_url_policy 'https://maven.neoforged.net/a' modrinth
msm_expect_failure _msm_url_policy 'https://maven.fabricmc.net/a' neoforge
msm_test_pass 'HTTPS source, credential and cross-source restrictions'

# A curl fixture exercises the real atomic transfer and checksum logic.
curl() {
    local msm_target=''
    while (( $# )); do if [[ $1 == --output ]]; then msm_target=$2; shift 2; else shift; fi; done
    printf 'new' > "$msm_target"
    printf '200\n'
}
printf 'old' > "$msm_test_work/download.jar"
msm_expect_failure msm_download 'https://cdn.modrinth.com/a.jar' "$msm_test_work/download.jar" sha256 "$(printf '%064d' 0)" 3
[[ $(< "$msm_test_work/download.jar") == old ]] || msm_die 'Failed hash replaced an existing file.'
msm_digest=$(printf new | sha256sum | cut -d' ' -f1)
msm_download 'https://cdn.modrinth.com/a.jar' "$msm_test_work/download.jar" sha256 "$msm_digest" 3
[[ $(< "$msm_test_work/download.jar") == new ]] || msm_die 'Verified download was not published.'
[[ -z $(find "$msm_test_work" -maxdepth 1 -name '*.part.*' -print) ]] || msm_die 'Failed download left temporary files.'
msm_test_pass 'Atomic verified downloads preserve old files on failure'
printf 0 > "$msm_test_work/curl-count"
curl() {
    local msm_count
    msm_count=$(< "$msm_test_work/curl-count"); printf '%s' "$((msm_count + 1))" > "$msm_test_work/curl-count"
    printf '500\n'; return 23
}
msm_expect_failure msm_get_json 'https://api.modrinth.com/v2/project/test' "$msm_test_work/disk.json"
[[ $(< "$msm_test_work/curl-count") == 1 ]] || msm_die 'A curl disk-write error was retried.'
msm_test_pass 'Disk write failures are not network retries'
unset -f curl

[[ $(_msm_neoforge_prefix 1.21) == 21.0. && $(_msm_neoforge_prefix 1.21.1) == 21.1. &&
   $(_msm_neoforge_prefix 26.3) == 26.3.0. && $(_msm_neoforge_prefix 26.1.2) == 26.1.2. ]] || msm_die 'NeoForge prefix mapping failed.'
msm_expect_failure _msm_neoforge_prefix 1.20.1
msm_test_pass 'NeoForge legacy and 26.x numbering'

jq -n '{id:"26.3",type:"release",releaseTime:"2026-09-01T12:00:00Z",javaVersion:{majorVersion:25},downloads:{server:{url:"https://piston-data.mojang.com/server.jar",sha1:("c"*40),size:123}}}' > "$msm_test_work/mc.json"
msm_digest=$(sha1sum "$msm_test_work/mc.json" | cut -d' ' -f1)
jq -n --arg hash "$msm_digest" '{latest:{release:"26.3"},versions:[{id:"26.3",type:"release",url:"https://piston-meta.mojang.com/test.json",sha1:$hash}]}' > "$msm_test_work/manifest.json"
printf '%s\n' '<metadata><groupId>net.neoforged</groupId><artifactId>neoforge</artifactId><versioning><versions><version>26.3.0.9</version><version>26.3.0.97</version><version>26.3.0.99-beta</version><version>26x3y0z999</version><version>26.3.1.4</version></versions></versioning></metadata>' > "$msm_test_work/neo.xml"
jq -n '{"version":{major:25},release_name:"jdk-25.0.5+8",binary:{architecture:"x64",os:"linux",image_type:"jdk",jvm_impl:"hotspot",package:{link:"https://github.com/adoptium/temurin25-binaries/releases/download/jdk-25/java.tar.gz",checksum:("d"*64),size:123}}} | [.]' > "$msm_test_work/java.json"
_msm_fetch() {
    case $1 in
        *version_manifest_v2.json) cp "$msm_test_work/manifest.json" "$2";;
        *piston-meta.mojang.com/test.json) cp "$msm_test_work/mc.json" "$2";;
        *maven-metadata.xml) cp "$msm_test_work/neo.xml" "$2";;
        *.jar.sha256) printf '%064d\n' 1 > "$2";;
        *meta.fabricmc.net/v2/versions/loader/26.3) printf '%s\n' '[{"loader":{"version":"0.19.5","stable":true}},{"loader":{"version":"0.19.9","stable":true}},{"loader":{"version":"0.20.0","stable":false}}]' > "$2";;
        *meta.fabricmc.net/v2/versions/installer) printf '%s\n' '[{"version":"1.9.0","stable":true},{"version":"1.10.0","stable":true},{"version":"2.0.0","stable":false}]' > "$2";;
        *api.adoptium.net*image_type=jre*) return 44;;
        *api.adoptium.net*image_type=jdk*) cp "$msm_test_work/java.json" "$2";;
        *) msm_log "Unknown runtime fixture URL: $1"; return 1;;
    esac
}
# The XML CLI is an injected adapter when unavailable in the test workspace.
if ! command -v xmlstarlet >/dev/null; then
    xmlstarlet() {
        case " $* " in
            *'/metadata/groupId'*) printf net.neoforged;;
            *'/metadata/artifactId'*) printf neoforge;;
            *) grep -oE '<version>[^<]+</version>' "${!#}" | sed -e 's/<version>//' -e 's#</version>##';;
        esac
    }
fi
msm_resolve_runtime latest latest "$msm_test_work/runtime.json" neoforge
jq -e '.mc=="26.3" and .neoforge=="26.3.0.97" and .java_major==25 and .java.release_name=="jdk-25.0.5+8" and .unix_args=="libraries/net/neoforged/neoforge/26.3.0.97/unix_args.txt"' "$msm_test_work/runtime.json" >/dev/null
msm_expect_failure msm_resolve_runtime 26.3 26.3.0.99-beta "$msm_test_work/bad-runtime.json" neoforge
msm_test_pass 'Catalog selects only the matching stable release and same-major JDK fallback'
msm_resolve_runtime '' latest "$msm_test_work/default-runtime.json"
jq -e '.mc=="26.3" and .loader=="vanilla" and .launch_jar=="server.jar" and .installer==null' "$msm_test_work/default-runtime.json" >/dev/null
msm_resolve_runtime latest latest "$msm_test_work/fabric-runtime.json" fabric
jq -e '.mc=="26.3" and .loader=="fabric" and .fabric=="0.19.9" and .fabric_installer=="1.10.0" and .java_major==25 and .launch_jar=="fabric-server-launch.jar" and .installer.url=="https://maven.fabricmc.net/net/fabricmc/fabric-installer/1.10.0/fabric-installer-1.10.0.jar"' "$msm_test_work/fabric-runtime.json" >/dev/null
msm_expect_failure msm_resolve_runtime latest 0.20.0 "$msm_test_work/beta-fabric.json" fabric
msm_expect_failure msm_resolve_runtime latest latest "$msm_test_work/unknown-loader.json" forge
msm_test_pass 'Default Minecraft tracks latest release and Fabric selects compatible stable loader and installer'
mkdir -p "$msm_test_work/installer-fixture/data"
printf '{"minecraft":"26.3","version":"neoforge-26.3.0.97"}\n' > "$msm_test_work/installer-fixture/install_profile.json"
printf '{"inheritsFrom":"26.3","id":"neoforge-26.3.0.97"}\n' > "$msm_test_work/installer-fixture/version.json"
printf 'fixture\n' > "$msm_test_work/installer-fixture/data/unix_args.txt"
(cd "$msm_test_work/installer-fixture" && zip -q "$msm_test_work/installer.jar" install_profile.json version.json data/unix_args.txt)
msm_verify_installer "$msm_test_work/installer.jar" 26.3 26.3.0.97
msm_expect_failure msm_verify_installer "$msm_test_work/installer.jar" 1.21.1 26.3.0.97
msm_test_pass 'Installer embedded Minecraft and loader identities are verified'
mkdir -p "$msm_test_work/fabric-installer-fixture/META-INF"
printf 'Manifest-Version: 1.0\nMain-Class: net.fabricmc.installer.Main\n\n' > "$msm_test_work/fabric-installer-fixture/META-INF/MANIFEST.MF"
(cd "$msm_test_work/fabric-installer-fixture" && zip -q "$msm_test_work/fabric-installer.jar" META-INF/MANIFEST.MF)
msm_verify_fabric_installer "$msm_test_work/fabric-installer.jar"
msm_expect_failure msm_verify_fabric_installer "$msm_test_work/installer.jar"
msm_test_pass 'Fabric installers require the expected executable manifest'
jq -n '{schema:1,loader:"vanilla",mods:[]}' > "$msm_test_work/vanilla-mods.json"
msm_resolve_mods "$msm_test_work/vanilla-mods.json" 26.3 '' "$msm_test_work/vanilla-lock.json" refresh
jq -e '.loader=="vanilla" and (.mods|length)==0' "$msm_test_work/vanilla-lock.json" >/dev/null
msm_download_mods "$msm_test_work/vanilla-lock.json" "$msm_test_work/vanilla-mods"
jq '.mods=[{project:"lithium",enabled:true,version:null}]' "$msm_test_work/vanilla-mods.json" > "$msm_test_work/invalid-vanilla.json"
msm_expect_failure msm_resolve_mods "$msm_test_work/invalid-vanilla.json" 26.3 '' "$msm_test_work/bad-vanilla-lock.json" refresh
msm_test_pass 'Vanilla creates an empty mod lock and rejects mod templates'

msm_fixture_version() {
    jq -n --arg loader "$msm_test_loader" --arg p "$1" --arg v "$2" --arg date "$3" --argjson deps "$4" '{id:$v,"project_id":$p,version_number:$v,version_type:"release",game_versions:["1.21.1"],loaders:[$loader],environment:"server_only",date_published:$date,dependencies:$deps,files:[{filename:($p+"-"+$v+".jar"),url:("https://cdn.modrinth.com/"+$v+".jar"),primary:true,size:1,hashes:{sha512:("a"*128)}}]}' > "$msm_test_work/api/$2.json"
}
msm_fixture_version A A1 2026-01-01T00:00:00Z '[]'
msm_fixture_version A A2 2026-01-02T00:00:00Z '[]'
msm_fixture_version B B1 2026-01-01T00:00:00Z '[{"project_id":"A","version_id":"A1","dependency_type":"required"}]'
msm_get_json() {
    local msm_path=${1#https://api.modrinth.com/v2/} msm_key
    case $msm_path in
        project/*/version\?*) msm_key=${msm_path#project/}; msm_key=${msm_key%%/*}; jq -s --arg p "$msm_key" '[.[]|select(.project_id==$p)]' "$msm_test_work/api/"*.json > "$2";;
        project/*) msm_key=${msm_path#project/}; msm_key=${msm_key^^}; jq -n --arg p "$msm_key" '{id:$p,slug:($p|ascii_downcase),project_type:"mod",server_side:"unknown"}' > "$2";;
        version/*) msm_key=${msm_path#version/}; [[ -f $msm_test_work/api/$msm_key.json ]] || return 1; cp "$msm_test_work/api/$msm_key.json" "$2";;
        *) return 1;;
    esac
}
msm_template() { jq -n --arg loader "$msm_test_loader" --argjson mods "$1" '{schema:1,loader:$loader,mods:$mods}' > "$msm_test_work/mods.json"; }
msm_template '[{"project":"b","enabled":true,"version":null}]'
msm_resolve_mods "$msm_test_work/mods.json" 1.21.1 '' "$msm_test_work/lock.json" refresh
jq -e '[.mods[].version]==["A1","B1"] and .roots[0].project=="B"' "$msm_test_work/lock.json" >/dev/null
msm_test_pass 'Required exact dependencies and canonical project IDs'
msm_template '[{"project":"A","enabled":true,"version":"A2"},{"project":"B","enabled":true,"version":null}]'
msm_expect_failure msm_resolve_mods "$msm_test_work/mods.json" 1.21.1 '' "$msm_test_work/conflict.json" refresh
msm_test_pass 'Later dependencies cannot overwrite explicit root pins'
msm_template '[{"project":"A","enabled":true,"version":null}]'
msm_resolve_mods "$msm_test_work/mods.json" 1.21.1 "$msm_test_work/lock.json" "$msm_test_work/strict.json" locked
jq -e '.mods[0].version=="A1"' "$msm_test_work/strict.json" >/dev/null
msm_resolve_mods "$msm_test_work/mods.json" 1.21.1 "$msm_test_work/lock.json" "$msm_test_work/refreshed.json" refresh
jq -e '.mods[0].version=="A2"' "$msm_test_work/refreshed.json" >/dev/null
msm_expect_failure msm_resolve_mods "$msm_test_work/mods.json" 1.21.1 '' "$msm_test_work/missing.json" locked
jq '.mods[0].sha512=("0"*128)' "$msm_test_work/lock.json" > "$msm_test_work/tampered.json"
msm_expect_failure msm_resolve_mods "$msm_test_work/mods.json" 1.21.1 "$msm_test_work/tampered.json" "$msm_test_work/changed.json" locked
msm_test_pass 'Strict locks prevent missing-project and checksum drift'
jq --arg loader "$(if [[ $msm_test_loader == fabric ]]; then printf neoforge; else printf fabric; fi)" '.loader=$loader' "$msm_test_work/lock.json" > "$msm_test_work/foreign-lock.json"
msm_expect_failure msm_resolve_mods "$msm_test_work/mods.json" 1.21.1 "$msm_test_work/foreign-lock.json" "$msm_test_work/cross-loader-lock.json" locked
msm_test_pass 'Strict locks reject a different loader'
msm_fixture_version A A1 2026-01-01T00:00:00Z '[{"project_id":"B","version_id":"B1","dependency_type":"required"}]'
msm_template '[{"project":"A","enabled":true,"version":"A1"}]'
msm_resolve_mods "$msm_test_work/mods.json" 1.21.1 '' "$msm_test_work/cycle.json" refresh
jq -e '.mods|length==2' "$msm_test_work/cycle.json" >/dev/null
msm_test_pass 'Exact dependency cycles terminate without duplication'
msm_fixture_version A A1 2026-01-01T00:00:00Z '[{"project_id":"B","version_id":null,"dependency_type":"incompatible"}]'
msm_template '[{"project":"A","enabled":true,"version":"A1"},{"project":"B","enabled":true,"version":null}]'
msm_expect_failure msm_resolve_mods "$msm_test_work/mods.json" 1.21.1 '' "$msm_test_work/incompatible.json" refresh
msm_test_pass 'Incompatible dependency declarations reject the selected set'
msm_template '[{"project":"A","enabled":true,"version":"A1"}]'
msm_fixture_version A A1 2026-01-01T00:00:00Z '[]'
jq '.environment="client_only"' "$msm_test_work/api/A1.json" > "$msm_test_work/client.json"
mv "$msm_test_work/client.json" "$msm_test_work/api/A1.json"
msm_expect_failure msm_resolve_mods "$msm_test_work/mods.json" 1.21.1 '' "$msm_test_work/client-lock.json" refresh
msm_fixture_version A A1 2026-01-01T00:00:00Z '[]'
jq '.loaders=["fabric","neoforge"]' "$msm_test_work/api/A1.json" > "$msm_test_work/mixed.json"
mv "$msm_test_work/mixed.json" "$msm_test_work/api/A1.json"
msm_resolve_mods "$msm_test_work/mods.json" 1.21.1 '' "$msm_test_work/mixed-lock.json" refresh
msm_test_pass 'Version server environment wins over unknown legacy fields'
msm_foreign=fabric
[[ $msm_test_loader != fabric ]] || msm_foreign=neoforge
for msm_filter in '.version_type="beta"' ".loaders=[\"$msm_foreign\"]"; do
    msm_fixture_version A A1 2026-01-01T00:00:00Z '[]'
    jq "$msm_filter" "$msm_test_work/api/A1.json" > "$msm_test_work/filtered.json"
    mv "$msm_test_work/filtered.json" "$msm_test_work/api/A1.json"
    msm_expect_failure msm_resolve_mods "$msm_test_work/mods.json" 1.21.1 '' "$msm_test_work/filtered-lock.json" refresh
done
msm_test_pass 'Beta versions and foreign-only loaders are rejected'
msm_fixture_version A A1 2026-01-01T00:00:00Z '[{"project_id":"B","dependency_type":"required"}]'
jq '.mods |= map(select(.project=="A"))' "$msm_test_work/lock.json" > "$msm_test_work/incomplete-lock.json"
msm_expect_failure msm_resolve_mods "$msm_test_work/mods.json" 1.21.1 "$msm_test_work/incomplete-lock.json" "$msm_test_work/new-dependency.json" locked
msm_test_pass 'Strict mode cannot silently add an unlocked dependency'
mkdir -p "$msm_test_work/mod-fixture/META-INF"
if [[ $msm_test_loader == fabric ]]; then
    printf '{"schemaVersion":1,"id":"fixture","version":"1.0.0","environment":"server"}\n' > "$msm_test_work/mod-fixture/fabric.mod.json"
    (cd "$msm_test_work/mod-fixture" && zip -q "$msm_test_work/mod.jar" fabric.mod.json)
else
    printf 'modLoader="javafml"\n' > "$msm_test_work/mod-fixture/META-INF/neoforge.mods.toml"
    (cd "$msm_test_work/mod-fixture" && zip -q "$msm_test_work/mod.jar" META-INF/neoforge.mods.toml)
fi
_msm_fetch() { cp -- "$msm_test_work/mod.jar" "$2"; }
msm_digest=$(sha512sum "$msm_test_work/mod.jar" | cut -d' ' -f1)
jq --arg sha "$msm_digest" --argjson size "$(stat -c %s "$msm_test_work/mod.jar")" '.mods[0].sha512=$sha | .mods[0].size=$size' "$msm_test_work/mixed-lock.json" > "$msm_test_work/download-lock.json"
msm_download_mods "$msm_test_work/download-lock.json" "$msm_test_work/downloaded-mods"
[[ -f $msm_test_work/downloaded-mods/A-A1.jar ]] || msm_die 'Mod JAR was not installed into the staging destination.'
cp -- "$msm_test_work/installer.jar" "$msm_test_work/mod.jar"
msm_digest=$(sha512sum "$msm_test_work/mod.jar" | cut -d' ' -f1)
jq --arg sha "$msm_digest" --argjson size "$(stat -c %s "$msm_test_work/mod.jar")" '.mods[0].sha512=$sha | .mods[0].size=$size' "$msm_test_work/mixed-lock.json" > "$msm_test_work/no-descriptor-lock.json"
msm_expect_failure msm_download_mods "$msm_test_work/no-descriptor-lock.json" "$msm_test_work/no-descriptor"
msm_test_pass "Downloaded mod JARs require a verified archive and $msm_test_loader descriptor"

# Cover Fabric's different descriptor format once, without repeating the suite.
msm_test_loader=fabric
msm_fixture_version A A1 2026-01-01T00:00:00Z '[]'
msm_template '[{"project":"A","enabled":true,"version":"A1"}]'
msm_resolve_mods "$msm_test_work/mods.json" 1.21.1 '' "$msm_test_work/fabric-lock.json" refresh
jq -e '.loader=="fabric" and .mods[0].version=="A1"' "$msm_test_work/fabric-lock.json" >/dev/null
printf '{"schemaVersion":1,"id":"fixture","version":"1.0.0","environment":"server"}\n' > "$msm_test_work/mod-fixture/fabric.mod.json"
(cd "$msm_test_work/mod-fixture" && zip -q "$msm_test_work/fabric-mod.jar" fabric.mod.json)
cp "$msm_test_work/fabric-mod.jar" "$msm_test_work/mod.jar"
msm_digest=$(sha512sum "$msm_test_work/mod.jar" | cut -d' ' -f1)
jq --arg sha "$msm_digest" --argjson size "$(stat -c %s "$msm_test_work/mod.jar")" '.mods[0].sha512=$sha | .mods[0].size=$size' "$msm_test_work/fabric-lock.json" > "$msm_test_work/fabric-download-lock.json"
msm_download_mods "$msm_test_work/fabric-download-lock.json" "$msm_test_work/fabric-downloaded"
msm_test_pass 'Fabric resolution and verified fabric.mod.json download'
printf 'PASS: %s network and resolver fixture tests\n' "$msm_test_count"
