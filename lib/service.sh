#!/bin/bash
# Lifecycle helpers. Callers hold manager.lock before changing service state.

msm_service_private_dir() {
    [[ -d $1 && ! -L $1 && $(stat -c '%u:%a' -- "$1") == 0:700 ]]
}

msm_proc_ticks() {
    local pid=$1 record; local -a fields
    [[ $pid =~ ^[1-9][0-9]*$ && ! -L /proc/$pid && $(stat -c %u "/proc/$pid" 2>/dev/null) == 0 ]] || return 1
    record=$(cat "/proc/$pid/stat" 2>/dev/null) || return 1
    [[ $record == "$pid ("* ]] || return 1
    record=${record##*) }
    read -r -a fields <<<"$record"
    [[ ${#fields[@]} -ge 20 && ${fields[0]} != [ZXx] && ${fields[19]} =~ ^[0-9]+$ ]] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    printf '%s\n' "${fields[19]}"
}

msm_have_lock() {
    local pid=${1:-$$} lock=$MSM_STATE/manager.lock fd rc=0 metadata dev inode major minor
    local number kind advisory mode owner device rest high low item found=1
    msm_service_private_dir "$MSM_STATE" && msm_proc_ticks "$pid" >/dev/null || return 1
    [[ -f $lock && ! -L $lock && $(stat -c '%u:%a:%h' -- "$lock") == 0:600:1 && -r /proc/locks ]] || return 1
    exec {fd}<"$lock" || return 1
    # Read-only flock probes also work inside systemd's read-only filesystem view.
    flock -xn "$fd" || rc=$?
    if (( rc != 1 )); then exec {fd}<&-; return 1; fi
    metadata=$(stat -c '%d %i' -- "$lock") || { exec {fd}<&-; return 1; }
    read -r dev inode <<<"$metadata"
    major=$(( (dev >> 8 & 0xfff) | (dev >> 32 & 0xfffff000) ))
    minor=$(( (dev & 0xff) | (dev >> 12 & 0xffffff00) ))
    while read -r number kind advisory mode owner device rest; do
        [[ $kind == FLOCK && $advisory == ADVISORY && $mode == WRITE && $owner == "$pid" ]] || continue
        [[ $device =~ ^[0-9a-fA-F]+:[0-9a-fA-F]+:[0-9]+$ ]] || continue
        IFS=: read -r high low item <<<"$device"
        if (( 16#$high == major && 16#$low == minor )) && [[ $item == "$inode" ]]; then found=0; break; fi
    done </proc/locks
    exec {fd}<&-
    return "$found"
}

msm_starting_journal_id() {
    msm_trusted_file "$MSM_JOURNAL"
    [[ $(stat -c %a -- "$MSM_JOURNAL") == 600 ]] || return 1
    jq -er 'select(.schema == 1 and (.id|type == "string" and test("^[0-9a-f]{32}$")) and
        (.kind == "transaction" or .kind == "bootstrap") and
        (.phase == "starting" or .phase == "rollback_starting") and
        (.was_running|type == "boolean") and has("backup") and
        (.backup == null or (.backup|type == "string" and startswith("/")))) | .id' "$MSM_JOURNAL"
}

msm_service_state() {
    local output key value rc=0
    output=$(timeout 20s systemctl show "$MSM_UNIT" --no-pager \
        --property=LoadState,ActiveState,SubState,MainPID,Result,ControlGroup,InvocationID) || rc=$?
    declare -gA MSM_S=()
    while IFS='=' read -r key value; do
        case $key in LoadState|ActiveState|SubState|MainPID|Result|ControlGroup|InvocationID) MSM_S[$key]=$value ;; esac
    done <<<"$output"
    for key in LoadState ActiveState SubState MainPID Result ControlGroup InvocationID; do
        [[ ${MSM_S[$key]+present} ]] || return 2
    done
    [[ ${MSM_S[MainPID]} =~ ^[0-9]+$ ]] || return 2
    (( rc == 0 )) || [[ ${MSM_S[LoadState]} == not-found ]] || return 2
}

msm_service_cgroup_empty() (
    local directory=$1 content entry
    [[ -d $directory && ! -L $directory && -r $directory/cgroup.procs ]] || return 2
    content=$(cat "$directory/cgroup.procs") || return 2
    [[ -z ${content//[[:space:]]/} ]] || return 1
    ls -A -- "$directory" >/dev/null 2>&1 || return 2
    shopt -s nullglob dotglob
    for entry in "$directory"/*; do
        [[ ! -L $entry ]] || return 2
        if [[ -d $entry ]]; then msm_service_cgroup_empty "$entry" || return $?; fi
    done
)

msm_service_stopped_state() {
    local group=${MSM_S[ControlGroup]} root found=0
    [[ ${MSM_S[ActiveState]} == inactive || ${MSM_S[ActiveState]} == failed ]] || return 1
    [[ ${MSM_S[MainPID]} == 0 ]] || return 1
    [[ -n $group ]] || return 0
    [[ $group == /* && $group != / && /$group/ != *'/../'* ]] || return 2
    for root in /sys/fs/cgroup /sys/fs/cgroup/systemd; do
        if [[ -e $root$group || -L $root$group ]]; then
            found=1
            msm_service_cgroup_empty "$root$group" || return $?
        fi
    done
    (( found == 1 )) || return 2
}

msm_service_running() {
    msm_service_state || return 2
    if [[ ${MSM_S[ActiveState]} == active && ${MSM_S[MainPID]} != 0 ]]; then return 0; fi
    if msm_service_stopped_state; then return 1; fi
    return 2
}

msm_service_assert_stopped() {
    msm_service_state && msm_service_stopped_state || msm_die 'Cannot confirm that Minecraft and all child processes have stopped.'
}

msm_service_stop() {
    local policy=${1:-clean}
    [[ $policy == clean || $policy == any ]] || msm_die 'Invalid stop policy.'
    timeout 330s systemctl stop "$MSM_UNIT" || msm_die 'Minecraft did not stop; no files may be replaced.'
    msm_service_assert_stopped
    [[ $policy == any || ${MSM_S[Result]} == success || -z ${MSM_S[Result]} ]] || msm_die 'Minecraft stopped abnormally. Inspect its logs before modifying data.'
}

msm_service_wait_ready() {
    local seconds=$1 deadline=$((SECONDS + $1)) invocation= current logs
    while (( SECONDS < deadline )); do
        msm_service_state || msm_die 'Cannot read Minecraft startup state.'
        [[ ${MSM_S[ActiveState]} != inactive && ${MSM_S[ActiveState]} != failed ]] || msm_die 'Minecraft exited before becoming ready.'
        current=${MSM_S[InvocationID]}
        if [[ -n $current && $current != 00000000000000000000000000000000 ]]; then
            [[ $current =~ ^[0-9a-fA-F]{32}$ ]] || msm_die 'Invalid systemd invocation ID.'
            [[ -z $invocation || $invocation == "$current" ]] || msm_die 'Minecraft restarted during startup.'
            invocation=$current
        fi
        if [[ -n $invocation && ${MSM_S[ActiveState]} == active && ${MSM_S[MainPID]} != 0 ]]; then
            logs=$(timeout 20s journalctl -u "$MSM_UNIT" --no-pager -o cat -n 500 "_SYSTEMD_INVOCATION_ID=$invocation") || msm_die 'Cannot read startup logs.'
            if [[ $logs =~ Done\ \([^$'\r\n']*\)\! ]]; then
                sleep 2
                msm_service_state || msm_die 'Cannot confirm readiness.'
                [[ ${MSM_S[ActiveState]} == active && ${MSM_S[MainPID]} != 0 && ${MSM_S[InvocationID]} == "$invocation" ]] || msm_die 'Minecraft exited immediately after its ready message.'
                return 0
            fi
        fi
        sleep 2
    done
    msm_die "Minecraft did not become ready within $seconds seconds."
}

msm_service_start() (
    local seconds id ticks boot expires temporary= attempted=0 status
    msm_start_cleanup() {
        status=$?
        trap - EXIT HUP INT TERM
        rm -f -- "$MSM_RUN/permit.json" || { msm_log 'ERROR: Cannot remove the startup permit.'; status=1; }
        [[ -z $temporary ]] || rm -f -- "$temporary" || true
        if (( status != 0 && attempted == 1 )); then
            if ! timeout 330s systemctl stop "$MSM_UNIT" || ! msm_service_state || ! msm_service_stopped_state; then
                msm_log 'ERROR: Startup failed and stopped state is unconfirmed. Do not replace server files.'
            fi
        fi
        exit "$status"
    }
    trap msm_start_cleanup EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    msm_have_lock "$$" || msm_die 'The current manager process does not hold manager.lock.'
    msm_trusted_file "$MSM_CONFIG/settings.json"
    msm_validate_settings "$MSM_CONFIG/settings.json"
    seconds=$(jq -r .startup_timeout "$MSM_CONFIG/settings.json")
    msm_directory "$MSM_RUN" 700 || msm_die 'Cannot prepare the startup-permit directory.'
    if [[ -e $MSM_JOURNAL || -L $MSM_JOURNAL ]]; then
        id=$(msm_starting_journal_id) || msm_die 'The active operation is not in a startup phase.'
        ticks=$(msm_proc_ticks "$$") || msm_die 'Cannot identify the manager process.'
        boot=$(cat /proc/sys/kernel/random/boot_id) || msm_die 'Cannot read the boot ID.'
        expires=$(( $(date +%s) + seconds + 30 ))
        temporary=$(mktemp "$MSM_RUN/.permit.XXXXXXXX") || msm_die 'Cannot prepare a startup permit.'
        jq -n --arg id "$id" --argjson pid "$$" --arg start_ticks "$ticks" --arg boot_id "$boot" \
            --argjson expires "$expires" '{id:$id,pid:$pid,start_ticks:$start_ticks,boot_id:$boot_id,expires:$expires}' >"$temporary" || msm_die 'Cannot write the startup permit.'
        msm_atomic_json "$temporary" "$MSM_RUN/permit.json" || msm_die 'Cannot publish the startup permit.'
    fi
    timeout 20s systemctl reset-failed "$MSM_UNIT" >/dev/null 2>&1 || true
    attempted=1
    timeout 60s systemctl start "$MSM_UNIT" || msm_die 'systemd could not start Minecraft.'
    msm_service_wait_ready "$seconds"
)
