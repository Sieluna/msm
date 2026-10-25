# Conservative server-mod resolution. Exact constraints never drift.
msm_auth_bundle() {
    local directory
    for directory in "$MSM_CODE_ROOT/bundled" "$MSM_CODE_ROOT/auth/dist"; do
        if [[ -d $directory && ! -L $directory && -f $directory/auth-manifest.json && ! -L $directory/auth-manifest.json ]]; then
            printf '%s\n' "$directory"; return 0
        fi
    done
    msm_die 'Auth artifacts are missing. Use the published installer or build auth with ./gradlew -p auth bundleAuth.'
}

_msm_auth_record() {
    local bundle record=$_msm_work/auth.json old=$_msm_work/old-auth.json
    bundle=$(msm_auth_bundle) || return 1
    jq -ce --arg mc "$_msm_mc" --arg loader "$_msm_loader" '
      select(.schema==1 and .mc==$mc and (.version|type=="string" and test("^[0-9]+\\.[0-9]+\\.[0-9]+$"))) |
      .version as $version | [.mods[]|select(.loader==$loader)] |
      if length==1 then .[0] + {source:"bundled",project:"msm-auth",slug:"auth",mc:$mc,version:.[0].sha512,version_number:$version} else empty end' \
      "$bundle/auth-manifest.json" > "$record" || msm_die "Bundled auth does not support Minecraft $_msm_mc with $_msm_loader."
    _msm_mod_record_valid "$record" || return 1
    if [[ $_msm_mode == locked ]]; then
        jq -Sce '[.mods[]|select(.project=="msm-auth")]|if length==1 then .[0] else empty end' "$_msm_old_lock" > "$old" || msm_die 'Strict lock is missing auth.'
        jq -Sc . "$record" > "$_msm_work/new-auth.json" || return 1
        cmp -s "$old" "$_msm_work/new-auth.json" || msm_die 'Bundled auth changed; refresh the mod lock explicitly.'
    fi
    _msm_names["auth-$_msm_loader-$_msm_mc.jar"]=msm-auth
    cat "$record" >> "$_msm_work/records.jsonl"
}

_MSM_MOD_COMPAT='def server_ok($p): (.environment // "unknown") as $e |
  if ($e|type)!="string" then false
  elif (["client_and_server","server_only","server_only_client_optional","dedicated_server_only","client_or_server","client_or_server_prefers_both","client_only_server_optional"]|index($e))!=null then true
  elif $e=="unknown" then ($p.server_side=="required" or $p.server_side=="optional") else false end;
  def compatible($mc;$pid;$p): .project_id==$pid and .version_type=="release" and
  (.game_versions|type=="array" and index($mc)!=null) and (.loaders|type=="array" and index($loader)!=null) and server_ok($p);'

_msm_mod_identifier() { [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$ ]] || msm_die "Invalid Modrinth identifier."; }
_msm_mod_project() {
    local msm_key=$1 msm_file msm_pid msm_slug
    [[ $msm_key != msm-auth ]] || msm_die 'msm-auth is reserved for the bundled authentication mod.'
    _msm_mod_identifier "$msm_key" || return 1
    if [[ -n ${_msm_alias[$msm_key]:-} ]]; then _msm_project_result=${_msm_alias[$msm_key]}; return 0; fi
    msm_file=$_msm_work/project-$msm_key.json
    msm_get_json "https://api.modrinth.com/v2/project/$msm_key" "$msm_file" || msm_die "Cannot resolve Modrinth project: $msm_key"
    jq -e '.project_type=="mod"' "$msm_file" >/dev/null || msm_die "Modrinth project is not a mod: $msm_key"
    msm_pid=$(_msm_value '.id' "$msm_file") && msm_slug=$(_msm_value '.slug' "$msm_file") || return 1
    [[ $msm_pid != msm-auth && $msm_slug != msm-auth ]] || msm_die 'A Modrinth identity conflicts with bundled auth.'
    _msm_mod_identifier "$msm_pid" && _msm_mod_identifier "$msm_slug" || return 1
    _msm_projects[$msm_pid]=1
    (( ${#_msm_projects[@]} <= 128 )) || msm_die "Mod and dependency count exceeds 128 projects."
    for msm_key in "$msm_key" "$msm_pid" "$msm_slug"; do
        [[ -z ${_msm_alias[$msm_key]:-} || ${_msm_alias[$msm_key]} == "$msm_pid" ]] || msm_die "Conflicting project aliases."
        _msm_alias[$msm_key]=$msm_pid
    done
    [[ $msm_file == "$_msm_work/project-$msm_pid.json" ]] || cp -- "$msm_file" "$_msm_work/project-$msm_pid.json" || return 1
    _msm_project_result=$msm_pid
}
_msm_mod_version() {
    local msm_vid=$1
    _msm_mod_identifier "$msm_vid" || return 1
    _msm_version_result=$_msm_work/version-$msm_vid.json
    [[ -f $_msm_version_result ]] || msm_get_json "https://api.modrinth.com/v2/version/$msm_vid" "$_msm_version_result" || msm_die "Required exact mod version is unavailable: $msm_vid"
    jq -e --arg id "$msm_vid" '.id==$id and (.project_id|type=="string")' "$_msm_version_result" >/dev/null || msm_die "Version metadata has the wrong identity."
}
_msm_mod_pin() {
    local msm_pid=$1 msm_vid=$2
    [[ -n $msm_vid ]] || return 0
    _msm_mod_identifier "$msm_vid" || return 1
    [[ -z ${_msm_pins[$msm_pid]:-} || ${_msm_pins[$msm_pid]} == "$msm_vid" ]] || msm_die "Conflicting exact versions for project $msm_pid."
    [[ -z ${_msm_selected[$msm_pid]:-} || ${_msm_selected[$msm_pid]} == "$msm_vid" ]] || msm_die "Dependency requires $msm_pid/$msm_vid after another version was selected; pin compatible roots explicitly."
    _msm_pins[$msm_pid]=$msm_vid
}
_msm_mod_record_valid() {
    local msm_record=$1 msm_algorithm msm_digest
    jq -e '(.filename|type=="string" and length>0 and utf8bytelength<=240 and (startswith(".")|not) and test("\\.jar$";"i") and (explode|all(.>=32 and .!=127 and .!=47 and .!=92))) and
      (.size|type=="number" and floor==. and .>0 and .<=2147483648) and (.version_number|type=="string" and length>0 and length<=256 and (explode|all(.>=32 and .!=127)))' \
      "$msm_record" >/dev/null || msm_die "Unsafe mod filename or invalid file metadata."
    if [[ $(jq -r '.source//"modrinth"' "$msm_record") == bundled ]]; then
        jq -e '.project=="msm-auth" and .slug=="auth" and (.loader=="fabric" or .loader=="neoforge") and
          (.mc|type=="string" and test("^[0-9]+\\.[0-9]+(\\.[0-9]+)?$")) and
          (.sha512|type=="string" and test("^[0-9a-f]{128}$")) and
          .filename==("auth-"+.loader+"-"+.mc+".jar") and .version==.sha512 and .url==null' "$msm_record" >/dev/null || msm_die 'Invalid bundled auth identity.'
    else
        jq -e '.source==null or .source=="modrinth"' "$msm_record" >/dev/null || msm_die 'Unknown mod source.'
        _msm_url_policy "$(_msm_value '.url' "$msm_record")" modrinth || msm_die "Unexpected mod download source."
    fi
    msm_algorithm=$(jq -r 'if .sha512 then "sha512" else "sha1" end' "$msm_record") || return 1
    msm_digest=$(_msm_value ".$msm_algorithm" "$msm_record") || return 1
    _msm_check_digest "$msm_algorithm" "$msm_digest" || msm_die "Invalid mod checksum."
}
_msm_mod_visit() {
    local msm_key=$1 msm_pin=${2:-} msm_pid msm_info msm_ver msm_vid msm_slug msm_name msm_dep msm_dp msm_dv msm_kind msm_old
    _msm_mod_project "$msm_key" || return 1; msm_pid=$_msm_project_result; msm_info=$_msm_work/project-$msm_pid.json
    _msm_mod_pin "$msm_pid" "$msm_pin" || return 1
    if [[ $_msm_mode == locked ]]; then
        msm_old=$_msm_work/old-$msm_pid.json
        jq -ce --arg p "$msm_pid" '[.mods[]|select(.project==$p)] | if length==1 then .[0] else empty end' "$_msm_old_lock" > "$msm_old" || msm_die "Strict lock is missing project: $msm_pid"
        _msm_mod_pin "$msm_pid" "$(_msm_value '.version' "$msm_old")" || return 1
    fi
    [[ -z ${_msm_selected[$msm_pid]:-} ]] || return 0
    msm_pin=${_msm_pins[$msm_pid]:-}
    if [[ -n $msm_pin ]]; then
        _msm_mod_version "$msm_pin" || return 1; msm_ver=$_msm_version_result
    else
        msm_get_json "https://api.modrinth.com/v2/project/$msm_pid/version?loaders=$_msm_loaders&game_versions=$_msm_games&include_changelog=false" "$_msm_work/candidates-$msm_pid.json" || msm_die "Cannot list compatible mod versions."
        msm_ver=$_msm_work/chosen-$msm_pid.json
        jq -ce --arg mc "$_msm_mc" --arg loader "$_msm_loader" --arg pid "$msm_pid" --slurpfile p "$msm_info" "$_MSM_MOD_COMPAT
          [.[]|select(compatible(\$mc;\$pid;\$p[0]))] | if length>100 then error(\"Too many candidates; pin an exact version\") else sort_by(.date_published,.id)|last // empty end" \
          "$_msm_work/candidates-$msm_pid.json" > "$msm_ver" || msm_die "No unambiguous release candidate for $msm_pid on Minecraft $_msm_mc; check compatibility or pin a version."
    fi
    jq -e --arg mc "$_msm_mc" --arg loader "$_msm_loader" --arg pid "$msm_pid" --slurpfile p "$msm_info" "$_MSM_MOD_COMPAT compatible(\$mc;\$pid;\$p[0])" "$msm_ver" >/dev/null || msm_die "Selected mod is not a compatible $_msm_loader server release: $msm_pid"
    msm_vid=$(_msm_value '.id' "$msm_ver") && msm_slug=$(_msm_value '.slug' "$msm_info") || return 1
    _msm_mod_identifier "$msm_vid" || return 1
    jq -e '(.files|type=="array" and length>0) and ((.dependencies//[])|type=="array" and length<=1024 and all(
      (.dependency_type=="required" or .dependency_type=="optional" or .dependency_type=="embedded" or .dependency_type=="incompatible") and
      (.project_id==null or (.project_id|type=="string" and test("^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$"))) and
      (.version_id==null or (.version_id|type=="string" and test("^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$"))) and
      (.file_name==null or (.file_name|type=="string"))))' "$msm_ver" >/dev/null || msm_die "Invalid mod files or dependency declarations."
    jq -ce --arg slug "$msm_slug" '(.files|map(select(.primary==true))) as $primary |
      (if ($primary|length)>1 then error("Multiple primary files") elif ($primary|length)==1 then $primary[0] else .files[0] end) as $f |
      if ($f.file_type!=null and $f.file_type!="unknown") then error("Unsupported file type") else
      {project:.project_id,slug:$slug,version:.id,version_number:.version_number,filename:$f.filename,url:$f.url,size:$f.size} +
      (if $f.hashes.sha512 then {sha512:($f.hashes.sha512|ascii_downcase)} else {sha1:($f.hashes.sha1|ascii_downcase)} end) end' "$msm_ver" > "$_msm_work/record-$msm_pid.json" || msm_die "Cannot select the mod JAR."
    _msm_mod_record_valid "$_msm_work/record-$msm_pid.json" || return 1
    if [[ $_msm_mode == locked ]]; then
        jq -e --slurpfile old "$msm_old" '.filename==$old[0].filename and .size==$old[0].size and
          (if $old[0].sha512 then .sha512==$old[0].sha512 else .sha1==$old[0].sha1 end)' "$_msm_work/record-$msm_pid.json" >/dev/null || msm_die "Upstream bytes no longer match the strict lock: $msm_pid"
    fi
    msm_name=$(_msm_value '.filename' "$_msm_work/record-$msm_pid.json") || return 1
    [[ -z ${_msm_names[$msm_name]:-} ]] || msm_die "Two mod projects use the same filename: $msm_name"
    _msm_names[$msm_name]=$msm_pid; _msm_selected[$msm_pid]=$msm_vid
    cat -- "$_msm_work/record-$msm_pid.json" >> "$_msm_work/records.jsonl" || return 1
    jq -c '.dependencies[]?' "$msm_ver" > "$_msm_work/deps-$msm_pid.jsonl" || return 1
    while IFS= read -r msm_dep; do
        msm_kind=$(jq -r '.dependency_type' <<< "$msm_dep") || return 1
        case $msm_kind in optional|embedded) continue;; incompatible)
            jq -c --arg owner "$msm_slug" '.+{owner:$owner}' <<< "$msm_dep" >> "$_msm_work/incompatible.jsonl" || return 1; continue;; esac
        msm_dp=$(jq -r '.project_id//empty' <<< "$msm_dep") && msm_dv=$(jq -r '.version_id//empty' <<< "$msm_dep") || return 1
        if [[ -n $msm_dv ]]; then
            _msm_mod_version "$msm_dv" || return 1
            msm_key=$(_msm_value '.project_id' "$_msm_version_result") || return 1
            [[ -z $msm_dp || $msm_dp == "$msm_key" ]] || msm_die "Dependency project and version IDs disagree."
            msm_dp=$msm_key
        fi
        [[ -n $msm_dp ]] || msm_die "Required external dependency cannot be resolved automatically: $msm_slug"
        _msm_mod_visit "$msm_dp" "$msm_dv" || return 1
    done < "$_msm_work/deps-$msm_pid.jsonl"
}

msm_resolve_mods() (
    local msm_template=$1 _msm_mc=$2 _msm_old_lock=$3 msm_out=$4 _msm_mode=${5:-refresh} _msm_work _msm_games _msm_loader _msm_loaders
    local msm_row msm_pid msm_pin msm_dep _msm_project_result _msm_version_result
    local -A _msm_alias=() _msm_projects=() _msm_pins=() _msm_selected=() _msm_names=() _msm_roots=()
    [[ $_msm_mode == refresh || $_msm_mode == locked ]] || msm_die "Mod mode must be refresh or locked."
    [[ $_msm_mc =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || msm_die "Invalid Minecraft version."
    _msm_work=$(mktemp -d) || msm_die "Cannot create mod resolver workspace."
    trap 'rm -rf -- "$_msm_work"' EXIT
    _msm_games=$(jq -rn --arg mc "$_msm_mc" '[$mc]|tojson|@uri') || exit 1
    jq -e '.schema==1 and (.loader=="vanilla" or .loader=="neoforge" or .loader=="fabric") and (.auth==null or (.auth|type=="boolean")) and (.mods|type=="array" and length<=128 and all((.project|type=="string") and (.enabled|type=="boolean") and (.version==null or (.version|type=="string")))) and (.loader!="vanilla" or ((.mods|length)==0 and (.auth//false)==false))' \
        "$msm_template" >/dev/null || msm_die "Invalid mod template."
    _msm_loader=$(jq -r .loader "$msm_template") || exit 1
    _msm_loaders=$(jq -rn --arg loader "$_msm_loader" '[$loader]|tojson|@uri') || exit 1
    if [[ $_msm_mode == locked ]]; then
        [[ -f $_msm_old_lock ]] || msm_die "Strict mode requires an existing lock file."
        jq -e --arg mc "$_msm_mc" --arg loader "$_msm_loader" '.schema==1 and .loader==$loader and .mc==$mc and (.mods|type=="array" and length<=128)' "$_msm_old_lock" >/dev/null || msm_die "Strict lock does not match Minecraft and the selected loader."
    fi
    : > "$_msm_work/roots.jsonl"; : > "$_msm_work/records.jsonl"; : > "$_msm_work/incompatible.jsonl"
    if [[ $(jq -r '.auth//false' "$msm_template") == true ]]; then
        _msm_projects[msm-auth]=1
        _msm_auth_record || exit 1
        printf '%s\n' '{"project":"msm-auth","version":null}' >> "$_msm_work/roots.jsonl"
    fi
    jq -c '.mods[]|select(.enabled)' "$msm_template" > "$_msm_work/input.jsonl" || exit 1
    while IFS= read -r msm_row; do
        _msm_mod_project "$(jq -r '.project' <<< "$msm_row")" || exit 1; msm_pid=$_msm_project_result
        [[ -z ${_msm_roots[$msm_pid]:-} ]] || msm_die "Duplicate root mod project: $msm_pid"
        _msm_roots[$msm_pid]=1; msm_pin=$(jq -r '.version//empty' <<< "$msm_row") || exit 1
        _msm_mod_pin "$msm_pid" "$msm_pin" || exit 1
        jq -nc --arg p "$msm_pid" --arg v "$msm_pin" '{project:$p,version:(if $v=="" then null else $v end)}' >> "$_msm_work/roots.jsonl" || exit 1
    done < "$_msm_work/input.jsonl"
    if [[ $_msm_loader == fabric && $(jq -r '.auth//false' "$msm_template") == true ]]; then
        # Auth's loader adapter requires Fabric API even in a custom, otherwise empty template.
        # Resolve explicit roots first so an existing exact Fabric API pin remains authoritative.
        _msm_mod_project fabric-api || exit 1; msm_pid=$_msm_project_result
        if [[ -z ${_msm_roots[$msm_pid]:-} ]]; then
            _msm_roots[$msm_pid]=1
            jq -nc --arg p "$msm_pid" '{project:$p,version:null}' >> "$_msm_work/roots.jsonl" || exit 1
        fi
    fi
    jq -sc 'sort_by(.version==null,.project)[]' "$_msm_work/roots.jsonl" > "$_msm_work/ordered.jsonl" || exit 1
    while IFS= read -r msm_row; do
        [[ $(jq -r '.project' <<< "$msm_row") != msm-auth ]] || continue
        _msm_mod_visit "$(jq -r '.project' <<< "$msm_row")" "$(jq -r '.version//empty' <<< "$msm_row")" || exit 1
    done < "$_msm_work/ordered.jsonl"
    jq -s '.' "$_msm_work/records.jsonl" > "$_msm_work/records.json" || exit 1
    while IFS= read -r msm_dep; do
        if jq -e --argjson d "$msm_dep" 'any(.[]; if $d.version_id then .version==$d.version_id and ($d.project_id==null or .project==$d.project_id)
            elif $d.project_id then .project==$d.project_id elif $d.file_name then .filename==$d.file_name else false end)' "$_msm_work/records.json" >/dev/null; then
            msm_die "A selected mod declares an incompatible project, version or filename: $(jq -r '.owner' <<< "$msm_dep")"
        fi
        jq -e '.project_id!=null or .version_id!=null or .file_name!=null' <<< "$msm_dep" >/dev/null || msm_die "Unrecognized incompatible dependency declaration."
    done < "$_msm_work/incompatible.jsonl"
    jq -n --arg mc "$_msm_mc" --arg loader "$_msm_loader" --slurpfile roots "$_msm_work/roots.jsonl" --slurpfile mods "$_msm_work/records.json" \
        '{schema:1,mc:$mc,loader:$loader,roots:($roots|sort_by(.project)),mods:($mods[0]|sort_by(.project))}' > "$msm_out" || msm_die "Cannot write mod lock."
)

msm_download_mods() (
    local msm_lock=$1 msm_dest=$2 msm_work msm_record msm_name msm_algorithm msm_digest msm_loader msm_mc msm_source
    [[ ! -L $msm_dest ]] && mkdir -p -- "$msm_dest" || msm_die "Mod destination is not a safe directory."
    msm_work=$(mktemp -d) || msm_die "Cannot create mod download workspace."
    trap 'rm -rf -- "$msm_work"' EXIT
    jq -e '.schema==1 and (.loader=="vanilla" or .loader=="neoforge" or .loader=="fabric") and (.mods|type=="array" and length<=128) and ([.mods[].filename]|length==(unique|length)) and (.loader!="vanilla" or (.mods|length)==0)' "$msm_lock" >/dev/null || msm_die "Invalid or duplicate mod lock entries."
    msm_loader=$(jq -r .loader "$msm_lock") || exit 1
    msm_mc=$(jq -r .mc "$msm_lock") || exit 1
    jq -c '.mods[]' "$msm_lock" > "$msm_work/mods.jsonl" || exit 1
    while IFS= read -r msm_record; do
        printf '%s\n' "$msm_record" > "$msm_work/record.json" || exit 1
        _msm_mod_record_valid "$msm_work/record.json" || exit 1
        msm_name=$(_msm_value '.filename' "$msm_work/record.json") || exit 1
        msm_algorithm=$(jq -r 'if .sha512 then "sha512" else "sha1" end' "$msm_work/record.json") || exit 1
        msm_digest=$(_msm_value ".$msm_algorithm" "$msm_work/record.json") || exit 1
        msm_source=$(jq -r '.source//"modrinth"' "$msm_work/record.json") || exit 1
        if [[ $msm_source == bundled ]]; then
            jq -e --arg mc "$msm_mc" --arg loader "$msm_loader" '.mc==$mc and .loader==$loader' "$msm_work/record.json" >/dev/null || msm_die 'Bundled auth does not match the mod lock runtime.'
            local bundle source
            bundle=$(msm_auth_bundle) || exit 1; source=$bundle/$msm_name
            [[ -f $source && ! -L $source && $(stat -c %s "$source") == "$(_msm_value '.size' "$msm_work/record.json")" ]] || msm_die 'Bundled auth is missing or has the wrong size.'
            [[ $("${msm_algorithm}sum" "$source" | cut -d' ' -f1) == "$msm_digest" ]] || msm_die 'Bundled auth checksum mismatch.'
            cp -- "$source" "$msm_dest/$msm_name" || exit 1
        else
            msm_download "$(_msm_value '.url' "$msm_work/record.json")" "$msm_dest/$msm_name" "$msm_algorithm" "$msm_digest" "$(_msm_value '.size' "$msm_work/record.json")" || msm_die "Mod download failed: $msm_name"
        fi
        [[ $("${msm_algorithm}sum" "$msm_dest/$msm_name" | cut -d' ' -f1) == "$msm_digest" ]] || msm_die 'Staged mod checksum mismatch.'
        timeout 120 unzip -tqq "$msm_dest/$msm_name" >/dev/null || msm_die "Mod JAR failed ZIP validation: $msm_name"
        unzip -Z1 "$msm_dest/$msm_name" > "$msm_work/members" || exit 1
        if [[ $msm_loader == neoforge ]]; then
            grep -Eq '^META-INF/(neoforge\.)?mods\.toml$' "$msm_work/members" || msm_die "JAR has no NeoForge mod descriptor: $msm_name"
            if [[ $msm_source == bundled ]]; then
                unzip -p "$msm_dest/$msm_name" META-INF/neoforge.mods.toml | head -c 8388609 > "$msm_work/auth.toml" || msm_die 'Cannot read bundled auth descriptor.'
                (( $(stat -c %s "$msm_work/auth.toml") <= 8388608 )) && grep -Eq '^modId[[:space:]]*=[[:space:]]*"auth"[[:space:]]*$' "$msm_work/auth.toml" || msm_die 'Bundled NeoForge JAR has the wrong mod ID.'
            fi
        else
            [[ $(grep -Fxc fabric.mod.json "$msm_work/members") == 1 ]] || msm_die "JAR has no unique Fabric mod descriptor: $msm_name"
            unzip -p "$msm_dest/$msm_name" fabric.mod.json | head -c 8388609 > "$msm_work/fabric.mod.json" || msm_die 'Cannot read Fabric mod descriptor.'
            (( $(stat -c %s "$msm_work/fabric.mod.json") <= 8388608 )) || msm_die 'Fabric mod descriptor is too large.'
            jq -e '(.id|type=="string" and length>0) and (.environment==null or .environment=="*" or .environment=="server")' "$msm_work/fabric.mod.json" >/dev/null || msm_die "Invalid or client-only Fabric mod descriptor: $msm_name"
            [[ $msm_source != bundled ]] || jq -e '.id=="auth"' "$msm_work/fabric.mod.json" >/dev/null || msm_die 'Bundled Fabric JAR has the wrong mod ID.'
        fi
    done < "$msm_work/mods.jsonl"
)
