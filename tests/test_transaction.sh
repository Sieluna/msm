#!/usr/bin/env bash
# Real snapshots, JSON state and directory swaps; service/account calls are fake.
set -u
set -o pipefail
umask 077
export LC_ALL=C.UTF-8

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd) || exit 1
PROJECT_DIR=${TEST_DIR%/tests}
TEST_ROOT=$(mktemp -d "$TEST_DIR/.transaction-tests.XXXXXXXX") || exit 1
trap 'rm -rf -- "$TEST_ROOT"' EXIT

# shellcheck source=../lib/common.sh
source "$PROJECT_DIR/lib/common.sh" || exit 1
# shellcheck source=../lib/archive.sh
source "$PROJECT_DIR/lib/archive.sh" || exit 1
# shellcheck source=../lib/transaction.sh
source "$PROJECT_DIR/lib/transaction.sh" || exit 1

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

msm_service_running() {
    [[ $(cat -- "$CASE_DIR/service-state") == running ]]
}

msm_service_stop() {
    printf 'stop %s\n' "${1:-any}" >> "$CASE_DIR/service-events" || return
    printf 'stopped\n' > "$CASE_DIR/service-state" || return
}

msm_service_assert_stopped() {
    [[ $(cat -- "$CASE_DIR/service-state") == stopped ]] || msm_die 'The simulated service has live processes.'
}

msm_service_start() {
    msm_load_config || return
    printf 'start\n' >> "$CASE_DIR/service-events" || return
    printf 'running\n' > "$CASE_DIR/service-state" || return
}

msm_own_server() {
    [[ -d $MSM_SERVER && ! -L $MSM_SERVER ]] || msm_die 'The simulated ownership target is invalid.'
    return 0
}

fixture() {
    local initial=${1:-running} home arguments hash
    if [[ -n ${TEST_LOCK_FD:-} ]]; then
        exec {TEST_LOCK_FD}>&- || fail 'Cannot close the prior test lock.'
        unset TEST_LOCK_FD
    fi
    CASE_DIR=$(mktemp -d "$TEST_ROOT/case.XXXXXXXX") || fail 'Cannot create transaction fixture.'
    MSM_BASE=$CASE_DIR/base
    MSM_SERVER=$MSM_BASE/server
    MSM_STAGING=$MSM_BASE/.msm-staging
    MSM_RECOVERY=$MSM_BASE/recovery
    MSM_CONFIG=$CASE_DIR/config
    MSM_BACKUPS=$CASE_DIR/backups
    MSM_STATE=$CASE_DIR/state
    MSM_JAVA=$CASE_DIR/java
    MSM_JOURNAL=$MSM_STATE/transaction.json
    MSM_LOCK=$MSM_STATE/manager.lock
    MSM_OWNER_UID=$(id -u) || fail 'Cannot read fixture UID.'
    mkdir -p -m 700 -- "$MSM_SERVER" "$MSM_STAGING" "$MSM_RECOVERY" "$MSM_CONFIG" \
        "$MSM_BACKUPS" "$MSM_STATE" "$MSM_JAVA" || fail 'Cannot create transaction directories.'
    home=$MSM_JAVA/java-21-aaaaaaaaaaaaaaaa
    arguments=libraries/net/neoforged/neoforge/21.1.235/unix_args.txt
    mkdir -p -m 700 -- "$home/bin" "${MSM_SERVER}/${arguments%/*}" "$MSM_SERVER/world" \
        "$MSM_SERVER/mods" "$MSM_SERVER/config" || fail 'Cannot create runtime fixture.'
    printf '#!/bin/sh\nexit 99\n' > "$home/bin/java" || fail 'Cannot write Java placeholder.'
    chmod 700 -- "$home/bin/java" || fail 'Cannot protect Java placeholder.'
    printf 'placeholder arguments\n' > "$MSM_SERVER/$arguments" || fail 'Cannot write runtime arguments.'
    printf 'level-name=world\nonline-mode=true\n' > "$MSM_SERVER/server.properties" || fail 'Cannot write server properties.'
    printf 'original world\n' > "$MSM_SERVER/world/level.dat" || fail 'Cannot write original world.'
    printf 'original mod\n' > "$MSM_SERVER/mods/original.jar" || fail 'Cannot write original mod.'
    printf 'original=true\n' > "$MSM_SERVER/config/game.toml" || fail 'Cannot write original mod config.'
    jq -n --arg home "$home" --arg args "$arguments" \
        '{schema:1,mc:"1.21.1",neoforge:"21.1.235",java_home:$home,unix_args:$args}' \
        > "$MSM_CONFIG/runtime.json" || fail 'Cannot write runtime metadata.'
    printf '{"schema":1,"memory_min":"1G","memory_max":"4G","startup_timeout":60}\n' \
        > "$MSM_CONFIG/settings.json" || fail 'Cannot write settings metadata.'
    printf '{"schema":1,"loader":"neoforge","mods":[]}\n\n' \
        > "$MSM_CONFIG/mods.json" || fail 'Cannot write the original template.'
    if [[ ${MSM_TEST_LOADER:-neoforge} == fabric ]]; then
        printf 'placeholder Fabric launcher\n' > "$MSM_SERVER/fabric-server-launch.jar"
        jq '.loader="fabric" | .fabric="0.20.1" | .fabric_installer="1.1.2" | .launch_jar="fabric-server-launch.jar" | del(.neoforge,.unix_args)' "$MSM_CONFIG/runtime.json" > "$CASE_DIR/fabric-runtime"
        mv "$CASE_DIR/fabric-runtime" "$MSM_CONFIG/runtime.json"
        jq '.loader="fabric"' "$MSM_CONFIG/mods.json" > "$CASE_DIR/fabric-mods"
        mv "$CASE_DIR/fabric-mods" "$MSM_CONFIG/mods.json"
    elif [[ ${MSM_TEST_LOADER:-neoforge} == vanilla ]]; then
        printf 'placeholder Vanilla server\n' > "$MSM_SERVER/server.jar"
        jq '.loader="vanilla" | .launch_jar="server.jar" | del(.neoforge,.unix_args)' "$MSM_CONFIG/runtime.json" > "$CASE_DIR/vanilla-runtime"
        mv "$CASE_DIR/vanilla-runtime" "$MSM_CONFIG/runtime.json"
        jq '.loader="vanilla"' "$MSM_CONFIG/mods.json" > "$CASE_DIR/vanilla-mods"
        mv "$CASE_DIR/vanilla-mods" "$MSM_CONFIG/mods.json"
    fi
    hash=$(sha1sum -- "$MSM_SERVER/mods/original.jar") || fail 'Cannot hash the original mod.'
    jq -n --arg hash "${hash%% *}" '{schema:1,mods:[{filename:"original.jar",sha1:$hash}]}' \
        > "$MSM_CONFIG/mods.lock.json" || fail 'Cannot write the original lock.'
    printf '%s\n' "$initial" > "$CASE_DIR/service-state" || fail 'Cannot create simulated service state.'
    : > "$CASE_DIR/service-events" || fail 'Cannot create simulated service log.'
    cp -a -- "$MSM_SERVER" "$CASE_DIR/original-server" || fail 'Cannot retain reference data.'
    cp -a -- "$MSM_CONFIG" "$CASE_DIR/original-config" || fail 'Cannot retain reference config.'
    exec {TEST_LOCK_FD}> "$MSM_LOCK" || fail 'Cannot open the shared management lock.'
    flock -n "$TEST_LOCK_FD" || fail 'Cannot acquire the shared management lock.'
}

mutate_candidate() {
    local file hash
    printf 'candidate world\n' > "$MSM_SERVER/world/level.dat" || fail 'Cannot mutate candidate world.'
    printf 'candidate=true\n' > "$MSM_SERVER/config/game.toml" || fail 'Cannot mutate candidate config.'
    printf 'candidate-only data\n' > "$MSM_SERVER/candidate-only.txt" || fail 'Cannot create candidate data.'
    rm -- "$MSM_SERVER/mods/original.jar" || fail 'Cannot replace candidate mod.'
    printf 'candidate mod\n' > "$MSM_SERVER/mods/candidate.jar" || fail 'Cannot write candidate mod.'
    jq '.candidate=true' "$MSM_CONFIG/runtime.json" > "$CASE_DIR/runtime-next.json" || fail 'Cannot prepare candidate runtime.'
    msm_atomic_json "$CASE_DIR/runtime-next.json" "$MSM_CONFIG/runtime.json" || fail 'Cannot publish candidate runtime.'
    jq '.memory_max="6G"' "$MSM_CONFIG/settings.json" > "$CASE_DIR/settings-next.json" || fail 'Cannot prepare candidate settings.'
    msm_atomic_json "$CASE_DIR/settings-next.json" "$MSM_CONFIG/settings.json" || fail 'Cannot publish candidate settings.'
    printf '{"schema":1,"loader":"neoforge","mods":[{"project":"candidate","enabled":true}]}\n' \
        > "$MSM_CONFIG/mods.json" || fail 'Cannot update candidate template.'
    hash=$(sha1sum -- "$MSM_SERVER/mods/candidate.jar") || fail 'Cannot hash candidate mod.'
    jq -n --arg hash "${hash%% *}" '{schema:1,mods:[{filename:"candidate.jar",sha1:$hash}]}' \
        > "$MSM_CONFIG/mods.lock.json" || fail 'Cannot update candidate lock.'
}

assert_original() {
    local state=${1:-running}
    diff -r -- "$CASE_DIR/original-server" "$MSM_SERVER" || fail 'Complete original server data was not restored.'
    diff -r -- "$CASE_DIR/original-config" "$MSM_CONFIG" || fail 'Complete original manager metadata was not restored.'
    [[ $(cat -- "$CASE_DIR/service-state") == "$state" ]] || fail 'Original service state was not preserved.'
    [[ ! -e $MSM_JOURNAL && ! -e $MSM_STATE/restore.json ]] || fail 'Completed recovery left an active journal.'
}

test_applying_interruption_restores_complete_data_and_running_state() {
    msm_transaction_begin update || fail 'Cannot begin update transaction.'
    local status=0 archive
    archive=$(jq -r .backup "$MSM_JOURNAL") || fail 'Cannot read backup location.'
    if (
        msm_journal_phase applying || fail 'Cannot persist the applying barrier.'
        mutate_candidate
        exit 73
    ); then
        fail 'The simulated interrupted writer unexpectedly succeeded.'
    else
        status=$?
    fi
    [[ $status == 73 ]] || fail 'The writer failed before the intended interruption.'
    [[ $(jq -r .restore_required "$MSM_JOURNAL") == true ]] || fail 'Applying did not persist rollback intent.'
    msm_recover || fail 'Interrupted applying phase could not recover.'
    assert_original
    msm_archive_verify "$archive" || fail 'Original recovery archive no longer verifies.'
    [[ -n $(find "$MSM_RECOVERY" -mindepth 1 -maxdepth 1 -type d -print -quit) ]] || fail 'Candidate data was not retained.'
}

test_snapshot_ready_recovers_only_original_service_state() {
    local initial
    for initial in running stopped; do
        fixture "$initial"
        msm_transaction_begin backup || fail 'Cannot prepare state-only recovery.'
        [[ $(jq -r .phase "$MSM_JOURNAL") == snapshot_ready ]] || fail 'Wrong pre-apply phase.'
        [[ $(jq -r .restore_required "$MSM_JOURNAL") == false ]] || fail 'Pre-apply journal requests a data restore.'
        msm_recover || fail 'State-only recovery failed.'
        assert_original "$initial"
        [[ -z $(find "$MSM_RECOVERY" -mindepth 1 -print -quit) ]] || fail 'State-only recovery replaced server data.'
    done
}

test_restore_directory_rename_gaps_can_resume() {
    local gap status archive
    for gap in old_moved new_live; do
        fixture running
        msm_transaction_begin update || fail 'Cannot prepare interrupted restore.'
        msm_journal_phase applying || fail 'Cannot set applying phase.'
        mutate_candidate
        archive=$(jq -r .backup "$MSM_JOURNAL") || fail 'Cannot read recovery archive.'
        status=0
        if (
            mv() {
                command mv "$@" || return
                if [[ ${1:-} == -T ]]; then
                    if [[ $gap == old_moved && ${2:-} == "$MSM_SERVER" ]]; then
                        exit 74
                    elif [[ $gap == new_live && ${3:-} == "$MSM_SERVER" ]]; then
                        exit 74
                    fi
                fi
            }
            msm_restore_tree "$archive" || fail 'Restore failed before the intended rename gap.'
        ); then
            fail 'The rename-gap interruption was not reached.'
        else
            status=$?
        fi
        [[ $status == 74 ]] || fail 'Restore failed at an unexpected point.'
        [[ -f $MSM_STATE/restore.json ]] || fail 'Directory swap intent was not durable.'
        if [[ $gap == old_moved ]]; then
            [[ ! -e $MSM_SERVER ]] || fail 'Expected the live-to-retired rename gap.'
        else
            [[ $(cat -- "$MSM_SERVER/world/level.dat") == 'original world' ]] || fail 'Expected the incoming-to-live rename gap.'
        fi
        msm_recover || fail 'Rename-gap recovery did not resume.'
        assert_original
    done
}

test_committed_cleanup_failure_does_not_roll_back_or_restart() {
    msm_transaction_begin update || fail 'Cannot prepare commit test.'
    msm_journal_phase applying || fail 'Cannot persist applying phase.'
    mutate_candidate
    local status=0 events
    if (
        msm_clear_journal() { return 75; }
        msm_transaction_finish
    ); then
        fail 'The terminal cleanup failure was not reached.'
    else
        status=$?
    fi
    [[ $status == 75 ]] || fail 'Commit failed before terminal cleanup.'
    [[ $(jq -r .phase "$MSM_JOURNAL") == committed ]] || fail 'Commit marker was not persisted.'
    cp -a -- "$MSM_SERVER" "$CASE_DIR/committed-server" || fail 'Cannot retain committed reference data.'
    cp -a -- "$MSM_CONFIG" "$CASE_DIR/committed-config" || fail 'Cannot retain committed reference metadata.'
    events=$(cat -- "$CASE_DIR/service-events") || fail 'Cannot read simulated service events.'
    msm_recover || fail 'Terminal cleanup recovery failed.'
    diff -r -- "$CASE_DIR/committed-server" "$MSM_SERVER" || fail 'Terminal cleanup rolled back committed data.'
    diff -r -- "$CASE_DIR/committed-config" "$MSM_CONFIG" || fail 'Terminal cleanup changed committed metadata.'
    [[ $(cat -- "$CASE_DIR/service-events") == "$events" ]] || fail 'Terminal cleanup operated the service again.'
    [[ $(cat -- "$CASE_DIR/service-state") == running ]] || fail 'Terminal cleanup changed the active service.'
    [[ ! -e $MSM_JOURNAL ]] || fail 'Terminal journal was not cleared.'
    [[ -z $(find "$MSM_RECOVERY" -mindepth 1 -print -quit) ]] || fail 'Terminal cleanup replaced data.'
}

tests=(
    test_applying_interruption_restores_complete_data_and_running_state
    test_snapshot_ready_recovers_only_original_service_state
    test_restore_directory_rename_gaps_can_resume
    test_committed_cleanup_failure_does_not_roll_back_or_restart
)
passed=0
failed=0
for test_name in "${tests[@]}"; do
    if (fixture; "$test_name"); then
        printf 'PASS %s\n' "$test_name"
        passed=$((passed + 1))
    else
        printf 'FAIL %s\n' "$test_name" >&2
        failed=$((failed + 1))
    fi
done
printf 'Transaction tests: %s passed, %s failed.\n' "$passed" "$failed"
(( failed == 0 ))
