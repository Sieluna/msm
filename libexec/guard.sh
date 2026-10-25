#!/bin/bash
set -Eeuo pipefail
source /usr/local/lib/msm/lib/common.sh
source /usr/local/lib/msm/lib/service.sh

[[ $# == 0 && $EUID == 0 ]] || msm_die 'The startup guard requires root and accepts no arguments.'
msm_service_private_dir "$MSM_STATE" || msm_die 'Unsafe manager state directory.'
[[ ! -e $MSM_STATE/restore.json && ! -L $MSM_STATE/restore.json ]] || msm_die 'An unfinished restore blocks this startup.'
[[ -e $MSM_JOURNAL || -L $MSM_JOURNAL ]] || exit 0
id=$(msm_starting_journal_id) || msm_die 'An unfinished operation blocks this startup.'
msm_service_private_dir "$MSM_RUN" || msm_die 'Unsafe startup-permit directory.'
permit=$MSM_RUN/permit.json
msm_trusted_file "$permit"
[[ $(stat -c %a -- "$permit") == 600 ]] || msm_die 'Unsafe startup-permit permissions.'
jq -e --arg id "$id" 'type == "object" and .id == $id and
    (.pid|type == "number" and floor == . and . > 0 and . <= 2147483647) and
    (.start_ticks|type == "string" and test("^[0-9]+$")) and
    (.boot_id|type == "string" and test("^[0-9a-f-]{36}$")) and
    (.expires|type == "number" and floor == . and . > 0 and . < 9007199254740991)' "$permit" >/dev/null || msm_die 'Invalid startup permit.'
pid=$(jq -r .pid "$permit")
ticks=$(jq -r .start_ticks "$permit")
boot=$(jq -r .boot_id "$permit")
expires=$(jq -r .expires "$permit")
now=$(date +%s)
(( expires > now && expires <= now + 3700 )) || msm_die 'The startup permit is expired or outside its allowed lifetime.'
[[ $boot == "$(cat /proc/sys/kernel/random/boot_id)" ]] || msm_die 'The startup permit belongs to another boot.'
[[ $ticks == "$(msm_proc_ticks "$pid")" ]] || msm_die 'The startup permit owner is gone or its PID was reused.'
msm_have_lock "$pid" || msm_die 'The startup permit owner no longer holds manager.lock.'
[[ $ticks == "$(msm_proc_ticks "$pid")" ]] || msm_die 'The startup permit owner changed during validation.'
