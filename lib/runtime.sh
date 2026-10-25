#!/usr/bin/env bash
# Prepare verified runtime files before touching the live server.

msm_runtime_plan_path() {
    local plan=$1 temporary major digest
    major=$(jq -r .java_major "$plan") digest=$(jq -r .java.sha256 "$plan")
    [[ $major =~ ^[0-9]+$ && $digest =~ ^[0-9a-f]{64}$ ]] || msm_die 'Invalid Java metadata.'
    temporary=$(mktemp "${plan%/*}/.runtime.XXXXXXXX") || return
    jq --arg java_home "$MSM_JAVA/java-$major-${digest:0:16}" '.java_home = $java_home' "$plan" >"$temporary" || return
    mv -fT "$temporary" "$plan" || return
    msm_validate_runtime "$plan"
}

msm_java_prepare() {
    local plan=$1 work=$2 java_home digest url size member link resolved
    java_home=$(jq -r .java_home "$plan") digest=$(jq -r .java.sha256 "$plan")
    if [[ -e $java_home || -L $java_home ]]; then
        [[ -d $java_home && ! -L $java_home && -x $java_home/bin/java ]] || msm_die 'An existing Java cache is incomplete.'
        msm_trusted_file "$java_home/.msm-sha256" || return
        [[ $(cat "$java_home/.msm-sha256") == "$digest" ]] || msm_die 'The Java cache does not match its lock.'
        return
    fi
    msm_directory "$MSM_JAVA" 755 || return
    url=$(jq -r .java.url "$plan") size=$(jq -r .java.size "$plan")
    msm_download "$url" "$work/java.tar.gz" sha256 "$digest" "$size" || return
    chmod 644 "$work/java.tar.gz" || return
    # GNU tar rejects traversal. Check the listing before unprivileged extraction.
    tar -tzf "$work/java.tar.gz" >"$work/java.list" || return
    local top= name
    while IFS= read -r member; do
        name=${member%/}
        [[ -n $name && $name != /* && $name != *\\* && $name != *$'\t'* && /$name/ != */../* && /$name/ != */./* ]] || msm_die 'Unsafe Java archive member.'
        [[ -n $top ]] || top=${name%%/*}
        [[ ${name%%/*} == "$top" ]] || msm_die 'Java archive has multiple root directories.'
    done <"$work/java.list"
    mkdir "$work/java-extract" || return
    chown minecraft:minecraft "$work/java-extract" || return
    chmod 750 "$work/java-extract" || return
    runuser -u minecraft -- tar --extract --gzip --file="$work/java.tar.gz" --directory="$work/java-extract" \
        --strip-components=1 --no-same-owner --no-same-permissions --delay-directory-restore || return
    while IFS= read -r -d '' link; do
        resolved=$(realpath -e -- "$link") || msm_die 'Java archive contains a dangling link.'
        [[ $resolved == "$work/java-extract/"* ]] || msm_die 'Java archive contains an external link.'
    done < <(find -P "$work/java-extract" -type l -print0)
    [[ -x $work/java-extract/bin/java && ! -L $work/java-extract/bin/java ]] || msm_die 'Java archive lacks an executable bin/java.'
    [[ -z $(find -P "$work/java-extract" \( ! -type f ! -type d ! -type l \) -print -quit) ]] || msm_die 'Java archive contains a special file.'
    chown -hR root:root "$work/java-extract" || return
    chmod 755 "$work/java-extract" || return
    printf '%s\n' "$digest" >"$work/java-extract/.msm-sha256" || return
    chmod 600 "$work/java-extract/.msm-sha256" || return
    sync -f "$work/java-extract" || return
    mv -T "$work/java-extract" "$java_home" || return
    sync -f "$MSM_JAVA" || return
    runuser -u minecraft -- "$java_home/bin/java" -version || return
}

msm_engine_prepare() {
    local plan=$1 work=$2 java_home url digest mc neo arguments item vanilla loader
    java_home=$(jq -r .java_home "$plan")
    mc=$(jq -r .mc "$plan") loader=$(jq -r '.loader // "neoforge"' "$plan")
    if [[ $loader == vanilla ]]; then
        mkdir "$work/engine" || return
        msm_download "$(jq -r .minecraft.url "$plan")" "$work/engine/server.jar" sha1 "$(jq -r .minecraft.sha1 "$plan")" "$(jq -r .minecraft.size "$plan")" || return
        sync -f "$work/engine"
        return
    fi
    url=$(jq -r .installer.url "$plan") digest=$(jq -r .installer.sha256 "$plan")
    mkdir "$work/installer" "$work/engine" || return
    msm_download "$url" "$work/installer/installer.jar" sha256 "$digest" || return
    case $loader in
        neoforge)
            neo=$(jq -r .neoforge "$plan") arguments=$(jq -r .unix_args "$plan")
            msm_verify_installer "$work/installer/installer.jar" "$mc" "$neo" || return
            vanilla="$work/engine/libraries/net/minecraft/server/$mc/server-$mc.jar"
            ;;
        fabric)
            neo=$(jq -r .fabric "$plan") arguments=$(jq -r .launch_jar "$plan")
            msm_verify_fabric_installer "$work/installer/installer.jar" || return
            vanilla="$work/engine/server.jar"
            ;;
        *) msm_die 'Unsupported runtime loader.' ;;
    esac
    mkdir -p "${vanilla%/*}" || return
    msm_download "$(jq -r .minecraft.url "$plan")" "$vanilla" sha1 "$(jq -r .minecraft.sha1 "$plan")" "$(jq -r .minecraft.size "$plan")" || return
    chown -hR minecraft:minecraft "$work/installer" "$work/engine" || return
    chmod 750 "$work/installer" "$work/engine" || return
    (
        cd "$work/engine" || exit 1
        if [[ $loader == fabric ]]; then
            timeout --signal=TERM --kill-after=20s 1800s runuser -u minecraft -- "$java_home/bin/java" \
                -jar "$work/installer/installer.jar" server -dir "$work/engine" -mcversion "$mc" -loader "$neo"
        else
            timeout --signal=TERM --kill-after=20s 1800s runuser -u minecraft -- "$java_home/bin/java" \
                -jar "$work/installer/installer.jar" --installServer "$work/engine"
        fi
    ) || return
    [[ -s $work/engine/$arguments && ! -L $work/engine/$arguments ]] || msm_die 'The installer did not generate the expected launch file.'
    if [[ $loader == fabric ]]; then
        [[ -s $work/engine/libraries/net/fabricmc/fabric-loader/$neo/fabric-loader-$neo.jar ]] || msm_die 'Fabric did not install the requested loader.'
        timeout 120 unzip -tqq "$work/engine/$arguments" >/dev/null || msm_die 'Fabric launcher ZIP validation failed.'
        unzip -p "$work/engine/$arguments" META-INF/MANIFEST.MF | tr -d '\r' | \
            grep -Eq '^Main-Class: net\.fabricmc\.loader\.(impl\.)?launch\.server\.FabricServerLauncher$' || msm_die 'Unexpected Fabric server launcher.'
    fi
    for item in "$work/engine/"*; do
        case ${item##*/} in
            libraries|versions|server.jar) ;;
            fabric-server-launch.jar) [[ $loader == fabric ]] || msm_die 'Unexpected Fabric launcher in a NeoForge runtime.' ;;
            run.sh|run.bat|user_jvm_args.txt|*.log) [[ -f $item && ! -L $item ]] || msm_die 'Unexpected installer output.'; rm -- "$item" || return ;;
            *) msm_die "Unexpected installer output: ${item##*/}" ;;
        esac
    done
    [[ -z $(find -P "$work/engine" \( -type l -o \( -type f -links +1 \) -o \( ! -type d ! -type f \) \) -print -quit) ]] || msm_die 'Unsafe file in the generated runtime.'
    [[ -f $vanilla && $(sha1sum "$vanilla" | cut -d' ' -f1) == "$(jq -r .minecraft.sha1 "$plan")" ]] || msm_die 'Minecraft server checksum mismatch.'
    sync -f "$work/engine"
}

msm_own_server() {
    [[ -d $MSM_SERVER && ! -L $MSM_SERVER ]] || msm_die 'Invalid live server path.'
    [[ -z $(find -P "$MSM_SERVER" \( -type l -o \( -type f -links +1 \) -o \( ! -type d ! -type f \) \) -print -quit) ]] || msm_die 'Server tree contains links or special files.'
    chown -hR minecraft:minecraft "$MSM_SERVER" || return
    find -P "$MSM_SERVER" -type d -exec chmod 750 {} + || return
    find -P "$MSM_SERVER" -type f -exec chmod 640 {} + || return
    sync -f "$MSM_SERVER"
}
