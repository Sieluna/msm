#!/usr/bin/env bash
# Complete cold snapshots. Callers must hold the single manager lock.
# GNU tar/coreutils/findutils are required. No extracted code is executed.

_msm_archive_tar() {
    env -u TAR_OPTIONS -u GZIP LC_ALL=C.UTF-8 tar --force-local "$@"
}

_msm_archive_safe_name() {
    local value=$1
    [[ -n $value && $value != /* && $value != */ && $value != *//* && $value != *\\* ]] || return 1
    [[ $value != . && $value != .. && $value != ./* && $value != ../* ]] || return 1
    [[ $value != */./* && $value != */../* && $value != */. && $value != */.. ]] || return 1
    [[ ! $value =~ [[:cntrl:]] ]] || return 1
    return 0
}

_msm_archive_directory() {
    local path=$1 owner mode expected=${MSM_OWNER_UID:-0}
    [[ $expected =~ ^[0-9]+$ ]] || msm_die 'Invalid archive owner UID.'
    [[ -d $path && ! -L $path ]] || msm_die "Expected a real directory: $path"
    owner=$(stat -c '%u' -- "$path") || msm_die "Cannot inspect directory owner: $path"
    mode=$(stat -c '%a' -- "$path") || msm_die "Cannot inspect directory mode: $path"
    [[ $owner == "$expected" && $mode =~ ^[0-7]{1,4}$ ]] || msm_die "Unsafe directory owner or mode: $path"
    (( (8#$mode & 8#022) == 0 )) || msm_die "Directory must not be group/world writable: $path"
}

_msm_archive_regular() {
    local path=$1 owner mode links expected=${MSM_OWNER_UID:-0}
    [[ -f $path && ! -L $path ]] || msm_die "Expected a regular non-symlink file: $path"
    owner=$(stat -c '%u' -- "$path") || msm_die "Cannot inspect file owner: $path"
    mode=$(stat -c '%a' -- "$path") || msm_die "Cannot inspect file mode: $path"
    links=$(stat -c '%h' -- "$path") || msm_die "Cannot inspect file links: $path"
    [[ $owner == "$expected" && $links == 1 && $mode =~ ^[0-7]{1,4}$ ]] || msm_die "Unsafe file owner, link count, or mode: $path"
    (( (8#$mode & 8#022) == 0 )) || msm_die "File must not be group/world writable: $path"
}

_msm_archive_location() {
    local archive=$1 name
    [[ $archive == /* && ${archive%/*} == "$MSM_BACKUPS" && $archive == *.tar.gz ]] ||
        msm_die 'Archive must be an absolute .tar.gz path directly inside the backup directory.'
    name=${archive##*/}
    _msm_archive_safe_name "$name" || msm_die 'Archive filename contains unsupported characters.'
    _msm_archive_directory "$MSM_BACKUPS"
}

_msm_archive_check_tree() {
    local list=$1 item relative device root_device links
    [[ -d $MSM_SERVER && ! -L $MSM_SERVER ]] || msm_die 'Server data must be a real directory.'
    root_device=$(stat -c '%d' -- "$MSM_SERVER") || msm_die 'Cannot inspect the server filesystem.'
    if ! find -P "$MSM_SERVER" -xdev -print0 > "$list"; then
        msm_die 'Cannot enumerate the server directory safely.'
    fi
    while IFS= read -r -d '' item; do
        if [[ $item == "$MSM_SERVER" ]]; then
            relative=server
        else
            relative=server/${item#"$MSM_SERVER"/}
        fi
        _msm_archive_safe_name "$relative" || msm_die 'Server names must not contain control characters, backslashes, or unsafe path components.'
        [[ ! -L $item ]] || msm_die "Server snapshots do not support symbolic links: $relative"
        device=$(stat -c '%d' -- "$item") || msm_die "Cannot inspect server entry: $relative"
        [[ $device == "$root_device" ]] || msm_die "Server snapshots do not cross filesystems: $relative"
        if [[ -d $item ]]; then
            continue
        elif [[ -f $item ]]; then
            links=$(stat -c '%h' -- "$item") || msm_die "Cannot inspect server file links: $relative"
            [[ $links == 1 ]] || msm_die "Server snapshots do not support hard links: $relative"
        else
            msm_die "Server snapshots do not support special files: $relative"
        fi
    done < "$list"
}

_msm_archive_validate_tar() {
    local archive=$1 work=$2 line mode size name canonical kind parent required quoted
    local listing=$work/members.txt names=$work/names.txt errors=$work/tar-errors.txt
    local pattern='^([^[:space:]]+)[[:space:]]+[0-9]+/[0-9]+[[:space:]]+([0-9]+)[[:space:]]'
    local -A kinds=()

    # -P is used ONLY for listing so unsafe absolute/parent paths are not
    # normalized away before validation. Extraction never enables -P.
    # C.UTF-8 keeps English metadata while preserving printable UTF-8 names.
    # Use a separate exact name listing: verbose timestamps have variable
    # fractional-second padding, which must not be mistaken for name bytes.
    if ! _msm_archive_tar --list --gzip --absolute-names --quoting-style=escape \
            --file="$archive" > "$names" 2> "$errors"; then
        msm_die 'Cannot read the gzip/tar archive; it may be incomplete or damaged.'
    fi
    if ! _msm_archive_tar --list --gzip --verbose --numeric-owner --full-time \
            --absolute-names --quoting-style=escape --file="$archive" \
            > "$listing" 2> "$errors"; then
        msm_die 'Cannot read the gzip/tar archive; it may be incomplete or damaged.'
    fi
    {
    while IFS= read -r line <&3 || [[ -n $line ]]; do
        IFS= read -r name <&4 || msm_die 'Archive name and metadata listings do not match.'
        [[ $line =~ $pattern ]] || msm_die 'Archive contains an unsupported or malformed tar entry.'
        mode=${BASH_REMATCH[1]}
        size=${BASH_REMATCH[2]}
        kind=${mode:0:1}
        [[ $mode =~ ^[-dlhcbps?][rwxSsTt-]{9}$ ]] || msm_die 'Archive contains unsupported permission metadata.'
        [[ $kind == - || $kind == d ]] || msm_die 'Archive contains a link or special file.'
        canonical=$name
        if [[ $kind == d ]]; then
            canonical=${canonical%/}
            [[ $size == 0 ]] || msm_die 'Archive contains an invalid directory entry.'
        fi
        _msm_archive_safe_name "$canonical" || msm_die 'Archive contains an unsafe path or unsupported filename.'
        case "$canonical" in
            server|manager)
                [[ $kind == d ]] || msm_die 'Archive roots must be directories.'
                ;;
            server/*) ;;
            manager/runtime.json|manager/mods.lock.json|manager/settings.json|manager/mods.json)
                [[ $kind == - ]] || msm_die 'Manager snapshot entries must be regular files.'
                ;;
            *)
                printf -v quoted '%q' "$canonical"
                msm_die "Archive contains an unexpected top-level or manager path: $quoted"
                ;;
        esac
        [[ ! ${kinds["$canonical"]+present} ]] || msm_die 'Archive contains duplicate paths.'
        kinds["$canonical"]=$kind
    done
    if IFS= read -r name <&4; then
        msm_die 'Archive name and metadata listings do not match.'
    fi
    } 3< "$listing" 4< "$names"
    [[ ${kinds[server]-} == d && ${kinds[manager]-} == d ]] || msm_die 'Archive is missing its server/ or manager/ directory.'
    for required in runtime.json mods.lock.json settings.json mods.json; do
        [[ ${kinds["manager/$required"]-} == - ]] || msm_die "Archive is missing manager/$required."
    done
    # Check after reading all entries so archive order cannot conceal a file
    # used as a parent. Our complete snapshots include every parent directory.
    for name in "${!kinds[@]}"; do
        parent=$name
        while [[ $parent == */* ]]; do
            parent=${parent%/*}
            [[ ${kinds["$parent"]-} == d ]] || msm_die 'Archive has a missing directory or a file/parent path conflict.'
        done
    done
}

_msm_archive_verify_with_work() {
    local archive=$1 work=$2 digest calculated bytes
    _msm_archive_location "$archive"
    _msm_archive_regular "$archive"
    _msm_archive_regular "$archive.sha256"
    bytes=$(stat -c '%s' -- "$archive.sha256") || msm_die 'Cannot inspect the checksum file.'
    [[ $bytes == 64 || $bytes == 65 ]] || msm_die 'Checksum file must contain one SHA-256 digest.'
    digest=$(cat -- "$archive.sha256") || msm_die 'Cannot read the checksum file.'
    [[ $digest =~ ^[0-9a-fA-F]{64}$ ]] || msm_die 'Checksum file contains an invalid SHA-256 digest.'
    calculated=$(sha256sum -- "$archive") || msm_die 'Cannot hash the archive.'
    calculated=${calculated%% *}
    [[ $calculated == "${digest,,}" ]] || msm_die 'Archive SHA-256 verification failed.'
    _msm_archive_validate_tar "$archive" "$work"
}

msm_archive_create() (
    set -u
    export LC_ALL=C.UTF-8
    umask 077
    local archive=${1:?Archive path is required} work='' temporary='' checksum_tmp=''
    local checksum_published=0 archive_published=0 name digest
    _msm_archive_create_cleanup() {
        local result=$1
        trap - EXIT
        if (( checksum_published && ! archive_published )); then
            rm -f -- "$archive.sha256" || result=1
        fi
        [[ -z $temporary ]] || rm -f -- "$temporary" || result=1
        [[ -z $checksum_tmp ]] || rm -f -- "$checksum_tmp" || result=1
        [[ -z $work ]] || rm -rf -- "$work" || result=1
        # Sync after removing temporary hard links, so published files have a
        # durable single-link form when this operation reports success.
        if (( archive_published || checksum_published )); then
            sync -f -- "$MSM_BACKUPS" || result=1
        fi
        exit "$result"
    }
    trap '_msm_archive_create_cleanup "$?"' EXIT

    msm_service_assert_stopped || msm_die 'Cannot snapshot a running or uncertain service.'
    _msm_archive_location "$archive"
    _msm_archive_directory "$MSM_STAGING"
    _msm_archive_directory "$MSM_CONFIG"
    [[ ! -e $archive && ! -L $archive && ! -e $archive.sha256 && ! -L $archive.sha256 ]] ||
        msm_die 'Archive or checksum already exists; refusing to overwrite it.'
    work=$(mktemp -d "$MSM_STAGING/archive-create.XXXXXXXX") || msm_die 'Cannot create private archive staging.'
    _msm_archive_check_tree "$work/server-entries.bin"
    mkdir -m 700 -- "$work/manager" || msm_die 'Cannot prepare manager snapshot files.'
    for name in runtime.json mods.lock.json settings.json mods.json; do
        _msm_archive_regular "$MSM_CONFIG/$name"
        cp -P --preserve=mode -- "$MSM_CONFIG/$name" "$work/manager/$name" || msm_die "Cannot snapshot manager file: $name"
        _msm_archive_regular "$work/manager/$name"
    done
    temporary=$(mktemp "$MSM_BACKUPS/.msm-archive.XXXXXXXX") || msm_die 'Cannot create archive temporary file.'
    checksum_tmp=$(mktemp "$MSM_BACKUPS/.msm-checksum.XXXXXXXX") || msm_die 'Cannot create checksum temporary file.'
    # Transform the server's leading dot into its fixed archive root; manager/
    # does not start with a dot and is therefore left unchanged.
    if ! _msm_archive_tar --create --gzip --format=posix --one-file-system --sort=name \
            --numeric-owner --owner=0 --group=0 --transform='s,^\.,server,' \
            --file="$temporary" -C "$MSM_SERVER" . -C "$work" manager; then
        msm_die 'Cold backup failed; source files may have changed or the disk may be full.'
    fi
    _msm_archive_validate_tar "$temporary" "$work"
    digest=$(sha256sum -- "$temporary") || msm_die 'Cannot calculate the archive checksum.'
    digest=${digest%% *}
    printf '%s\n' "$digest" > "$checksum_tmp" || msm_die 'Cannot write the archive checksum.'
    sync -f -- "$temporary" || msm_die 'Cannot sync archive data.'
    sync -f -- "$checksum_tmp" || msm_die 'Cannot sync checksum data.'
    # link+unlink publishes without replacing any existing pathname. The
    # checksum appears first; a published archive therefore has its checksum.
    ln -T -- "$checksum_tmp" "$archive.sha256" || msm_die 'Checksum publication failed; no existing file was overwritten.'
    checksum_published=1
    ln -T -- "$temporary" "$archive" || msm_die 'Archive publication failed; no existing file was overwritten.'
    archive_published=1
    exit 0
)

msm_archive_verify() (
    set -u
    export LC_ALL=C.UTF-8
    umask 077
    local archive=${1:?Archive path is required} work=''
    _msm_archive_directory "$MSM_STAGING"
    work=$(mktemp -d "$MSM_STAGING/archive-verify.XXXXXXXX") || msm_die 'Cannot create verification staging.'
    trap '[[ -z $work ]] || rm -rf -- "$work"' EXIT
    _msm_archive_verify_with_work "$archive" "$work"
)

msm_archive_extract() (
    set -u
    export LC_ALL=C.UTF-8
    umask 077
    local archive=${1:?Archive path is required} destination=${2:?Destination is required}
    local work='' relative current component entry device root_device mode existing
    _msm_archive_directory "$MSM_STAGING"
    [[ $destination == "$MSM_STAGING/"* ]] || msm_die 'Extraction destination must be inside the managed staging directory.'
    relative=${destination#"$MSM_STAGING"/}
    _msm_archive_safe_name "$relative" || msm_die 'Extraction destination contains an unsafe path.'
    # Every existing parent must remain trusted. Missing intermediate parents
    # are not created implicitly, which keeps accidental destinations obvious.
    current=$MSM_STAGING
    while [[ $relative == */* ]]; do
        component=${relative%%/*}
        relative=${relative#*/}
        current=$current/$component
        _msm_archive_directory "$current"
    done
    if [[ -e $destination || -L $destination ]]; then
        _msm_archive_directory "$destination"
        existing=$(find -P "$destination" -mindepth 1 -maxdepth 1 -print -quit) || msm_die 'Cannot inspect extraction destination.'
        [[ -z $existing ]] || msm_die 'Extraction destination is not empty.'
        mode=$(stat -c '%a' -- "$destination") || msm_die 'Cannot inspect extraction directory mode.'
        [[ $mode == 700 ]] || msm_die 'An existing extraction destination must have mode 0700.'
    fi
    work=$(mktemp -d "$MSM_STAGING/archive-extract.XXXXXXXX") || msm_die 'Cannot create extraction verification staging.'
    trap '[[ -z $work ]] || rm -rf -- "$work"' EXIT
    _msm_archive_verify_with_work "$archive" "$work"
    if [[ ! -e $destination ]]; then
        mkdir -m 700 -- "$destination" || msm_die 'Cannot create the private extraction destination.'
    fi
    if ! _msm_archive_tar --extract --gzip --restrict --keep-old-files \
            --no-same-owner --no-same-permissions --delay-directory-restore \
            --file="$archive" --directory="$destination"; then
        msm_die 'Archive extraction failed; the private staging directory was retained for inspection.'
    fi
    root_device=$(stat -c '%d' -- "$destination") || msm_die 'Cannot inspect extracted filesystem.'
    if ! find -P "$destination" -xdev -print0 > "$work/extracted-entries.bin"; then
        msm_die 'Cannot inspect extracted entries.'
    fi
    while IFS= read -r -d '' entry; do
        [[ ! -L $entry ]] || msm_die 'Extraction produced an unexpected symbolic link.'
        device=$(stat -c '%d' -- "$entry") || msm_die 'Cannot inspect an extracted entry.'
        [[ $device == "$root_device" ]] || msm_die 'Extraction must not cross filesystems.'
        if [[ -d $entry ]]; then
            chmod 700 -- "$entry" || msm_die 'Cannot protect an extracted directory.'
        elif [[ -f $entry ]]; then
            mode=$(stat -c '%a' -- "$entry") || msm_die 'Cannot inspect extracted file mode.'
            if (( 8#$mode & 8#100 )); then
                chmod 700 -- "$entry" || msm_die 'Cannot protect an extracted executable file.'
            else
                chmod 600 -- "$entry" || msm_die 'Cannot protect an extracted file.'
            fi
        else
            msm_die 'Extraction produced an unexpected special file.'
        fi
    done < "$work/extracted-entries.bin"
    sync -f -- "$destination" || msm_die 'Cannot sync the extracted snapshot.'
)
