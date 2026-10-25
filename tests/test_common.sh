#!/usr/bin/env bash
set -Eeuo pipefail
export LC_ALL=C
test_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
source "$test_root/lib/common.sh"
test_work=$(mktemp -d "$test_root/.test-common.XXXXXXXX")
trap 'rm -rf -- "$test_work"' EXIT
MSM_SERVER=$test_work/server
MSM_STATE=$test_work/state
MSM_JOURNAL=$MSM_STATE/transaction.json
MSM_JAVA=$test_work/java
MSM_OWNER_UID=$EUID
mkdir -m 700 "$MSM_SERVER" "$MSM_STATE"
passed=0
check_ok() { "$@" || { printf 'FAIL: expected success: %s\n' "$*" >&2; exit 1; }; ((passed+=1)); }
check_fail() { if ("$@") >/dev/null 2>&1; then printf 'FAIL: expected rejection: %s\n' "$*" >&2; exit 1; fi; ((passed+=1)); }

check_ok bash -c 'umask 0002; source "$1/lib/common.sh"; MSM_OWNER_UID=$EUID; msm_directory "$2" 755; [[ $(stat -c %a "$2") == 755 ]]' bash "$test_root" "$test_work/new-directory"
mkdir -m 775 "$test_work/writable-directory"
check_fail msm_directory "$test_work/writable-directory" 755
[[ $(stat -c %a "$test_work/writable-directory") == 775 ]]
if command -v setfacl >/dev/null; then
    mkdir "$test_work/acl-parent"
    setfacl -d -m u::rwx,g::rwx,o::rx "$test_work/acl-parent"
    check_ok msm_directory "$test_work/acl-parent/managed" 755
    [[ $(stat -c %a "$test_work/acl-parent/managed") == 755 ]]
fi

printf '  # A comment ending in a backslash\\\nlevel-name: world\nmotd=A\\u0020server\n' >"$MSM_SERVER/server.properties"
check_ok msm_validate_properties
printf 'level-name=../escape\n' >"$MSM_SERVER/server.properties"
check_fail msm_validate_properties
printf 'level-name=world\nlevel\\u002dname=../escape\n' >"$MSM_SERVER/server.properties"
check_fail msm_validate_properties
printf 'motd=continued\\\nlevel-name=../escape\n' >"$MSM_SERVER/server.properties"
check_fail msm_validate_properties
printf 'level-name=world\nlevel-name: libraries\n' >"$MSM_SERVER/server.properties"
check_fail msm_validate_properties
printf 'level-name world_2\n' >"$MSM_SERVER/server.properties"
check_ok msm_validate_properties
ln -s "$test_work" "$MSM_SERVER/world_2"
check_fail msm_validate_properties
rm "$MSM_SERVER/world_2"

printf '{"schema":1,"memory_min":"1G","memory_max":"4096M","startup_timeout":300}\n' >"$test_work/settings.json"
check_ok msm_validate_settings "$test_work/settings.json"
printf '{"schema":1,"memory_min":"5G","memory_max":"4G","startup_timeout":300}\n' >"$test_work/settings.json"
check_fail msm_validate_settings "$test_work/settings.json"
printf '{"schema":1,"memory_min":"1G;id","memory_max":"4G","startup_timeout":300}\n' >"$test_work/settings.json"
check_fail msm_validate_settings "$test_work/settings.json"

jq -n --arg java_home "$MSM_JAVA/java-21-aaaaaaaaaaaaaaaa" '{schema:1,mc:"1.21.1",neoforge:"21.1.235",java_home:$java_home,unix_args:"libraries/net/neoforged/neoforge/21.1.235/unix_args.txt"}' >"$test_work/runtime.json"
check_ok msm_validate_runtime "$test_work/runtime.json"
jq '.unix_args="../../other"' "$test_work/runtime.json" >"$test_work/invalid.json"
check_fail msm_validate_runtime "$test_work/invalid.json"
jq '.java_home="/usr/bin"' "$test_work/runtime.json" >"$test_work/invalid.json"
check_fail msm_validate_runtime "$test_work/invalid.json"

jq --arg java_home "$MSM_JAVA/java-25-bbbbbbbbbbbbbbbb" '.loader="fabric" | .fabric="0.20.1" | .fabric_installer="1.1.2" | .launch_jar="fabric-server-launch.jar" | .java_home=$java_home | del(.neoforge,.unix_args)' "$test_work/runtime.json" > "$test_work/fabric.json"
check_ok msm_validate_runtime "$test_work/fabric.json"
[[ $(msm_runtime_launch_file "$test_work/fabric.json") == fabric-server-launch.jar ]]
jq '.launch_jar="../../escape.jar"' "$test_work/fabric.json" > "$test_work/invalid.json"
check_fail msm_validate_runtime "$test_work/invalid.json"
jq '.loader="unknown"' "$test_work/fabric.json" > "$test_work/invalid.json"
check_fail msm_validate_runtime "$test_work/invalid.json"
jq '.fabric="0.20.2-beta"' "$test_work/fabric.json" > "$test_work/invalid.json"
check_fail msm_validate_runtime "$test_work/invalid.json"

jq '.loader="vanilla" | .launch_jar="server.jar" | del(.fabric,.fabric_installer)' "$test_work/fabric.json" > "$test_work/vanilla.json"
check_ok msm_validate_runtime "$test_work/vanilla.json"
[[ $(msm_runtime_launch_file "$test_work/vanilla.json") == server.jar ]]
jq '.launch_jar="fabric-server-launch.jar"' "$test_work/vanilla.json" > "$test_work/invalid.json"
check_fail msm_validate_runtime "$test_work/invalid.json"

printf '{"schema":1,"phase":"snapshot_ready","restore_required":false}\n' >"$MSM_JOURNAL"
chmod 600 "$MSM_JOURNAL"
msm_journal_phase applying
check_ok jq -e '.phase=="applying" and .restore_required==true' "$MSM_JOURNAL"
check_fail msm_idle
msm_clear_journal
check_ok msm_idle
printf '{}\n' >"$MSM_STATE/restore.json"
check_fail msm_idle
printf 'PASS: common (%s checks)\n' "$passed"
