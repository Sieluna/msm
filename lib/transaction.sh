#!/usr/bin/env bash
# Failed operations keep a durable journal; recover restores the full snapshot.

msm_transaction_begin() {
    local operation=$1 running=false status=0 identity archive temporary
    msm_idle || return
    msm_load_config || return
    msm_validate_properties || return
    msm_service_running || status=$?
    case $status in 0) running=true ;; 1) ;; *) msm_die 'Cannot determine whether the service is running.' ;; esac
    identity=$(msm_id)
    archive="$MSM_BACKUPS/$operation-$(date -u +%Y%m%dT%H%M%S)-$identity.tar.gz"
    temporary=$(mktemp "$MSM_STATE/.transaction.XXXXXXXX") || return
    jq -n --arg id "$identity" --arg operation "$operation" --arg backup "$archive" --argjson running "$running" \
        '{schema:1,id:$id,kind:"transaction",operation:$operation,phase:"prepared",was_running:$running,restore_required:false,backup:$backup}' >"$temporary" || return
    msm_atomic_json "$temporary" "$MSM_JOURNAL" || return
    rm -f "$temporary" || return
    if [[ $running == true ]]; then msm_service_stop clean || return; fi
    msm_service_assert_stopped || return
    msm_journal_phase stopped || return
    msm_archive_create "$archive" || return
    msm_archive_verify "$archive" || return
    msm_journal_phase snapshot_ready || return
    msm_log "Snapshot: $archive"
}

msm_transaction_finish() {
    if [[ $(jq -r .was_running "$MSM_JOURNAL") == true ]]; then
        msm_journal_phase starting || return
        msm_service_start || return
    else
        msm_service_assert_stopped || return
    fi
    msm_journal_phase committed || return
    # A cleanup error after this point must never undo committed data.
    msm_clear_journal || return
    msm_log 'Operation committed.'
}

msm_restore_tree() {
    local archive=$1 restore=$MSM_STATE/restore.json stage retired temporary
    msm_service_assert_stopped || return
    if [[ -e $restore || -L $restore ]]; then
        msm_trusted_file "$restore" || return
        [[ $(jq -r .archive "$restore") == "$archive" ]] || msm_die 'Restore journal refers to a different archive.'
        stage=$(jq -r .stage "$restore") retired=$(jq -r .retired "$restore")
        [[ $stage == "$MSM_STAGING/restore."* && ${stage#"$MSM_STAGING/"} != */* && $retired == "$MSM_RECOVERY/replaced-"* && ${retired#"$MSM_RECOVERY/"} != */* ]] || msm_die 'Restore journal paths are invalid.'
    else
        stage=$(mktemp -d "$MSM_STAGING/restore.XXXXXXXX") || return
        # The extractor requires a new destination.
        msm_archive_extract "$archive" "$stage/payload" || return
        msm_validate_runtime "$stage/payload/manager/runtime.json" || return
        msm_validate_settings "$stage/payload/manager/settings.json" || return
        (MSM_SERVER="$stage/payload/server"; msm_validate_properties) || return
        [[ -x $(jq -r .java_home "$stage/payload/manager/runtime.json")/bin/java ]] || msm_die 'The Java cache required by the backup is missing.'
        retired="$MSM_RECOVERY/replaced-$(date -u +%Y%m%dT%H%M%S)-$(msm_id)"
        temporary=$(mktemp "$MSM_STATE/.restore.XXXXXXXX") || return
        jq -n --arg archive "$archive" --arg stage "$stage" --arg retired "$retired" \
            '{schema:1,archive:$archive,stage:$stage,retired:$retired}' >"$temporary" || return
        sync -f "$stage" || return
        msm_atomic_json "$temporary" "$restore" || return
        rm -f "$temporary" || return
    fi
    [[ ! -L $stage && ! -L $retired && ! -L $MSM_SERVER && ! -L $stage/payload/server ]] || msm_die 'A restore path is a symlink.'
    if [[ -d $stage/payload/server ]]; then
        if [[ -e $MSM_SERVER ]]; then
            [[ ! -e $retired ]] || msm_die 'Ambiguous restore directories; preserving all copies.'
            mv -T "$MSM_SERVER" "$retired" || return
            sync -f "$MSM_BASE" || return
        else
            [[ -d $retired ]] || msm_die 'Both live and retired data are missing.'
        fi
        mv -T "$stage/payload/server" "$MSM_SERVER" || return
        sync -f "$MSM_BASE" || return
    else
        [[ -d $MSM_SERVER && -d $retired ]] || msm_die 'The restore directory swap is incomplete.'
    fi
    local file
    for file in runtime.json settings.json mods.json mods.lock.json; do
        msm_atomic_json "$stage/payload/manager/$file" "$MSM_CONFIG/$file" 644 || return
    done
    msm_own_server || return
    msm_validate_properties || return
    rm -- "$restore" || return
    sync -f "$MSM_STATE" || return
    rm -rf -- "$stage" || return
    msm_log "Previous data retained at: $retired"
}

msm_recover() {
    [[ -e $MSM_JOURNAL || -L $MSM_JOURNAL ]] || {
        [[ ! -e $MSM_STATE/restore.json ]] || msm_die 'Orphan restore journal; preserve the directories for manual inspection.'
        msm_log 'No unfinished operation.'
        return
    }
    msm_trusted_file "$MSM_JOURNAL" || return
    jq -e '.schema==1 and (.id|type=="string" and test("^[0-9a-f]{32}$")) and
        (.was_running|type=="boolean")' "$MSM_JOURNAL" >/dev/null || msm_die 'Invalid operation journal.'
    if [[ $(jq -r .kind "$MSM_JOURNAL") == bootstrap ]]; then msm_install_resume; return; fi
    [[ $(jq -r .kind "$MSM_JOURNAL") == transaction ]] || msm_die 'Unknown journal kind.'
    local phase archive
    phase=$(jq -r .phase "$MSM_JOURNAL") archive=$(jq -r .backup "$MSM_JOURNAL")
    case $phase in
        committed|rolled_back)
            [[ ! -e $MSM_STATE/restore.json && ! -L $MSM_STATE/restore.json ]] || msm_die 'A terminal transaction has an unexpected restore journal.'
            msm_clear_journal; msm_log 'Terminal journal cleared. Check status and start the service if needed.'; return ;;
        prepared|stopped|snapshot_ready) ;;
        applying|starting|restoring|rollback_starting) ;;
        *) msm_die "Unknown transaction phase: $phase" ;;
    esac
    msm_service_stop any || return
    msm_service_assert_stopped || return
    jq -e '.restore_required|type=="boolean"' "$MSM_JOURNAL" >/dev/null || msm_die 'Missing transaction restore flag.'
    if [[ $(jq -r .restore_required "$MSM_JOURNAL") == true ]]; then
            # Complete an interrupted explicit restore before returning to the
            # transaction's original snapshot. Each swap remains restartable.
            if [[ -f $MSM_STATE/restore.json ]]; then
                msm_restore_tree "$(jq -r .archive "$MSM_STATE/restore.json")" || return
            fi
            msm_journal_phase restoring || return
            msm_restore_tree "$archive" || return
    fi
    if [[ $(jq -r .was_running "$MSM_JOURNAL") == true ]]; then
        msm_journal_phase rollback_starting || return
        msm_service_start || return
    fi
    msm_journal_phase rolled_back || return
    msm_clear_journal || return
    msm_log 'The previous data and service state have been restored.'
}
