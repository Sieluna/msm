#!/usr/bin/env bash
# Resume integration fixtures use real JSON/files and simulated accounts/systemd.
# Real account creation, downloads, Java execution, and unit installation are not tested.
set -Eeuo pipefail
TEST_CODE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
source "$TEST_CODE/lib/common.sh"
source "$TEST_CODE/lib/install.sh"
source "$TEST_CODE/lib/transaction.sh"
TEST_ROOT=$(mktemp -d "$TEST_CODE/tests/install-fixture.XXXXXXXX")
trap 'rm -rf -- "$TEST_ROOT"' EXIT
passed=0 failed=0

case_run() {
    local name=$1; shift
    if ("$@"); then
        printf 'PASS %s\n' "$name"; ((passed+=1))
    else
        printf 'FAIL %s\n' "$name" >&2; ((failed+=1))
    fi
}

fixture() {
    TEST_CASE=$(mktemp -d "$TEST_ROOT/case.XXXXXXXX")
    MSM_BASE=$TEST_CASE/minecraft MSM_CONFIG=$TEST_CASE/config MSM_STATE=$TEST_CASE/state
    MSM_SERVER=$MSM_BASE/server MSM_STAGING=$MSM_BASE/.msm-staging MSM_RECOVERY=$MSM_BASE/recovery
    MSM_BACKUPS=$TEST_CASE/backups MSM_JAVA=$TEST_CASE/opt/java MSM_CODE=$TEST_CASE/code
    MSM_JOURNAL=$MSM_STATE/transaction.json MSM_OWNER_UID=$EUID
    TEST_PAYLOAD=$MSM_STAGING/prepare.Fixture123/engine
    mkdir -p "$MSM_STATE" "$TEST_PAYLOAD/world" "$TEST_PAYLOAD/libraries/net/neoforged/neoforge/21.1.235" \
        "$MSM_JAVA/java-21-aaaaaaaaaaaaaaaa/bin"
    chmod 700 "$MSM_STATE"
    printf 'original world data\n' >"$TEST_PAYLOAD/world/level.dat"
    printf 'level-name=world\n' >"$TEST_PAYLOAD/server.properties"
    printf 'fixture NeoForge arguments\n' >"$TEST_PAYLOAD/libraries/net/neoforged/neoforge/21.1.235/unix_args.txt"
    printf '#!/bin/bash\nexit 0\n' >"$MSM_JAVA/java-21-aaaaaaaaaaaaaaaa/bin/java"
    chmod 755 "$MSM_JAVA/java-21-aaaaaaaaaaaaaaaa/bin/java"
    jq -n --arg payload "$TEST_PAYLOAD" --arg java_home "$MSM_JAVA/java-21-aaaaaaaaaaaaaaaa" \
        '{schema:1,id:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",kind:"bootstrap",phase:"assembled",
          was_running:false,backup:null,account_id:299,no_start:true,port:25565,payload:$payload,
          runtime:{schema:1,mc:"1.21.1",neoforge:"21.1.235",java_major:21,java_home:$java_home,
                   unix_args:"libraries/net/neoforged/neoforge/21.1.235/unix_args.txt"},
          settings:{schema:1,memory_min:"1G",memory_max:"4G",startup_timeout:300},
          mods:{schema:1,mods:[]},mods_lock:{schema:1,mods:[]}}' >"$MSM_JOURNAL"
    chmod 600 "$MSM_JOURNAL"
    if [[ ${MSM_TEST_LOADER:-neoforge} == fabric ]]; then
        printf 'fixture Fabric launcher\n' > "$TEST_PAYLOAD/fabric-server-launch.jar"
        jq '.runtime |= (.loader="fabric" | .fabric="0.20.1" | .fabric_installer="1.1.2" | .launch_jar="fabric-server-launch.jar" | del(.neoforge,.unix_args))' "$MSM_JOURNAL" > "$TEST_CASE/fabric-journal"
        mv "$TEST_CASE/fabric-journal" "$MSM_JOURNAL"
        chmod 600 "$MSM_JOURNAL"
    elif [[ ${MSM_TEST_LOADER:-neoforge} == vanilla ]]; then
        printf 'fixture Vanilla server\n' > "$TEST_PAYLOAD/server.jar"
        jq '.runtime |= (.loader="vanilla" | .launch_jar="server.jar" | del(.neoforge,.unix_args))' "$MSM_JOURNAL" > "$TEST_CASE/vanilla-journal"
        mv "$TEST_CASE/vanilla-journal" "$MSM_JOURNAL"
        chmod 600 "$MSM_JOURNAL"
    fi
    : >"$TEST_CASE/accounts.calls"
    : >"$TEST_CASE/code.calls"
    : >"$TEST_CASE/service.calls"
}

# Exercise the real account idempotency logic against an isolated fake database.
getent() {
    case $1:$2 in
        group:minecraft|group:299) [[ -f $TEST_CASE/group ]] && cat "$TEST_CASE/group" ;;
        passwd:minecraft|passwd:299) [[ -f $TEST_CASE/passwd ]] && cat "$TEST_CASE/passwd" ;;
        *) return 2 ;;
    esac
}
groupadd() {
    [[ $* == '--system --gid 299 minecraft' && ! -e $TEST_CASE/group ]] || return 91
    printf 'minecraft:x:299:\n' >"$TEST_CASE/group"
    printf 'groupadd\n' >>"$TEST_CASE/accounts.calls"
}
useradd() {
    [[ $* == "--system --uid 299 --gid 299 --home-dir $MSM_BASE --no-create-home --shell /usr/sbin/nologin minecraft" && ! -e $TEST_CASE/passwd ]] || return 92
    printf 'minecraft:x:299:299::%s:/usr/sbin/nologin\n' "$MSM_BASE" >"$TEST_CASE/passwd"
    printf 'useradd\n' >>"$TEST_CASE/accounts.calls"
}
msm_install_code() {
    printf 'install\n' >>"$TEST_CASE/code.calls"
    if [[ -f $TEST_CASE/fail-code-once ]]; then rm "$TEST_CASE/fail-code-once"; return 41; fi
    : >"$TEST_CASE/unit-installed"
}
msm_own_server() { [[ -d $MSM_SERVER && ! -L $MSM_SERVER ]]; }
msm_service_stop() {
    [[ ${1:-} == any ]] || return 93
    printf 'stop\n' >>"$TEST_CASE/service.calls"
}
msm_service_start() {
    [[ -f $TEST_CASE/unit-installed && $(jq -r .phase "$MSM_JOURNAL") == starting ]] || return 94
    printf 'start\n' >>"$TEST_CASE/service.calls"
    if [[ -f $TEST_CASE/fail-start-once ]]; then
        rm "$TEST_CASE/fail-start-once"
        printf 'data saved during the failed first start\n' >>"$MSM_SERVER/world/level.dat"
        return 42
    fi
}
msm_java_prepare() { msm_die 'Unexpected Java preparation during a resume fixture.'; }
msm_engine_prepare() { msm_die 'Unexpected engine preparation during a resume fixture.'; }
msm_download_mods() { msm_die 'Unexpected mod download during a resume fixture.'; }
msm_resolve_runtime() { msm_die 'Unexpected version resolution during a resume fixture.'; }
msm_resolve_mods() { msm_die 'Unexpected mod resolution during a resume fixture.'; }

expect_resume_failure() {
    local expected=$1 actual=0
    msm_install_resume >"$TEST_CASE/output" 2>"$TEST_CASE/error" || actual=$?
    [[ $actual == "$expected" ]] || { cat "$TEST_CASE/error" >&2; return 1; }
}

config_matches_journal() {
    local key name
    for key in runtime settings mods mods_lock; do
        name=$key.json
        [[ $key != mods_lock ]] || name=mods.lock.json
        [[ $(jq -Sc ".$key" "$MSM_JOURNAL") == "$(jq -Sc . "$MSM_CONFIG/$name")" ]] || return 1
    done
}

renamed_payload_case() {
    local before inode
    fixture
    msm_install_accounts || return
    mv -T "$TEST_PAYLOAD" "$MSM_SERVER"
    printf 'existing live world data must survive\n' >>"$MSM_SERVER/world/level.dat"
    before=$(sha256sum "$MSM_SERVER/world/level.dat") inode=$(stat -c %i "$MSM_SERVER/world")
    msm_recover >"$TEST_CASE/output" 2>"$TEST_CASE/error" || { cat "$TEST_CASE/error" >&2; return 1; }
    [[ ! -e $MSM_JOURNAL && ! -e $TEST_PAYLOAD && -f $TEST_CASE/unit-installed ]] || return 1
    [[ $before == "$(sha256sum "$MSM_SERVER/world/level.dat")" && $inode == "$(stat -c %i "$MSM_SERVER/world")" ]] || return 1
    [[ $(cat "$TEST_CASE/accounts.calls") == $'groupadd\nuseradd' && ! -s $TEST_CASE/service.calls ]]
}

unit_failure_case() {
    local before inode
    fixture
    : >"$TEST_CASE/fail-code-once"
    expect_resume_failure 41 || return
    [[ $(jq -r .phase "$MSM_JOURNAL") == assembled && ! -e $TEST_PAYLOAD && -d $MSM_SERVER ]] || return 1
    config_matches_journal || return
    printf 'world data after the interrupted unit installation\n' >>"$MSM_SERVER/world/level.dat"
    before=$(sha256sum "$MSM_SERVER/world/level.dat") inode=$(stat -c %i "$MSM_SERVER/world")
    msm_recover >"$TEST_CASE/output" 2>"$TEST_CASE/error" || { cat "$TEST_CASE/error" >&2; return 1; }
    [[ ! -e $MSM_JOURNAL && -f $TEST_CASE/unit-installed ]] || return 1
    [[ $before == "$(sha256sum "$MSM_SERVER/world/level.dat")" && $inode == "$(stat -c %i "$MSM_SERVER/world")" ]] || return 1
    [[ $(cat "$TEST_CASE/accounts.calls") == $'groupadd\nuseradd' && $(cat "$TEST_CASE/code.calls") == $'install\ninstall' ]]
}

startup_failure_case() {
    local temporary plan before config_before
    fixture
    temporary=$(mktemp "$MSM_STATE/.test.XXXXXXXX")
    jq '.no_start=false' "$MSM_JOURNAL" >"$temporary"
    mv -T "$temporary" "$MSM_JOURNAL"
    plan=$(jq -Sc 'del(.phase)' "$MSM_JOURNAL")
    : >"$TEST_CASE/fail-start-once"
    expect_resume_failure 42 || return
    [[ $(jq -r .phase "$MSM_JOURNAL") == starting && $plan == "$(jq -Sc 'del(.phase)' "$MSM_JOURNAL")" ]] || return 1
    config_matches_journal || return
    before=$(sha256sum "$MSM_SERVER/world/level.dat") config_before=$(sha256sum "$MSM_CONFIG/"*.json)
    msm_recover >"$TEST_CASE/output" 2>"$TEST_CASE/error" || { cat "$TEST_CASE/error" >&2; return 1; }
    [[ ! -e $MSM_JOURNAL && $before == "$(sha256sum "$MSM_SERVER/world/level.dat")" && $config_before == "$(sha256sum "$MSM_CONFIG/"*.json)" ]] || return 1
    [[ $(cat "$TEST_CASE/accounts.calls") == $'groupadd\nuseradd' && $(cat "$TEST_CASE/code.calls") == install ]] || return 1
    [[ $(cat "$TEST_CASE/service.calls") == $'stop\nstart\nstop\nstart' ]]
}

case_run 'renamed assembled payload resumes without replacing world or accounts' renamed_payload_case
case_run 'unit-install failure after config publication resumes safely' unit_failure_case
case_run 'startup failure preserves starting plan and resumes without reinstalling' startup_failure_case
printf '%s passed, %s failed; account database and systemd are simulated\n' "$passed" "$failed"
((failed == 0))
