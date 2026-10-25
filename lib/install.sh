#!/usr/bin/env bash
# First installation is resumable and never adopts an existing instance.

msm_install_usage() {
    cat <<'EOF'
Usage: msm install [options]
  --version VERSION        Minecraft release (default: latest stable)
  --loader LOADER          vanilla (default), fabric or neoforge
  --loader-version VERSION Stable loader version (default: latest)
  --neoforge VERSION       NeoForge stable version (default: latest)
  --template FILE          Mod template (default: selected loader template)
  --xms MEMORY             Initial heap (default: 1G)
  --xmx MEMORY             Maximum heap (default: 4G)
  --port PORT              Initial server port (default: 25565)
  --startup-timeout N      Startup deadline, 30..3600 seconds (default: 300)
  --accept-eula            Explicitly accept the Minecraft EULA
  --no-start               Install and enable the service without starting it now
EOF
}

msm_install_fresh() {
    local path
    [[ -d /run/systemd/system ]] || msm_die 'A systemd host is required.'
    case $(uname -m) in x86_64|aarch64) ;; *) msm_die 'Only x86_64 and aarch64 are supported.' ;; esac
    [[ $(systemctl show "$MSM_UNIT" -p LoadState --value) == not-found ]] || msm_die 'minecraft.service already exists; automatic takeover is disabled.'
    ! getent passwd minecraft >/dev/null || msm_die 'The minecraft account already exists.'
    ! getent group minecraft >/dev/null || msm_die 'The minecraft group already exists.'
    for path in "$MSM_BASE" "$MSM_CONFIG" "${MSM_JAVA%/*}" "$MSM_CODE" /usr/local/bin/msm /etc/systemd/system/minecraft.service; do
        [[ ! -e $path && ! -L $path ]] || msm_die "Target already exists: $path"
    done
}

msm_install_accounts() {
    local account_id actual
    account_id=$(jq -r .account_id "$MSM_JOURNAL")
    [[ $account_id =~ ^[0-9]+$ ]] && (( account_id >= 100 && account_id <= 999 )) || msm_die 'Invalid persisted account ID.'
    if ! getent group minecraft >/dev/null; then groupadd --system --gid "$account_id" minecraft || return; fi
    [[ $(getent group minecraft | cut -d: -f3) == "$account_id" && $(getent group "$account_id" | cut -d: -f1) == minecraft ]] || msm_die 'The minecraft group does not match the installation journal.'
    if ! getent passwd minecraft >/dev/null; then
        useradd --system --uid "$account_id" --gid "$account_id" --home-dir "$MSM_BASE" --no-create-home --shell /usr/sbin/nologin minecraft || return
    fi
    actual=$(getent passwd minecraft)
    [[ $(cut -d: -f3,4,6,7 <<<"$actual") == "$account_id:$account_id:$MSM_BASE:/usr/sbin/nologin" && $(getent passwd "$account_id" | cut -d: -f1) == minecraft ]] || msm_die 'The minecraft account does not match the installation journal.'
}

msm_install_code() {
    local folder file target
    msm_directory "$MSM_CODE" 755 || return
    for folder in bin lib libexec templates systemd; do
        msm_directory "$MSM_CODE/$folder" 755 || return
        for file in "$MSM_CODE_ROOT/$folder/"*; do
            [[ -f $file && ! -L $file ]] || msm_die 'Unexpected source package member.'
            target="$MSM_CODE/$folder/${file##*/}"
            if [[ $file != "$target" ]]; then
                install -m 644 "$file" "$target" || return
            fi
        done
    done
    if [[ -d $MSM_CODE_ROOT/bundled || -d $MSM_CODE_ROOT/auth/dist ]]; then
        local bundle auth_mc
        bundle=$(msm_auth_bundle) || return
        auth_mc=$(jq -er '.mc|strings|select(test("^[0-9]+\\.[0-9]+(\\.[0-9]+)?$"))' "$bundle/auth-manifest.json") || msm_die 'Invalid bundled auth Minecraft version.'
        msm_directory "$MSM_CODE/bundled" 755 || return
        for file in "$bundle/auth-manifest.json" "$bundle/auth-fabric-$auth_mc.jar" "$bundle/auth-neoforge-$auth_mc.jar"; do
            [[ -f $file && ! -L $file ]] || msm_die 'Missing bundled auth artifact.'
            target="$MSM_CODE/bundled/${file##*/}"
            [[ $file == "$target" ]] || install -m 644 "$file" "$target" || return
        done
    fi
    chmod 755 "$MSM_CODE/bin/msm" "$MSM_CODE/libexec/launch.sh" "$MSM_CODE/libexec/guard.sh" || return
    local temporary
    temporary=$(mktemp /usr/local/bin/.msm.XXXXXXXX) || return
    printf '#!/usr/bin/env bash\nexec /bin/bash /usr/local/lib/msm/bin/msm "$@"\n' >"$temporary" || return
    chmod 755 "$temporary" || return
    sync -f "$temporary" || return
    mv -fT "$temporary" /usr/local/bin/msm || return
    install -m 644 "$MSM_CODE/systemd/minecraft.service" /etc/systemd/system/minecraft.service || return
    sync -f "$MSM_CODE" || return
    sync -f /etc/systemd/system || return
    systemctl daemon-reload || return
    systemctl enable "$MSM_UNIT"
}

msm_install_resume() {
    local phase payload file temporary
    phase=$(jq -r .phase "$MSM_JOURNAL")
    case $phase in
        committed) msm_clear_journal; msm_log 'Installation was already committed. Check status and start if needed.'; return ;;
        preparing|assembled|starting) ;;
        *) msm_die "Unknown installation phase: $phase" ;;
    esac
    msm_directory "$MSM_BASE" 755 || return
    msm_directory "$MSM_STAGING" 711 || return
    msm_directory "$MSM_RECOVERY" 700 || return
    msm_directory "$MSM_CONFIG" 755 || return
    msm_directory "$MSM_BACKUPS" 700 || return
    msm_directory "${MSM_JAVA%/*}" 755 || return
    msm_directory "$MSM_JAVA" 755 || return
    msm_install_accounts || return
    if [[ $phase == preparing ]]; then
        msm_new_work || return
        jq .runtime "$MSM_JOURNAL" >"$MSM_WORK/runtime.json" || return
        jq .mods_lock "$MSM_JOURNAL" >"$MSM_WORK/mods.lock.json" || return
        msm_java_prepare "$MSM_WORK/runtime.json" "$MSM_WORK" || return
        msm_engine_prepare "$MSM_WORK/runtime.json" "$MSM_WORK" || return
        msm_download_mods "$MSM_WORK/mods.lock.json" "$MSM_WORK/engine/mods" || return
        printf 'eula=true\n' >"$MSM_WORK/engine/eula.txt" || return
        printf 'server-port=%s\nonline-mode=true\nenable-rcon=false\nenable-query=false\nlevel-name=world\nmotd=Minecraft Server\n' \
            "$(jq -r .port "$MSM_JOURNAL")" >"$MSM_WORK/engine/server.properties" || return
        payload=$MSM_WORK/engine
        sync -f "$payload" || return
        temporary=$(mktemp "$MSM_STATE/.assembled.XXXXXXXX") || return
        jq --arg payload "$payload" '.phase="assembled" | .payload=$payload' "$MSM_JOURNAL" >"$temporary" || return
        msm_atomic_json "$temporary" "$MSM_JOURNAL" || return
        rm -f "$temporary" || return
        phase=assembled
    fi
    if [[ $phase == assembled ]]; then
        payload=$(jq -r .payload "$MSM_JOURNAL")
        [[ $payload == "$MSM_STAGING/prepare."*/engine && ${payload#"$MSM_STAGING/"} =~ ^prepare\.[A-Za-z0-9]+/engine$ && ! -L $payload && ! -L ${payload%/*} && ! -L $MSM_SERVER ]] || msm_die 'Invalid installation payload path.'
        if [[ -d $payload ]]; then
            [[ ! -e $MSM_SERVER ]] || msm_die 'The live server path unexpectedly exists.'
            mv -T "$payload" "$MSM_SERVER" || return
            sync -f "$MSM_BASE" || return
        else
            [[ -d $MSM_SERVER ]] || msm_die 'Both installation payload and live server are missing.'
        fi
        for file in runtime settings mods mods_lock; do
            temporary=$(mktemp "$MSM_CONFIG/.install.XXXXXXXX") || return
            jq ".$file" "$MSM_JOURNAL" >"$temporary" || return
            if [[ $file == mods_lock ]]; then
                msm_atomic_json "$temporary" "$MSM_CONFIG/mods.lock.json" 644 || return
            else
                msm_atomic_json "$temporary" "$MSM_CONFIG/$file.json" 644 || return
            fi
            rm -f "$temporary" || return
        done
        msm_own_server || return
        msm_load_config || return
        msm_install_code || return
        msm_journal_phase starting || return
        phase=starting
    fi
    if [[ $phase == starting ]]; then
        if [[ $(jq -r .no_start "$MSM_JOURNAL") == false ]]; then
            msm_service_stop any || return
            msm_service_start || return
        fi
        msm_journal_phase committed || return
    fi
    msm_clear_journal || return
    msm_log 'Installation complete. Use: sudo msm status'
}

msm_install() {
    local mc=latest neo=latest loader=vanilla loader_explicit=false template= neo_option=false minimum=1G maximum=4G port=25565 deadline=300 accept=false no_start=false
    while (($#)); do
        case $1 in
            --help|-h) msm_install_usage; return ;;
            --version) [[ $# -ge 2 ]] || msm_die 'Missing version.'; mc=$2; shift 2 ;;
            --loader) [[ $# -ge 2 ]] || msm_die 'Missing loader.'; loader=$2; loader_explicit=true; shift 2 ;;
            --loader-version) [[ $# -ge 2 ]] || msm_die 'Missing loader version.'; neo=$2; shift 2 ;;
            --neoforge) [[ $# -ge 2 ]] || msm_die 'Missing NeoForge version.'; neo=$2; neo_option=true; shift 2 ;;
            --template) [[ $# -ge 2 ]] || msm_die 'Missing template path.'; template=$2; shift 2 ;;
            --xms) [[ $# -ge 2 ]] || msm_die 'Missing heap size.'; minimum=$2; shift 2 ;;
            --xmx) [[ $# -ge 2 ]] || msm_die 'Missing heap size.'; maximum=$2; shift 2 ;;
            --port) [[ $# -ge 2 ]] || msm_die 'Missing port.'; port=$2; shift 2 ;;
            --startup-timeout) [[ $# -ge 2 ]] || msm_die 'Missing timeout.'; deadline=$2; shift 2 ;;
            --accept-eula) accept=true; shift ;;
            --no-start) no_start=true; shift ;;
            *) msm_die "Unknown installation option: $1" ;;
        esac
    done
    [[ $accept == true ]] || msm_die 'Read https://aka.ms/MinecraftEULA and pass --accept-eula if you agree.'
    [[ $neo_option == false || $loader_explicit == true ]] || loader=neoforge
    [[ $loader == vanilla || $loader == neoforge || $loader == fabric ]] || msm_die 'Loader must be vanilla, neoforge or fabric.'
    [[ $loader != vanilla || $neo == latest ]] || msm_die 'Vanilla does not have a loader version.'
    [[ $neo_option == false || $loader == neoforge ]] || msm_die '--neoforge cannot be used with Fabric.'
    if [[ -f $MSM_JOURNAL ]]; then
        [[ $(jq -r .kind "$MSM_JOURNAL") == bootstrap ]] || msm_die 'Run msm recover for the pending transaction.'
        msm_install_resume
        return
    fi
    msm_install_fresh || return
    [[ $port =~ ^[1-9][0-9]{3,4}$ ]] && (( port >= 1024 && port <= 65535 )) || msm_die 'Port must be 1024..65535.'
    [[ $deadline =~ ^[1-9][0-9]{1,3}$ ]] && (( deadline >= 30 && deadline <= 3600 )) || msm_die 'Startup timeout must be 30..3600.'
    local planning account_id=100 temporary identity
    planning=$(mktemp -d) || return
    MSM_WORK=$planning
    [[ -n $template ]] || template=$(msm_mod_template "$loader") || return
    [[ -f $template && ! -L $template ]] || msm_die 'The mod template must be a regular file.'
    cp -- "$template" "$planning/mods.json" || return
    jq -e --arg loader "$loader" '.loader==$loader' "$planning/mods.json" >/dev/null || msm_die 'The mod template must match the selected loader.'
    jq -n --arg minimum "$minimum" --arg maximum "$maximum" --argjson deadline "$deadline" \
        '{schema:1,memory_min:$minimum,memory_max:$maximum,startup_timeout:$deadline}' >"$planning/settings.json" || return
    msm_validate_settings "$planning/settings.json" || return
    msm_resolve_runtime "$mc" "$neo" "$planning/runtime.json" "$loader" || return
    msm_runtime_plan_path "$planning/runtime.json" || return
    msm_resolve_mods "$planning/mods.json" "$(jq -r .mc "$planning/runtime.json")" '' "$planning/mods.lock.json" refresh || return
    while getent passwd "$account_id" >/dev/null || getent group "$account_id" >/dev/null; do ((account_id+=1)); done
    (( account_id <= 999 )) || msm_die 'No free system UID/GID in 100..999.'
    identity=$(msm_id)
    temporary=$(mktemp "$MSM_STATE/.bootstrap.XXXXXXXX") || return
    jq -n --arg id "$identity" --argjson account_id "$account_id" --argjson no_start "$no_start" --argjson port "$port" \
        --slurpfile runtime "$planning/runtime.json" --slurpfile settings "$planning/settings.json" \
        --slurpfile mods "$planning/mods.json" --slurpfile lock "$planning/mods.lock.json" \
        '{schema:1,id:$id,kind:"bootstrap",phase:"preparing",was_running:false,backup:null,account_id:$account_id,no_start:$no_start,port:$port,
          runtime:$runtime[0],settings:$settings[0],mods:$mods[0],mods_lock:$lock[0]}' >"$temporary" || return
    msm_atomic_json "$temporary" "$MSM_JOURNAL" || return
    rm -f "$temporary" || return
    rm -rf "$planning" || return
    msm_install_resume
}
