#!/usr/bin/env bash
# Shared paths and primitives. Production paths are not environment overrides.
MSM_VERSION=0.0.1
MSM_BASE=/srv/minecraft
MSM_SERVER=$MSM_BASE/server
MSM_STAGING=$MSM_BASE/.msm-staging
MSM_RECOVERY=$MSM_BASE/recovery
MSM_STATE=/var/lib/msm
MSM_CONFIG=/etc/msm
MSM_BACKUPS=/var/backups/minecraft
MSM_JAVA=/opt/minecraft/java
MSM_CODE=/usr/local/lib/msm
MSM_UNIT=minecraft.service
MSM_RUN=/run/msm
MSM_JOURNAL=$MSM_STATE/transaction.json
MSM_LOCK=$MSM_STATE/manager.lock
MSM_OWNER_UID=0
MSM_WORK=

msm_log() { printf '[msm] %s\n' "$*" >&2; }
msm_die() { msm_log "ERROR: $*"; exit 1; }
msm_id() { od -v -An -N16 -tx1 /dev/urandom | tr -d ' \n'; }

msm_require_root() { [[ $EUID == 0 ]] || msm_die 'Run this command as root.'; }

msm_require_tools() {
    local tool
    for tool in jq curl xmlstarlet unzip tar sha256sum sha512sum sha1sum flock \
        realpath find stat sync timeout runuser getent install systemctl journalctl; do
        command -v "$tool" >/dev/null || msm_die "Missing dependency: $tool. Run install.sh first."
    done
}

msm_directory() {
    local directory=$1 mode=${2:-700}
    [[ ! -L $directory ]] || msm_die "Refusing a symlink directory: $directory"
    (umask 077; mkdir -p -m 700 -- "$directory") || return
    [[ $(stat -c %u -- "$directory") == "$MSM_OWNER_UID" ]] || msm_die "Wrong directory owner: $directory"
    [[ $(( 8#$(stat -c %a -- "$directory") & 0022 )) == 0 ]] || msm_die "Writable management directory: $directory"
    chmod "$mode" -- "$directory" || return
}

msm_trusted_file() {
    local file=$1
    [[ -f $file && ! -L $file ]] || msm_die "Expected a regular file: $file"
    [[ $(stat -c %u -- "$file") == "$MSM_OWNER_UID" && $(stat -c %h -- "$file") == 1 ]] || msm_die "Unsafe file owner or link count: $file"
    [[ $(( 8#$(stat -c %a -- "$file") & 0022 )) == 0 ]] || msm_die "Writable management file: $file"
}

msm_atomic_json() {
    local source=$1 destination=$2 mode=${3:-600} temporary
    jq -e 'type == "object"' "$source" >/dev/null || msm_die "Invalid JSON object: $source"
    [[ ! -L $destination ]] || msm_die "Refusing a symlink destination: $destination"
    temporary=$(mktemp "${destination%/*}/.msm-json.XXXXXXXX") || return
    if ! cat -- "$source" >"$temporary" || ! chmod "$mode" "$temporary" || ! sync -f "$temporary"; then
        rm -f -- "$temporary"
        return 1
    fi
    mv -fT -- "$temporary" "$destination" || return
    sync -f "${destination%/*}"
}

msm_journal_phase() {
    local phase=$1 temporary
    temporary=$(mktemp "$MSM_STATE/.phase.XXXXXXXX") || return
    jq --arg phase "$phase" '.phase = $phase | if $phase == "applying" then .restore_required = true else . end' "$MSM_JOURNAL" >"$temporary" || return
    msm_atomic_json "$temporary" "$MSM_JOURNAL" || return
    rm -f -- "$temporary"
}

msm_clear_journal() {
    rm -f -- "$MSM_JOURNAL" || return
    sync -f "$MSM_STATE"
}

msm_new_work() {
    msm_directory "$MSM_STAGING" 711 || return
    MSM_WORK=$(mktemp -d "$MSM_STAGING/prepare.XXXXXXXX") || return
    chmod 711 "$MSM_WORK"
}

msm_idle() {
    [[ ! -e $MSM_JOURNAL && ! -L $MSM_JOURNAL ]] || msm_die 'An operation is unfinished. Run: sudo msm recover'
    [[ ! -e $MSM_STATE/restore.json && ! -L $MSM_STATE/restore.json ]] || msm_die 'An interrupted restore requires recovery.'
}

msm_memory_valid() { [[ $1 =~ ^[1-9][0-9]{0,6}[MG]$ ]]; }
msm_memory_mib() {
    local value=$1
    if [[ $value == *G ]]; then printf '%s\n' "$(( ${value%G} * 1024 ))"; else printf '%s\n' "${value%M}"; fi
}

msm_validate_settings() {
    local file=$1 minimum maximum
    jq -e '.schema == 1 and (.memory_min|type == "string") and (.memory_max|type == "string") and
        (.startup_timeout|type == "number" and floor == . and . >= 30 and . <= 3600)' "$file" >/dev/null || msm_die 'Invalid settings.json.'
    minimum=$(jq -r .memory_min "$file") maximum=$(jq -r .memory_max "$file")
    msm_memory_valid "$minimum" && msm_memory_valid "$maximum" || msm_die 'Memory values must use integer M/G units.'
    (( $(msm_memory_mib "$minimum") <= $(msm_memory_mib "$maximum") )) || msm_die 'memory_min exceeds memory_max.'
}

msm_validate_runtime() {
    local file=$1 java_home version arguments loader
    jq -e '.schema == 1 and (.mc|type == "string" and test("^[A-Za-z0-9._+-]+$")) and
        (.java_home|type == "string") and (.loader==null or (.loader|type=="string")) and
        (if (.loader // "neoforge") == "neoforge" then
          (.neoforge|type == "string" and test("^[0-9]+(\\.[0-9]+){2,3}$")) and (.unix_args|type == "string")
         elif .loader == "fabric" then
          (.fabric|type == "string" and test("^[0-9]+\\.[0-9]+\\.[0-9]+$")) and
          (.fabric_installer|type == "string" and test("^[0-9]+\\.[0-9]+\\.[0-9]+$")) and .launch_jar == "fabric-server-launch.jar"
         elif .loader == "vanilla" then .launch_jar == "server.jar"
         else false end)' "$file" >/dev/null || msm_die 'Invalid runtime.json.'
    java_home=$(jq -r .java_home "$file") loader=$(jq -r '.loader // "neoforge"' "$file")
    [[ $java_home == "$MSM_JAVA/"* && ${java_home#"$MSM_JAVA/"} =~ ^java-[0-9]+-[0-9a-f]{16}$ ]] || msm_die 'Java path is outside the managed cache.'
    if [[ $loader == neoforge ]]; then
        version=$(jq -r .neoforge "$file") arguments=$(jq -r .unix_args "$file")
        [[ $arguments == "libraries/net/neoforged/neoforge/$version/unix_args.txt" ]] || msm_die 'NeoForge argument path does not match the selected version.'
    fi
}

msm_runtime_launch_file() {
    jq -er 'if .loader == "fabric" or .loader == "vanilla" then .launch_jar else .unix_args end' "$1"
}

msm_mod_template() {
    case $1 in
        vanilla) printf '%s/templates/mods-vanilla.json\n' "$MSM_CODE_ROOT" ;;
        neoforge) printf '%s/templates/mods-neoforge.json\n' "$MSM_CODE_ROOT" ;;
        fabric) printf '%s/templates/mods-fabric.json\n' "$MSM_CODE_ROOT" ;;
        *) msm_die 'Loader must be vanilla, neoforge or fabric.' ;;
    esac
}

msm_load_config() {
    local file
    for file in runtime.json settings.json mods.json mods.lock.json; do msm_trusted_file "$MSM_CONFIG/$file" || return; done
    msm_validate_runtime "$MSM_CONFIG/runtime.json" || return
    msm_validate_settings "$MSM_CONFIG/settings.json" || return
    local java_home args
    java_home=$(jq -r .java_home "$MSM_CONFIG/runtime.json") args=$(msm_runtime_launch_file "$MSM_CONFIG/runtime.json")
    [[ -x $java_home/bin/java && ! -L $java_home && -s $MSM_SERVER/$args && ! -L $MSM_SERVER/$args ]] || msm_die 'The installed Java or Minecraft runtime is incomplete.'
}

msm_validate_properties() {
    # Use a deliberately restricted, unambiguous subset for property keys.
    # Values may contain escapes, but continuation lines are not supported.
    local line key value tail backslashes world=world
    [[ -f $MSM_SERVER/server.properties && ! -L $MSM_SERVER/server.properties ]] || msm_die 'Missing regular server.properties.'
    while IFS= read -r line || [[ -n $line ]]; do
        line=${line%$'\r'}
        line="${line#"${line%%[!$' \t\f']*}"}"
        [[ -n $line && $line != \#* && $line != \!* ]] || continue
        tail=$line backslashes=0
        while [[ $tail == *\\ ]]; do tail=${tail%\\}; ((backslashes+=1)); done
        (( backslashes % 2 == 0 )) || msm_die 'server.properties continuation lines are unsupported; use one line per property.'
        key=${line%%[$' \t\f'=:]*}
        [[ $key =~ ^[A-Za-z0-9_.-]+$ ]] || msm_die 'Use plain, unescaped property keys in server.properties.'
        value=${line#"$key"}
        value="${value#"${value%%[!$' \t\f']*}"}"
        [[ $value != [=:]* ]] || value=${value:1}
        value="${value#"${value%%[!$' \t\f']*}"}"
        if [[ $key == level-name ]]; then
            [[ $value =~ ^[A-Za-z0-9_-]+$ ]] || msm_die 'level-name must be a safe single directory name.'
            case ${value,,} in libraries|versions|mods|config|defaultconfigs|logs|backups|recovery|cache|debug|downloads|crash-reports) msm_die 'level-name conflicts with a managed directory.' ;; esac
            world=$value
        fi
    done <"$MSM_SERVER/server.properties"
    [[ ! -L $MSM_SERVER/$world ]] || msm_die 'The world directory cannot be a symlink.'
}

msm_check_mods() {
    local folder=$MSM_SERVER/mods file name algorithm expected listed
    [[ -d $folder && ! -L $folder ]] || msm_die 'mods must be a regular directory.'
    while IFS= read -r -d '' file; do
        name=${file##*/}
        [[ -f $file && ! -L $file && $(stat -c %h "$file") == 1 ]] || msm_die "Invalid mod file: $name"
        listed=$(jq --arg name "$name" '[.mods[] | select(.filename == $name)] | length' "$MSM_CONFIG/mods.lock.json")
        [[ $listed == 1 ]] || msm_die "Unmanaged JAR: $name. Move it out manually before sync/update."
        algorithm=$(jq -r --arg name "$name" '.mods[]|select(.filename==$name)|if .sha512 then "sha512" else "sha1" end' "$MSM_CONFIG/mods.lock.json")
        expected=$(jq -r --arg name "$name" --arg algorithm "$algorithm" '.mods[]|select(.filename==$name)|.[$algorithm]' "$MSM_CONFIG/mods.lock.json")
        [[ $("${algorithm}sum" "$file" | cut -d' ' -f1) == "$expected" ]] || msm_die "A managed JAR was modified: $name"
    done < <(find -P "$folder" -mindepth 1 -maxdepth 1 -iname '*.jar' -print0)
    while IFS= read -r name; do
        [[ $name =~ ^[^/\\]+\.jar$ && -f $folder/$name && ! -L $folder/$name ]] || msm_die "Missing or invalid managed JAR: $name"
    done < <(jq -r '.mods[].filename' "$MSM_CONFIG/mods.lock.json")
}
