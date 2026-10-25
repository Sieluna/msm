#!/usr/bin/env bash
# Isolated lifecycle and guard fixtures; never contact the host's systemd.
set -Eeuo pipefail
TEST_CODE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
source "$TEST_CODE/lib/common.sh"
source "$TEST_CODE/lib/service.sh"
TEST_ROOT=$(mktemp -d "$TEST_CODE/tests/service-fixture.XXXXXXXX")
trap 'rm -rf -- "$TEST_ROOT"' EXIT
passed=0 failed=0 skipped=0

case_run() {
    local name=$1; shift
    if ("$@"); then
        printf 'PASS %s\n' "$name"; ((passed+=1))
    else
        printf 'FAIL %s\n' "$name" >&2; ((failed+=1))
    fi
}

expect_status() {
    local expected=$1 actual=0; shift
    ("$@") >"$TEST_ROOT/output" 2>"$TEST_ROOT/error" || actual=$?
    [[ $actual == "$expected" ]] || {
        printf 'Expected status %s, got %s\n' "$expected" "$actual" >&2
        cat "$TEST_ROOT/error" >&2
        return 1
    }
}

state_fixture() {
    local active=${1:-active} pid=${2:-123} invocation=${3:-11111111111111111111111111111111} result=${4:-success}
    declare -gA MSM_S=([LoadState]=loaded [ActiveState]="$active" [SubState]=running
        [MainPID]="$pid" [Result]="$result" [ControlGroup]='' [InvocationID]="$invocation")
}

unknown_state_case() {
    timeout() { printf 'MainPID=0\nActiveState=inactive\n'; }
    expect_status 2 msm_service_running
}

cgroup_case() {
    local mode=$1 folder=$TEST_ROOT/cgroup
    mkdir -p "$folder/child"
    : >"$folder/cgroup.procs"
    : >"$folder/child/cgroup.procs"
    case $mode in
        empty) expect_status 0 msm_service_cgroup_empty "$folder" ;;
        live) printf '123\n' >"$folder/child/cgroup.procs"; expect_status 1 msm_service_cgroup_empty "$folder" ;;
        missing) rm "$folder/child/cgroup.procs"; expect_status 2 msm_service_cgroup_empty "$folder" ;;
        symlink) ln -s "$folder/child" "$folder/link"; expect_status 2 msm_service_cgroup_empty "$folder" ;;
    esac
}

ready_case() {
    local mode=$1 count=0
    SECONDS=0
    msm_service_state() {
        ((count+=1))
        state_fixture
        if [[ $mode == restart && $count -gt 1 ]]; then MSM_S[InvocationID]=22222222222222222222222222222222; fi
    }
    timeout() {
        [[ $* == *'_SYSTEMD_INVOCATION_ID=11111111111111111111111111111111'* ]] || return 99
        if [[ $mode != old_log ]]; then printf '[Server thread/INFO]: Done (1.234s)! For help, type "help"\n'; fi
    }
    sleep() { ((SECONDS+=2)); }
    if [[ $mode == ready ]]; then
        expect_status 0 msm_service_wait_ready 3
    else
        expect_status 1 msm_service_wait_ready 3
    fi
}

stop_case() {
    local policy=$1 expected=$2
    timeout() { [[ $* == "330s systemctl stop $MSM_UNIT" ]]; }
    msm_service_state() { state_fixture inactive 0 '' timeout; }
    expect_status "$expected" msm_service_stop "$policy"
}

start_cleanup_case() {
    local mode=$1
    MSM_CONFIG=$TEST_ROOT/start-config MSM_RUN=$TEST_ROOT/start-run MSM_JOURNAL=$TEST_ROOT/no-journal
    MSM_OWNER_UID=$(id -u)
    mkdir -p "$MSM_CONFIG" "$MSM_RUN"
    chmod 700 "$MSM_RUN"
    printf '{"schema":1,"memory_min":"1G","memory_max":"4G","startup_timeout":30}\n' >"$MSM_CONFIG/settings.json"
    printf '{}\n' >"$MSM_RUN/permit.json"
    : >"$TEST_ROOT/calls"
    msm_have_lock() { return 0; }
    timeout() { printf '%s\n' "$*" >>"$TEST_ROOT/calls"; return 0; }
    msm_service_wait_ready() { [[ $mode == success ]] || msm_die 'Fixture startup failure.'; }
    msm_service_state() { state_fixture inactive 0; }
    if [[ $mode == success ]]; then
        expect_status 0 msm_service_start || return
        [[ $(cat "$TEST_ROOT/calls") != *'systemctl stop '* ]] || return 1
    else
        expect_status 1 msm_service_start || return
        [[ $(cat "$TEST_ROOT/calls") == *'systemctl stop '* ]] || return 1
    fi
    [[ ! -e $MSM_RUN/permit.json ]]
}

guard_fixture() {
    rm -rf -- "$TEST_ROOT/guard"
    mkdir -m 700 "$TEST_ROOT/guard" "$TEST_ROOT/guard/state" "$TEST_ROOT/guard/run"
    printf '{"schema":1,"id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","kind":"transaction","phase":"starting","was_running":true,"backup":null}\n' >"$TEST_ROOT/guard/state/transaction.json"
    jq -n --argjson expires "$(( $(date +%s) + 60 ))" \
        '{id:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",pid:123,start_ticks:"100",boot_id:"bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",expires:$expires}' >"$TEST_ROOT/guard/run/permit.json"
    chmod 600 "$TEST_ROOT/guard/state/transaction.json" "$TEST_ROOT/guard/run/permit.json"
}

guard_execute() (
    # Rebind only the two fixed source paths inside this fixture process.
    source() {
        case $1 in
            /usr/local/lib/msm/lib/common.sh)
                builtin source "$TEST_CODE/lib/common.sh"
                MSM_STATE=$TEST_ROOT/guard/state MSM_RUN=$TEST_ROOT/guard/run
                MSM_JOURNAL=$MSM_STATE/transaction.json ;;
            /usr/local/lib/msm/lib/service.sh)
                builtin source "$TEST_CODE/lib/service.sh"
                msm_proc_ticks() { [[ $1 == 123 ]] || return 1; printf '%s\n' "${GUARD_TICKS:-100}"; }
                msm_have_lock() { [[ ${GUARD_LOCK:-held} == held ]]; } ;;
            *) return 99 ;;
        esac
    }
    cat() {
        if [[ $# == 1 && $1 == /proc/sys/kernel/random/boot_id ]]; then
            printf '%s\n' "${GUARD_BOOT:-bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb}"
        else command cat "$@"; fi
    }
    builtin source "$TEST_CODE/libexec/guard.sh"
)

guard_case() {
    local mode=$1 expected=1 temporary
    guard_fixture
    case $mode in
        absent) rm "$TEST_ROOT/guard/state/transaction.json"; expected=0 ;;
        valid) expected=0 ;;
        rollback)
            temporary=$(mktemp "$TEST_ROOT/guard/state/.test.XXXXXXXX")
            jq '.phase="rollback_starting"' "$TEST_ROOT/guard/state/transaction.json" >"$temporary"
            mv -T "$temporary" "$TEST_ROOT/guard/state/transaction.json"
            expected=0 ;;
        committed|preparing)
            temporary=$(mktemp "$TEST_ROOT/guard/state/.test.XXXXXXXX")
            jq --arg phase "$mode" '.phase=$phase' "$TEST_ROOT/guard/state/transaction.json" >"$temporary"
            mv -T "$temporary" "$TEST_ROOT/guard/state/transaction.json" ;;
        orphan_restore) rm "$TEST_ROOT/guard/state/transaction.json"; printf '{}\n' >"$TEST_ROOT/guard/state/restore.json" ;;
        no_permit) rm "$TEST_ROOT/guard/run/permit.json" ;;
        reused_pid) GUARD_TICKS=200 ;;
        old_boot) GUARD_BOOT=cccccccc-cccc-cccc-cccc-cccccccccccc ;;
        unlocked) GUARD_LOCK=free ;;
        expired)
            temporary=$(mktemp "$TEST_ROOT/guard/run/.test.XXXXXXXX")
            jq '.expires=1' "$TEST_ROOT/guard/run/permit.json" >"$temporary"
            mv -T "$temporary" "$TEST_ROOT/guard/run/permit.json" ;;
        writable) chmod 664 "$TEST_ROOT/guard/run/permit.json" ;;
        symlink)
            mv "$TEST_ROOT/guard/run/permit.json" "$TEST_ROOT/guard/run/other.json"
            ln -s other.json "$TEST_ROOT/guard/run/permit.json" ;;
    esac
    expect_status "$expected" guard_execute
}

real_lock_case() {
    mkdir -m 700 "$TEST_ROOT/lock-state"
    (umask 077; : >"$TEST_ROOT/lock-state/manager.lock")
    flock -n -F "$TEST_ROOT/lock-state/manager.lock" /bin/bash -c '
        set -Eeuo pipefail
        source "$1/lib/common.sh"
        source "$1/lib/service.sh"
        MSM_STATE=$2
        msm_have_lock "$$"
    ' bash "$TEST_CODE" "$TEST_ROOT/lock-state"
}

case_run 'incomplete systemctl output is unknown' unknown_state_case
case_run 'empty cgroup descendants are stopped' cgroup_case empty
case_run 'live descendant prevents stopped state' cgroup_case live
case_run 'unreadable cgroup data fails closed' cgroup_case missing
case_run 'symlink cgroup data fails closed' cgroup_case symlink
case_run 'current invocation ready message is accepted' ready_case ready
case_run 'invocation change invalidates readiness' ready_case restart
case_run 'old invocation logs do not prove readiness' ready_case old_log
case_run 'clean stop rejects a timeout result' stop_case clean 1
case_run 'recovery stop accepts stopped failed state' stop_case any 0
case_run 'failed startup stops the service and removes permit' start_cleanup_case failure
case_run 'successful startup only removes permit' start_cleanup_case success
if [[ $EUID == 0 ]]; then
    for mode in absent valid rollback preparing orphan_restore no_permit reused_pid old_boot unlocked expired writable symlink; do
        case_run "guard fixture: $mode" guard_case "$mode"
    done
else
    printf 'SKIP root-owned guard fixtures require UID 0\n'; ((skipped+=1))
fi
if [[ $EUID == 0 && -r /proc/locks && -r /proc/$$/stat ]]; then
    case_run 'real flock -F owner passes /proc validation' real_lock_case
else
    printf 'SKIP real flock ownership requires UID 0 and readable procfs\n'; ((skipped+=1))
fi
printf '%s passed, %s failed, %s skipped\n' "$passed" "$failed" "$skipped"
((failed == 0))
