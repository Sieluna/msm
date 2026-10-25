#!/usr/bin/env bash
# Basic server operations. Configuration files are edited manually.

msm_usage() {
    cat <<'EOF'
msm 0.0.1 - single-instance Minecraft server manager (Vanilla, Fabric or NeoForge)

Usage:
  msm install [--version MC] [--loader vanilla|fabric|neoforge] [--loader-version VERSION] --accept-eula [options]
  msm plan [--version MC] [--loader vanilla|fabric|neoforge] [--loader-version VERSION] [--template FILE]
  msm start | stop | restart | status
  msm logs [-f]
  msm update [MC] [--loader-version VERSION] [--dry-run]
  msm mods list
  msm mods sync [--locked] [--dry-run]
  msm backup
  msm backups
  msm restore BACKUP_NAME --yes
  msm recover
  msm --help | --version

Edit /etc/msm/settings.json and /etc/msm/mods.json manually.
Install and plan default to Vanilla. All commands select the latest stable Minecraft.
Updates retain the installed loader. --neoforge VERSION remains supported.
Edit server.properties and mod configuration files while the server is stopped.
No file editor, arbitrary file API, console, timer, or web panel is installed.
EOF
}

msm_plan() {
    local mc=latest neo=latest loader=vanilla loader_explicit=false template= neo_option=false
    while (($#)); do
        case $1 in
            --version) [[ $# -ge 2 ]] || msm_die 'Missing Minecraft version.'; mc=$2; shift 2 ;;
            --loader) [[ $# -ge 2 ]] || msm_die 'Missing loader.'; loader=$2; loader_explicit=true; shift 2 ;;
            --loader-version) [[ $# -ge 2 ]] || msm_die 'Missing loader version.'; neo=$2; shift 2 ;;
            --neoforge) [[ $# -ge 2 ]] || msm_die 'Missing NeoForge version.'; neo=$2; neo_option=true; shift 2 ;;
            --template) [[ $# -ge 2 ]] || msm_die 'Missing template path.'; template=$2; shift 2 ;;
            --help|-h) printf 'Usage: msm plan [--version MC] [--loader vanilla|fabric|neoforge] [--loader-version VERSION] [--template FILE]\n'; return ;;
            *) msm_die "Unknown plan option: $1" ;;
        esac
    done
    [[ $neo_option == false || $loader_explicit == true ]] || loader=neoforge
    [[ $loader == vanilla || $loader == neoforge || $loader == fabric ]] || msm_die 'Loader must be vanilla, neoforge or fabric.'
    [[ $loader != vanilla || $neo == latest ]] || msm_die 'Vanilla does not have a loader version.'
    [[ $neo_option == false || $loader == neoforge ]] || msm_die '--neoforge cannot be used with Fabric.'
    [[ -n $template ]] || template=$(msm_mod_template "$loader") || return
    [[ -f $template && ! -L $template ]] || msm_die 'The mod template must be a regular file.'
    jq -e --arg loader "$loader" '.loader==$loader' "$template" >/dev/null || msm_die 'The mod template must match the selected loader.'
    MSM_WORK=$(mktemp -d) || return
    msm_resolve_runtime "$mc" "$neo" "$MSM_WORK/runtime.json" "$loader" || return
    msm_runtime_plan_path "$MSM_WORK/runtime.json" || return
    msm_resolve_mods "$template" "$(jq -r .mc "$MSM_WORK/runtime.json")" '' "$MSM_WORK/mods.lock.json" refresh || return
    jq -n --slurpfile runtime "$MSM_WORK/runtime.json" --slurpfile mods "$MSM_WORK/mods.lock.json" '{runtime:$runtime[0],mods:$mods[0]}'
}

msm_apply_mods() {
    local lock=$1 staged=$2 name
    while IFS= read -r name; do
        [[ $name =~ ^[^/\\]+\.jar$ ]] || msm_die 'Invalid locked JAR name.'
        [[ -f $MSM_SERVER/mods/$name && ! -L $MSM_SERVER/mods/$name ]] || msm_die 'Managed JAR changed during preparation.'
        rm -- "$MSM_SERVER/mods/$name" || return
    done < <(jq -r '.mods[].filename' "$MSM_CONFIG/mods.lock.json")
    while IFS= read -r name; do
        [[ $name =~ ^[^/\\]+\.jar$ && -f $staged/$name && ! -L $staged/$name ]] || msm_die 'Invalid staged JAR.'
        [[ ! -e $MSM_SERVER/mods/$name && ! -L $MSM_SERVER/mods/$name ]] || msm_die 'New JAR collides with an existing file.'
        install -m 640 "$staged/$name" "$MSM_SERVER/mods/$name" || return
    done < <(jq -r '.mods[].filename' "$lock")
    msm_atomic_json "$lock" "$MSM_CONFIG/mods.lock.json" 644
}

msm_update() {
    local kind=$1; shift
    local mc= neo=latest loader neo_option=false dry=false mode=refresh
    while (($#)); do
        case $1 in
            --loader-version) [[ $kind == runtime && $# -ge 2 ]] || msm_die 'Unexpected --loader-version option.'; neo=$2; shift 2 ;;
            --neoforge) [[ $kind == runtime && $# -ge 2 ]] || msm_die 'Unexpected --neoforge option.'; neo=$2; neo_option=true; shift 2 ;;
            --dry-run) dry=true; shift ;;
            --locked) [[ $kind == mods ]] || msm_die '--locked only applies to mods sync.'; mode=locked; shift ;;
            --help|-h) msm_usage; return ;;
            -*) msm_die "Unknown update option: $1" ;;
            *) [[ $kind == runtime && -z $mc ]] || msm_die 'Unexpected positional argument.'; mc=$1; shift ;;
        esac
    done
    msm_load_config || return
    msm_validate_properties || return
    msm_check_mods || return
    loader=$(jq -r '.loader // "neoforge"' "$MSM_CONFIG/runtime.json")
    [[ $neo_option == false || $loader == neoforge ]] || msm_die '--neoforge cannot be used with Fabric.'
    jq -e --arg loader "$loader" '.loader==$loader' "$MSM_CONFIG/mods.json" >/dev/null || msm_die 'The mod template must match the installed loader.'
    if [[ -z $mc ]]; then
        if [[ $kind == runtime ]]; then mc=latest; else mc=$(jq -r .mc "$MSM_CONFIG/runtime.json"); fi
    fi
    msm_new_work || return
    # The exact input template is copied before resolving and committed later.
    cp -- "$MSM_CONFIG/mods.json" "$MSM_WORK/mods.json" || return
    if [[ $kind == runtime ]]; then
        msm_resolve_runtime "$mc" "$neo" "$MSM_WORK/runtime.json" "$loader" || return
        msm_runtime_plan_path "$MSM_WORK/runtime.json" || return
        local old_time new_time
        old_time=$(date -d "$(jq -r .release_time "$MSM_CONFIG/runtime.json")" +%s) || return
        new_time=$(date -d "$(jq -r .release_time "$MSM_WORK/runtime.json")" +%s) || return
        (( new_time >= old_time )) || msm_die 'Direct Minecraft downgrade is disabled. Restore a matching complete backup instead.'
        mc=$(jq -r .mc "$MSM_WORK/runtime.json")
    else
        cp -- "$MSM_CONFIG/runtime.json" "$MSM_WORK/runtime.json" || return
    fi
    msm_resolve_mods "$MSM_WORK/mods.json" "$mc" "$MSM_CONFIG/mods.lock.json" "$MSM_WORK/mods.lock.json" "$mode" || return
    jq -r '"Minecraft: \(.mc)  Loader: \(.loader // "neoforge") \(.fabric // .neoforge)  Java: \(.java_major)"' "$MSM_WORK/runtime.json"
    jq -r '.mods[] | "\(.slug)  \(.version_number)  \(.filename)"' "$MSM_WORK/mods.lock.json"
    [[ $dry == false ]] || return 0
    if [[ $kind == runtime ]]; then
        msm_java_prepare "$MSM_WORK/runtime.json" "$MSM_WORK" || return
        msm_engine_prepare "$MSM_WORK/runtime.json" "$MSM_WORK" || return
    fi
    msm_download_mods "$MSM_WORK/mods.lock.json" "$MSM_WORK/mods" || return
    msm_transaction_begin "pre-$kind-update" || return
    msm_journal_phase applying || return
    # Recheck the original JARs after stopping, before replacing any of them.
    msm_check_mods || return
    if [[ $kind == runtime ]]; then
        local name target
        for name in libraries versions server.jar fabric-server-launch.jar fabric-server-launcher.properties .fabric; do
            target=$MSM_SERVER/$name
            [[ ! -L $target ]] || msm_die 'An engine path is a symlink.'
            if [[ -d $target ]]; then
                [[ -z $(find -P "$target" \( -name level.dat -o -name level.dat_old \) -print -quit) ]] || msm_die 'World data found inside an engine directory.'
                rm -rf -- "$target" || return
            elif [[ -e $target ]]; then
                [[ -f $target ]] || msm_die 'An engine path has an unexpected type.'
                rm -- "$target" || return
            fi
            if [[ -e $MSM_WORK/engine/$name ]]; then
                cp -a -- "$MSM_WORK/engine/$name" "$target" || return
            fi
        done
    fi
    msm_apply_mods "$MSM_WORK/mods.lock.json" "$MSM_WORK/mods" || return
    msm_atomic_json "$MSM_WORK/runtime.json" "$MSM_CONFIG/runtime.json" 644 || return
    msm_atomic_json "$MSM_WORK/mods.json" "$MSM_CONFIG/mods.json" 644 || return
    msm_own_server || return
    msm_transaction_finish
}

msm_restore_command() {
    [[ $# == 2 && $2 == --yes ]] || msm_die 'Usage: msm restore BACKUP_NAME --yes'
    local archive=$1
    [[ $archive == /* ]] || archive=$MSM_BACKUPS/$archive
    msm_archive_verify "$archive" || return
    msm_transaction_begin pre-restore || return
    msm_journal_phase applying || return
    msm_restore_tree "$archive" || return
    msm_transaction_finish
}

msm_dispatch() {
    local command=$1; shift
    case $command in
        install) msm_install "$@" ;;
        plan) msm_plan "$@" ;;
        start) [[ $# == 0 ]] || msm_die 'Usage: msm start'; msm_load_config; msm_validate_properties; msm_service_start ;;
        stop) [[ $# == 0 ]] || msm_die 'Usage: msm stop'; msm_service_stop any ;;
        restart) [[ $# == 0 ]] || msm_die 'Usage: msm restart'; msm_load_config; msm_validate_properties; msm_service_stop clean; msm_service_start ;;
        status)
            [[ $# == 0 ]] || msm_die 'Usage: msm status'
            if [[ -f $MSM_CONFIG/runtime.json ]]; then jq '{mc,loader:(.loader // "neoforge"),neoforge,fabric,java_major,java_home}' "$MSM_CONFIG/runtime.json"; fi
            systemctl status "$MSM_UNIT" --no-pager || [[ $? == 3 ]]
            [[ ! -f $MSM_JOURNAL ]] || msm_log 'An operation is unfinished. Run: sudo msm recover'
            ;;
        logs) [[ $# == 0 || ( $# == 1 && $1 == -f ) ]] || msm_die 'Usage: msm logs [-f]'; journalctl -u "$MSM_UNIT" -n 100 --no-pager "$@" ;;
        update) msm_update runtime "$@" ;;
        mods)
            case ${1:-} in
                sync) shift; msm_update mods "$@" ;;
                list) [[ $# == 1 ]] || msm_die 'Usage: msm mods list'; jq -r '.mods[] | "\(.slug)  \(.version_number)  \(.filename)"' "$MSM_CONFIG/mods.lock.json" ;;
                *) msm_die 'Usage: msm mods list | sync [--locked] [--dry-run]' ;;
            esac
            ;;
        backup) [[ $# == 0 ]] || msm_die 'Usage: msm backup'; msm_transaction_begin backup; msm_transaction_finish ;;
        backups) [[ $# == 0 ]] || msm_die 'Usage: msm backups'; find "$MSM_BACKUPS" -maxdepth 1 -type f -name '*.tar.gz' -printf '%f\n' | sort -r ;;
        restore) msm_restore_command "$@" ;;
        recover) [[ $# == 0 ]] || msm_die 'Usage: msm recover'; msm_recover ;;
        *) msm_die "Unknown command: $command. Use msm --help." ;;
    esac
}
