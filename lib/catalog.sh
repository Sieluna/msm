# Official Minecraft, NeoForge, Fabric and Temurin metadata.
_msm_value() { jq -er "$1" "$2" || msm_die "Missing or invalid metadata field: $1"; }
_msm_neoforge_prefix() {
    local msm_mc=$1 msm_minor msm_patch
    if [[ $msm_mc =~ ^1\.([0-9]+)(\.([0-9]+))?$ ]]; then
        msm_minor=${BASH_REMATCH[1]}; msm_patch=${BASH_REMATCH[3]:-0}
        (( 10#$msm_minor > 20 || (10#$msm_minor == 20 && 10#$msm_patch >= 2) )) || msm_die "NeoForge requires Minecraft 1.20.2 or later."
        printf '%d.%d.' "$((10#$msm_minor))" "$((10#$msm_patch))"
    elif [[ $msm_mc =~ ^([0-9]+)\.([0-9]+)(\.([0-9]+))?$ ]] && (( 10#${BASH_REMATCH[1]} >= 26 )); then
        printf '%d.%d.%d.' "$((10#${BASH_REMATCH[1]}))" "$((10#${BASH_REMATCH[2]}))" "$((10#${BASH_REMATCH[4]:-0}))"
    else msm_die "Unsupported Minecraft version numbering: $msm_mc"; fi
}

msm_resolve_runtime() (
    local msm_mc=${1:-latest} msm_neo=${2:-latest} msm_out=$3 msm_loader=${4:-vanilla} msm_work msm_prefix msm_sha msm_url msm_major msm_arch msm_kind msm_rc msm_asset=''
    [[ $msm_loader == vanilla || $msm_loader == neoforge || $msm_loader == fabric ]] || msm_die 'Loader must be vanilla, neoforge or fabric.'
    [[ $msm_loader != vanilla || $msm_neo == latest ]] || msm_die 'Vanilla does not have a loader version.'
    msm_work=$(mktemp -d) || msm_die "Cannot create runtime metadata workspace."
    trap 'rm -rf -- "$msm_work"' EXIT
    msm_get_json 'https://piston-meta.mojang.com/mc/game/version_manifest_v2.json' "$msm_work/manifest.json" || msm_die "Cannot resolve Minecraft."
    [[ $msm_mc != latest ]] || msm_mc=$(_msm_value '.latest.release | strings' "$msm_work/manifest.json") || exit 1
    [[ $msm_mc =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || msm_die "Only numbered Minecraft releases are supported."
    jq -ce --arg mc "$msm_mc" '[.versions[] | select(.id==$mc and .type=="release")] | if length==1 then .[0] else error("Release not found") end' \
        "$msm_work/manifest.json" > "$msm_work/entry.json" || msm_die "Minecraft release not found: $msm_mc"
    msm_download "$(_msm_value '.url' "$msm_work/entry.json")" "$msm_work/mc.json" sha1 "$(_msm_value '.sha1' "$msm_work/entry.json")" || msm_die "Cannot verify Minecraft metadata."
    jq -e --arg mc "$msm_mc" '.id==$mc and .type=="release" and (.releaseTime|type=="string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T")) and
        (.javaVersion.majorVersion | type=="number" and floor==. and .>=17 and .<=99) and (.downloads.server|type=="object")' \
        "$msm_work/mc.json" >/dev/null || msm_die "Invalid Minecraft server metadata."
    msm_major=$(_msm_value '.javaVersion.majorVersion' "$msm_work/mc.json") || exit 1
    date -d "$(_msm_value '.releaseTime' "$msm_work/mc.json")" +%s >/dev/null || msm_die "Invalid release timestamp."
    if [[ $msm_loader == neoforge ]]; then
        msm_prefix=$(_msm_neoforge_prefix "$msm_mc") || exit 1
        _msm_fetch 'https://maven.neoforged.net/releases/net/neoforged/neoforge/maven-metadata.xml' "$msm_work/neo.xml" 8388608 || msm_die "Cannot fetch NeoForge versions."
        if grep -Eiq '<!(DOCTYPE|ENTITY)' "$msm_work/neo.xml"; then msm_die "DTD and entities are not accepted in Maven metadata."; fi
        [[ $(xmlstarlet sel -t -v '/metadata/groupId' "$msm_work/neo.xml") == net.neoforged &&
           $(xmlstarlet sel -t -v '/metadata/artifactId' "$msm_work/neo.xml") == neoforge ]] || msm_die "Unexpected NeoForge Maven artifact."
        xmlstarlet sel -t -m '/metadata/versioning/versions/version' -v . -n "$msm_work/neo.xml" > "$msm_work/versions" || msm_die "Invalid Maven XML."
        grep -E "^${msm_prefix//./\\.}(0|[1-9][0-9]*)$" "$msm_work/versions" > "$msm_work/stable" || :
        [[ -s $msm_work/stable ]] || msm_die "No stable NeoForge release exists for Minecraft $msm_mc."
        if [[ $msm_neo == latest ]]; then msm_neo=$(sort -V "$msm_work/stable" | tail -n 1) || exit 1
        else grep -Fxq -- "$msm_neo" "$msm_work/stable" || msm_die "NeoForge version is not a stable release for the requested Minecraft version."; fi
        msm_url="https://maven.neoforged.net/releases/net/neoforged/neoforge/$msm_neo/neoforge-$msm_neo-installer.jar"
        _msm_fetch "$msm_url.sha256" "$msm_work/neo.sha256" 4096 || msm_die "Cannot fetch the NeoForge checksum."
        msm_sha=$(awk 'NR==1 {print $1; exit}' "$msm_work/neo.sha256") || exit 1
        _msm_check_digest sha256 "$msm_sha" || msm_die "Invalid NeoForge checksum."
        jq -n --arg version "$msm_neo" --arg url "$msm_url" --arg sha "$msm_sha" \
            '{loader:"neoforge",neoforge:$version,installer:{url:$url,sha256:$sha},unix_args:("libraries/net/neoforged/neoforge/"+$version+"/unix_args.txt")}' > "$msm_work/loader.json" || exit 1
    elif [[ $msm_loader == fabric ]]; then
        msm_get_json "https://meta.fabricmc.net/v2/versions/loader/$msm_mc" "$msm_work/fabric-loaders.json" || msm_die 'Cannot fetch compatible Fabric Loader versions.'
        jq -e 'type=="array" and all(.loader.version|type=="string")' "$msm_work/fabric-loaders.json" >/dev/null || msm_die 'Invalid Fabric Loader metadata.'
        jq -r '.[] | select(.loader.stable==true) | .loader.version | select(test("^[0-9]+\\.[0-9]+\\.[0-9]+$"))' "$msm_work/fabric-loaders.json" > "$msm_work/stable" || exit 1
        [[ -s $msm_work/stable ]] || msm_die "No stable Fabric Loader exists for Minecraft $msm_mc."
        if [[ $msm_neo == latest ]]; then msm_neo=$(sort -V "$msm_work/stable" | tail -n 1)
        else grep -Fxq -- "$msm_neo" "$msm_work/stable" || msm_die 'Fabric Loader is not a stable release for the requested Minecraft version.'; fi
        msm_get_json 'https://meta.fabricmc.net/v2/versions/installer' "$msm_work/fabric-installers.json" || msm_die 'Cannot fetch Fabric installers.'
        local msm_installer
        msm_installer=$(jq -er '[.[] | select(.stable==true and (.version|test("^[0-9]+\\.[0-9]+\\.[0-9]+$")))] | sort_by(.version|split(".")|map(tonumber)) | last.version' "$msm_work/fabric-installers.json") || msm_die 'No stable Fabric installer exists.'
        msm_url="https://maven.fabricmc.net/net/fabricmc/fabric-installer/$msm_installer/fabric-installer-$msm_installer.jar"
        _msm_fetch "$msm_url.sha256" "$msm_work/fabric.sha256" 4096 || msm_die 'Cannot fetch the Fabric installer checksum.'
        msm_sha=$(awk 'NR==1 {print $1; exit}' "$msm_work/fabric.sha256") || exit 1
        _msm_check_digest sha256 "$msm_sha" || msm_die 'Invalid Fabric installer checksum.'
        jq -n --arg version "$msm_neo" --arg installer "$msm_installer" --arg url "$msm_url" --arg sha "$msm_sha" \
            '{loader:"fabric",fabric:$version,fabric_installer:$installer,installer:{url:$url,sha256:$sha},launch_jar:"fabric-server-launch.jar"}' > "$msm_work/loader.json" || exit 1
    else
        printf '{"loader":"vanilla","launch_jar":"server.jar"}\n' > "$msm_work/loader.json"
    fi
    case $(uname -m) in x86_64) msm_arch=x64;; aarch64) msm_arch=aarch64;; *) msm_die "Only x86_64 and aarch64 are supported.";; esac
    for msm_kind in jre jdk; do
        if _msm_fetch "https://api.adoptium.net/v3/assets/latest/$msm_major/hotspot?architecture=$msm_arch&image_type=$msm_kind&os=linux&vendor=eclipse" "$msm_work/java.json"; then
            jq -e 'type=="array"' "$msm_work/java.json" >/dev/null || msm_die "Invalid Adoptium response."
            if jq -ce --argjson major "$msm_major" --arg arch "$msm_arch" --arg kind "$msm_kind" \
                '[.[] | select(.version.major==$major and .binary.architecture==$arch and .binary.os=="linux" and .binary.image_type==$kind and .binary.jvm_impl=="hotspot")] | .[0] // empty' \
                "$msm_work/java.json" > "$msm_work/asset.json"; then msm_asset=$msm_work/asset.json; break; fi
        else msm_rc=$?; (( msm_rc == 44 )) || msm_die "Cannot query Adoptium."; fi
    done
    [[ -n $msm_asset ]] || msm_die "No matching official JRE or JDK is available."
    jq -n --arg mc "$msm_mc" --slurpfile loader "$msm_work/loader.json" \
        --slurpfile mcdata "$msm_work/mc.json" --slurpfile asset "$msm_asset" \
        '{schema:1,mc:$mc,release_time:$mcdata[0].releaseTime,java_major:$mcdata[0].javaVersion.majorVersion,
          java:{url:$asset[0].binary.package.link,sha256:$asset[0].binary.package.checksum,size:$asset[0].binary.package.size,release_name:$asset[0].release_name},
          minecraft:($mcdata[0].downloads.server|{url,sha1,size})} + $loader[0] |
          .java.sha256 |= ascii_downcase | .minecraft.sha1 |= ascii_downcase |
          if .installer then .installer.sha256 |= ascii_downcase else . end' > "$msm_work/result.json" || msm_die "Cannot construct the runtime plan."
    for msm_kind in java minecraft; do
        _msm_url_policy "$(_msm_value ".$msm_kind.url" "$msm_work/result.json")" "$([[ $msm_kind == java ]] && printf adoptium || printf mojang)" || msm_die "Unexpected download source."
        jq -e ".$msm_kind.size | type==\"number\" and floor==. and .>0 and .<=2147483648" "$msm_work/result.json" >/dev/null || msm_die "Invalid runtime asset size."
    done
    _msm_check_digest sha256 "$(_msm_value '.java.sha256' "$msm_work/result.json")" && _msm_check_digest sha1 "$(_msm_value '.minecraft.sha1' "$msm_work/result.json")" || msm_die "Invalid runtime asset checksum."
    jq -e '.java.release_name | type=="string" and length>0' "$msm_work/result.json" >/dev/null || msm_die "Missing Java release name."
    cp -- "$msm_work/result.json" "$msm_out" || msm_die "Cannot write runtime plan."
)

msm_verify_installer() (
    local msm_file=$1 msm_mc=$2 msm_neo=$3 msm_work msm_name
    [[ -f $msm_file && ! -L $msm_file ]] && (( $(stat -c %s -- "$msm_file") <= 134217728 )) || msm_die "Installer must be a regular file of at most 128 MiB."
    msm_work=$(mktemp -d) || msm_die "Cannot create installer inspection workspace."
    trap 'rm -rf -- "$msm_work"' EXIT
    timeout 120 unzip -tqq "$msm_file" >/dev/null || msm_die "Installer ZIP validation failed."
    unzip -Z1 "$msm_file" > "$msm_work/members" || msm_die "Cannot list installer entries."
    for msm_name in install_profile.json version.json data/unix_args.txt; do
        [[ $(grep -Fxc -- "$msm_name" "$msm_work/members") == 1 ]] || msm_die "Installer entry missing or duplicated: $msm_name"
    done
    for msm_name in install_profile.json version.json; do
        unzip -p "$msm_file" "$msm_name" | head -c 8388609 > "$msm_work/$msm_name" || msm_die "Cannot read installer metadata."
        (( $(stat -c %s -- "$msm_work/$msm_name") <= 8388608 )) || msm_die "Installer metadata exceeds 8 MiB."
    done
    jq -e --arg mc "$msm_mc" --arg id "neoforge-$msm_neo" '.minecraft==$mc and .version==$id' "$msm_work/install_profile.json" >/dev/null &&
        jq -e --arg mc "$msm_mc" --arg id "neoforge-$msm_neo" '.inheritsFrom==$mc and .id==$id' "$msm_work/version.json" >/dev/null || msm_die "Installer Minecraft or NeoForge version does not match the plan."
)

msm_verify_fabric_installer() (
    local file=$1 work
    [[ -f $file && ! -L $file ]] && (( $(stat -c %s -- "$file") <= 134217728 )) || msm_die 'Fabric installer must be a regular file of at most 128 MiB.'
    work=$(mktemp -d) || msm_die 'Cannot create Fabric installer inspection workspace.'
    trap 'rm -rf -- "$work"' EXIT
    timeout 120 unzip -tqq "$file" >/dev/null || msm_die 'Fabric installer ZIP validation failed.'
    unzip -Z1 "$file" > "$work/members" || msm_die 'Cannot list Fabric installer entries.'
    [[ $(grep -Fxc META-INF/MANIFEST.MF "$work/members") == 1 ]] || msm_die 'Fabric installer manifest is missing or duplicated.'
    unzip -p "$file" META-INF/MANIFEST.MF | head -c 65537 > "$work/manifest" || msm_die 'Cannot read Fabric installer manifest.'
    (( $(stat -c %s "$work/manifest") <= 65536 )) || msm_die 'Fabric installer manifest is too large.'
    tr -d '\r' < "$work/manifest" | grep -Fxq 'Main-Class: net.fabricmc.installer.Main' || msm_die 'Unexpected Fabric installer main class.'
)
