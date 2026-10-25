# HTTPS transfers. These functions are sourced by msm and never run on import.
_msm_url_policy() {
    local msm_url=$1 msm_required=${2:-} msm_authority msm_host
    [[ $msm_url =~ ^https://([^/?#]+)(/[^#]*)?$ && $msm_url != *'#'* && ! $msm_url =~ [[:space:][:cntrl:]] ]] || { msm_log "Invalid HTTPS URL."; return 1; }
    msm_authority=${msm_url#https://}; msm_authority=${msm_authority%%/*}
    msm_host=${msm_authority%:443}; msm_host=${msm_host,,}
    case $msm_host in
        piston-meta.mojang.com|piston-data.mojang.com|launchermeta.mojang.com|launcher.mojang.com|launchermeta.launcher.mojang.com|libraries.minecraft.net|resources.download.minecraft.net) _MSM_URL_POLICY=mojang ;;
        maven.neoforged.net) _MSM_URL_POLICY=neoforge ;;
        meta.fabricmc.net|maven.fabricmc.net) _MSM_URL_POLICY=fabric ;;
        api.modrinth.com|cdn.modrinth.com) _MSM_URL_POLICY=modrinth ;;
        api.adoptium.net|github.com|api.github.com|objects.githubusercontent.com|release-assets.githubusercontent.com|github-releases.githubusercontent.com) _MSM_URL_POLICY=adoptium ;;
        *) msm_log "URL host is not an approved upstream."; return 1 ;;
    esac
    [[ -z $msm_required || $_MSM_URL_POLICY == "$msm_required" ]] || { msm_log "Redirect crossed an upstream policy."; return 1; }
    if [[ $msm_host == github.com ]]; then
        [[ $msm_url =~ ^https://github.com/(adoptium|eclipse-adoptium)/[^/]+/releases/download/[^/]+/[^/]+$ ]] || { msm_log "GitHub asset is not an Adoptium release."; return 1; }
    elif [[ $msm_host == api.github.com ]]; then
        [[ $msm_url =~ ^https://api.github.com/repos/(adoptium|eclipse-adoptium)/[^/]+/releases/assets/[0-9]+$ ]] || { msm_log "GitHub API asset is not an Adoptium release."; return 1; }
    fi
}

_msm_fetch() {
    local msm_url=$1 msm_dest=$2 msm_limit=${3:-33554432} msm_budget=${4:-120}
    local msm_policy msm_started=$SECONDS msm_left msm_report msm_status msm_next msm_rc msm_hops=0 msm_attempt=0
    _msm_url_policy "$msm_url" || return 1; msm_policy=$_MSM_URL_POLICY
    while (( msm_hops <= 5 )); do
        msm_left=$((msm_budget - SECONDS + msm_started))
        (( msm_left > 0 )) || { msm_log "HTTPS operation exceeded its total time budget."; return 1; }
        _msm_url_policy "$msm_url" "$msm_policy" || return 1
        if msm_report=$(curl -q --silent --show-error --proto '=https' --connect-timeout 15 --max-time "$msm_left" \
            --max-filesize "$msm_limit" --user-agent 'msm-shell/0.0.1 (Minecraft server manager)' \
            --output "$msm_dest" --write-out $'%{http_code}\n%{redirect_url}' -- "$msm_url"); then msm_rc=0; else msm_rc=$?; fi
        msm_status=${msm_report%%$'\n'*}; msm_next=${msm_report#*$'\n'}
        if (( msm_rc == 0 )) && [[ $msm_status == 200 ]]; then
            [[ -s $msm_dest ]] && (( $(stat -c %s -- "$msm_dest") <= msm_limit )) || { msm_log "Empty or oversized HTTPS response."; return 1; }
            return 0
        fi
        if (( msm_rc == 0 )) && [[ $msm_status =~ ^(301|302|303|307|308)$ ]]; then
            [[ -n $msm_next && $msm_next != "$msm_report" ]] || return 1
            msm_url=$msm_next; msm_hops=$((msm_hops + 1)); msm_attempt=0; continue
        fi
        [[ $msm_status != 404 ]] || { msm_log "Upstream returned HTTP 404."; return 44; }
        [[ $msm_status != 410 ]] || { msm_log "Upstream API returned HTTP 410; update msm before retrying."; return 1; }
        if (( msm_attempt < 2 )) && { { (( msm_rc == 0 )) && [[ $msm_status =~ ^(408|425|429|500|502|503|504)$ ]]; } || [[ $msm_rc =~ ^(5|6|7|18|28|35|52|55|56)$ ]]; }; then
            msm_attempt=$((msm_attempt + 1))
            (( msm_budget - SECONDS + msm_started > msm_attempt )) || { msm_log "HTTPS retry exceeded its time budget."; return 1; }
            sleep "$msm_attempt" || return 1; continue
        fi
        msm_log "HTTPS request failed (curl=$msm_rc, HTTP=$msm_status)."; return 1
    done
    msm_log "Too many HTTPS redirects."; return 1
}

msm_get_json() (
    local msm_url=$1 msm_out=$2 msm_tmp
    msm_tmp=$(mktemp -- "${msm_out}.part.XXXXXX") || msm_die "Cannot create JSON temporary file."
    trap 'rm -f -- "$msm_tmp"' EXIT
    _msm_fetch "$msm_url" "$msm_tmp" || msm_die "Cannot fetch upstream JSON."
    jq empty "$msm_tmp" >/dev/null || msm_die "Upstream returned invalid JSON."
    chmod 600 "$msm_tmp" && mv -fT -- "$msm_tmp" "$msm_out" || msm_die "Cannot publish JSON file."
)

_msm_check_digest() {
    local msm_algorithm=$1 msm_digest=$2 msm_length
    case $msm_algorithm in sha1) msm_length=40;; sha256) msm_length=64;; sha512) msm_length=128;; *) return 1;; esac
    [[ $msm_digest =~ ^[0-9a-fA-F]+$ && ${#msm_digest} == "$msm_length" ]]
}

msm_download() (
    local msm_url=$1 msm_out=$2 msm_algorithm=$3 msm_digest=$4 msm_size=${5:-} msm_tmp
    _msm_check_digest "$msm_algorithm" "$msm_digest" || msm_die "Invalid download checksum."
    [[ -z $msm_size || $msm_size =~ ^[1-9][0-9]{0,9}$ ]] || msm_die "Invalid download size."
    [[ -z $msm_size ]] || (( msm_size <= 2147483648 )) || msm_die "Download exceeds 2 GiB."
    msm_tmp=$(mktemp -- "${msm_out}.part.XXXXXX") || msm_die "Cannot create download temporary file."
    trap 'rm -f -- "$msm_tmp"' EXIT
    _msm_fetch "$msm_url" "$msm_tmp" "${msm_size:-2147483648}" 900 || msm_die "Download failed."
    [[ -z $msm_size || $(stat -c %s -- "$msm_tmp") == "$msm_size" ]] || msm_die "Downloaded size does not match metadata."
    printf '%s  %s\n' "$msm_digest" "$msm_tmp" | "${msm_algorithm}sum" --check --status || msm_die "Download checksum mismatch."
    chmod 644 "$msm_tmp" && mv -fT -- "$msm_tmp" "$msm_out" || msm_die "Cannot publish verified download."
)
