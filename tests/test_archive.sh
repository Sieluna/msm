#!/usr/bin/env bash
# Isolated archive tests: real GNU tar/hash/files, no system service changes.
set -u
set -o pipefail
umask 077
export LC_ALL=C.UTF-8

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd) || exit 1
PROJECT_DIR=${TEST_DIR%/tests}
TEST_ROOT=$(mktemp -d "$TEST_DIR/.archive-tests.XXXXXXXX") || exit 1
trap 'rm -rf -- "$TEST_ROOT"' EXIT

msm_die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
msm_service_assert_stopped() {
    [[ ${TEST_RUNNING:-0} == 0 ]] || msm_die 'The simulated service is still running.'
}
# shellcheck source=../lib/archive.sh
source "$PROJECT_DIR/lib/archive.sh" || exit 1

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
expect_failure() {
    if "$@" > "$CASE_DIR/expected.stdout" 2> "$CASE_DIR/expected.stderr"; then
        fail "Expected failure: $*"
    fi
    [[ -s $CASE_DIR/expected.stderr ]] || fail 'Failure did not explain its cause.'
}

fixture() {
    CASE_DIR=$(mktemp -d "$TEST_ROOT/case.XXXXXXXX") || fail 'Cannot create test fixture.'
    MSM_SERVER=$CASE_DIR/server
    MSM_CONFIG=$CASE_DIR/config
    MSM_BACKUPS=$CASE_DIR/backups
    MSM_STAGING=$CASE_DIR/staging
    MSM_OWNER_UID=$(id -u) || fail 'Cannot read the test UID.'
    TEST_RUNNING=0
    mkdir -m 700 -- "$MSM_SERVER" "$MSM_CONFIG" "$MSM_BACKUPS" "$MSM_STAGING" || fail 'Cannot create fixture directories.'
    mkdir -m 700 -- "$MSM_SERVER/world" "$MSM_SERVER/mods" "$MSM_SERVER/config" || fail 'Cannot create server fixture.'
    printf 'complete world bytes\n' > "$MSM_SERVER/world/level.dat" || fail 'Cannot write world fixture.'
    printf 'mod bytes\n' > "$MSM_SERVER/mods/example.jar" || fail 'Cannot write mod fixture.'
    printf 'enabled=true\n' > "$MSM_SERVER/config/example.toml" || fail 'Cannot write server config fixture.'
    printf '{"schema":1,"mc":"1.21.1"}\n' > "$MSM_CONFIG/runtime.json" || fail 'Cannot write runtime fixture.'
    printf '{"schema":1,"mods":[]}\n' > "$MSM_CONFIG/mods.lock.json" || fail 'Cannot write lock fixture.'
    printf '{"memory":"4G"}\n' > "$MSM_CONFIG/settings.json" || fail 'Cannot write settings fixture.'
    printf '{"schema":1,"mods":[]}\n\n' > "$MSM_CONFIG/mods.json" || fail 'Cannot write template fixture.'
    ARCHIVE=$MSM_BACKUPS/test.tar.gz
}

digest_file() {
    local archive=$1 digest
    digest=$(sha256sum -- "$archive") || fail 'Cannot hash a test archive.'
    printf '%s\n' "${digest%% *}" > "$archive.sha256" || fail 'Cannot write a test checksum.'
    chmod 600 -- "$archive" "$archive.sha256" || fail 'Cannot protect a test archive.'
}

craft_fixture() {
    CRAFT=$CASE_DIR/craft
    mkdir -m 700 -- "$CRAFT" "$CRAFT/manager" || fail 'Cannot create crafted archive fixture.'
    cp -a -- "$MSM_SERVER" "$CRAFT/server" || fail 'Cannot copy crafted server fixture.'
    local name
    for name in runtime.json mods.lock.json settings.json mods.json; do
        cp -- "$MSM_CONFIG/$name" "$CRAFT/manager/$name" || fail 'Cannot copy crafted metadata.'
    done
}

craft_tar() {
    local archive=$1
    shift
    env -u TAR_OPTIONS -u GZIP tar --create --gzip --file="$archive" -C "$CRAFT" "$@" || fail 'Cannot produce a crafted test archive.'
    digest_file "$archive"
}

test_roundtrip_complete_files_and_names() {
    local unicode name
    unicode=$(printf '\344\270\255\346\226\207') || fail 'Cannot construct UTF-8 test name.'
    for name in 'a space' ' leading' 'trailing ' 'quote"name' "single'quote" "$unicode"; do
        printf 'named file\n' > "$MSM_SERVER/world/$name" || fail 'Cannot create named fixture.'
    done
    msm_archive_create "$ARCHIVE" || fail 'Valid cold backup failed.'
    [[ $(stat -c '%h' -- "$ARCHIVE") == 1 ]] || fail 'Archive retained a temporary hard link.'
    [[ $(stat -c '%h' -- "$ARCHIVE.sha256") == 1 ]] || fail 'Checksum retained a temporary hard link.'
    msm_archive_verify "$ARCHIVE" || fail 'Created archive did not verify.'
    msm_archive_extract "$ARCHIVE" "$MSM_STAGING/unpacked" || fail 'Verified archive did not extract.'
    diff -r -- "$MSM_SERVER" "$MSM_STAGING/unpacked/server" || fail 'Server tree did not round-trip exactly.'
    for name in runtime.json mods.lock.json settings.json mods.json; do
        cmp -- "$MSM_CONFIG/$name" "$MSM_STAGING/unpacked/manager/$name" || fail 'Manager metadata changed during backup.'
    done
    [[ $(stat -c '%a' -- "$MSM_STAGING/unpacked") == 700 ]] || fail 'Extraction root is not private.'
    [[ -z $(find "$MSM_BACKUPS" -name '.msm-*' -print -quit) ]] || fail 'Backup temporary files were left behind.'
}

test_running_service_and_existing_archive_are_rejected() {
    TEST_RUNNING=1
    expect_failure msm_archive_create "$ARCHIVE"
    [[ ! -e $ARCHIVE ]] || fail 'A live server produced an archive.'
    TEST_RUNNING=0
    msm_archive_create "$ARCHIVE" || fail 'Cannot create baseline archive.'
    local before after
    before=$(sha256sum -- "$ARCHIVE") || fail 'Cannot hash baseline archive.'
    expect_failure msm_archive_create "$ARCHIVE"
    after=$(sha256sum -- "$ARCHIVE") || fail 'Cannot hash retained archive.'
    [[ $before == "$after" ]] || fail 'Existing archive was overwritten.'
}

test_source_links_special_files_and_control_names_are_rejected() {
    local kind item target
    for kind in symlink hardlink fifo tab newline backslash; do
        item=$MSM_SERVER/unsafe
        case "$kind" in
            symlink) ln -s -- "$MSM_SERVER/world/level.dat" "$item" || fail 'Cannot create test symlink.' ;;
            hardlink) ln -- "$MSM_SERVER/world/level.dat" "$item" || fail 'Cannot create test hard link.' ;;
            fifo) mkfifo -- "$item" || fail 'Cannot create test FIFO.' ;;
            tab) item=$MSM_SERVER/$'bad\tname'; : > "$item" || fail 'Cannot create tab fixture.' ;;
            newline) item=$MSM_SERVER/$'bad\nname'; : > "$item" || fail 'Cannot create newline fixture.' ;;
            backslash) item=$MSM_SERVER/'bad\name'; : > "$item" || fail 'Cannot create backslash fixture.' ;;
        esac
        target=$MSM_BACKUPS/$kind.tar.gz
        expect_failure msm_archive_create "$target"
        [[ ! -e $target && ! -e $target.sha256 ]] || fail 'Rejected source published an archive.'
        rm -f -- "$item" || fail 'Cannot remove unsafe source fixture.'
    done
}

test_cross_filesystem_source_is_rejected() {
    mkdir -- "$MSM_SERVER/mounted" || fail 'Cannot create filesystem boundary fixture.'
    local original_device
    original_device=$(command stat -c '%d' -- "$MSM_SERVER") || fail 'Cannot inspect fixture device.'
    stat() {
        if [[ ${1:-} == -c && ${2:-} == %d && ${*: -1} == "$MSM_SERVER/mounted" ]]; then
            printf '%s\n' "$((original_device + 1))"
        else
            command stat "$@"
        fi
    }
    expect_failure msm_archive_create "$ARCHIVE"
    [[ ! -e $ARCHIVE ]] || fail 'A cross-filesystem tree was published.'
}

test_checksum_damage_and_untrusted_backup_files_are_rejected() {
    msm_archive_create "$ARCHIVE" || fail 'Cannot create baseline archive.'
    chmod 666 -- "$ARCHIVE" || fail 'Cannot change fixture permissions.'
    expect_failure msm_archive_verify "$ARCHIVE"
    chmod 600 -- "$ARCHIVE" || fail 'Cannot restore fixture permissions.'
    ln -- "$ARCHIVE" "$CASE_DIR/archive-link" || fail 'Cannot create backup hard-link fixture.'
    expect_failure msm_archive_verify "$ARCHIVE"
    rm -- "$CASE_DIR/archive-link" || fail 'Cannot remove backup hard-link fixture.'
    printf 'damage' >> "$ARCHIVE" || fail 'Cannot damage test archive.'
    expect_failure msm_archive_extract "$ARCHIVE" "$MSM_STAGING/should-not-exist"
    [[ ! -e $MSM_STAGING/should-not-exist ]] || fail 'Damaged archive was extracted.'
}

test_archive_location_and_extraction_destination_are_confined() {
    msm_archive_create "$ARCHIVE" || fail 'Cannot create baseline archive.'
    mkdir -- "$MSM_BACKUPS/nested" "$MSM_STAGING/nonempty" "$CASE_DIR/outside" || fail 'Cannot create destination fixtures.'
    cp -- "$ARCHIVE" "$MSM_BACKUPS/nested/test.tar.gz" || fail 'Cannot copy archive fixture.'
    cp -- "$ARCHIVE.sha256" "$MSM_BACKUPS/nested/test.tar.gz.sha256" || fail 'Cannot copy checksum fixture.'
    expect_failure msm_archive_verify "$MSM_BACKUPS/nested/test.tar.gz"
    printf 'keep\n' > "$MSM_STAGING/nonempty/keep" || fail 'Cannot create protected destination fixture.'
    expect_failure msm_archive_extract "$ARCHIVE" "$MSM_STAGING/nonempty"
    [[ $(cat -- "$MSM_STAGING/nonempty/keep") == keep ]] || fail 'Nonempty destination was overwritten.'
    ln -s -- "$CASE_DIR/outside" "$MSM_STAGING/linked" || fail 'Cannot create destination symlink.'
    expect_failure msm_archive_extract "$ARCHIVE" "$MSM_STAGING/linked"
    expect_failure msm_archive_extract "$ARCHIVE" "$MSM_STAGING/../outside"
    expect_failure msm_archive_extract "$ARCHIVE" "$CASE_DIR/outside"
    [[ -z $(find "$CASE_DIR/outside" -mindepth 1 -print -quit) ]] || fail 'Extraction escaped staging.'
}

test_archive_absolute_parent_and_foreign_paths_are_rejected() {
    craft_fixture
    local transform index=0 target
    for transform in 's,^server/world/level.dat$,../escape,' 's,^server/world/level.dat$,/absolute-escape,' \
                     's,^server/world/level.dat$,foreign/escape,'; do
        index=$((index + 1))
        target=$MSM_BACKUPS/unsafe-$index.tar.gz
        craft_tar "$target" --transform="$transform" manager server
        expect_failure msm_archive_verify "$target"
    done
}

test_archive_links_and_escaped_names_are_rejected() {
    craft_fixture
    local kind item target
    for kind in symlink hardlink tab newline backslash; do
        item=$CRAFT/server/unsafe
        case "$kind" in
            symlink) ln -s -- /etc/passwd "$item" || fail 'Cannot create archive link fixture.' ;;
            hardlink) ln -- "$CRAFT/server/world/level.dat" "$item" || fail 'Cannot create archive hard-link fixture.' ;;
            tab) item=$CRAFT/server/$'bad\tname'; : > "$item" || fail 'Cannot create archive tab fixture.' ;;
            newline) item=$CRAFT/server/$'bad\nname'; : > "$item" || fail 'Cannot create archive newline fixture.' ;;
            backslash) item=$CRAFT/server/'bad\name'; : > "$item" || fail 'Cannot create archive backslash fixture.' ;;
        esac
        target=$MSM_BACKUPS/member-$kind.tar.gz
        craft_tar "$target" manager server
        expect_failure msm_archive_verify "$target"
        rm -f -- "$item" || fail 'Cannot remove crafted member fixture.'
    done
}

test_duplicate_missing_metadata_and_parent_conflict_are_rejected() {
    craft_fixture
    craft_tar "$MSM_BACKUPS/duplicate.tar.gz" manager server server/world/level.dat
    expect_failure msm_archive_verify "$MSM_BACKUPS/duplicate.tar.gz"
    rm -- "$CRAFT/manager/settings.json" || fail 'Cannot remove metadata fixture.'
    craft_tar "$MSM_BACKUPS/missing.tar.gz" manager server
    expect_failure msm_archive_verify "$MSM_BACKUPS/missing.tar.gz"
    cp -- "$MSM_CONFIG/settings.json" "$CRAFT/manager/settings.json" || fail 'Cannot restore metadata fixture.'
    printf 'parent file' > "$CRAFT/parent-file" || fail 'Cannot create parent conflict fixture.'
    printf 'child file' > "$CRAFT/child-file" || fail 'Cannot create child conflict fixture.'
    craft_tar "$MSM_BACKUPS/conflict.tar.gz" --transform='s,^parent-file$,server/conflict,' \
        --transform='s,^child-file$,server/conflict/child,' manager server parent-file child-file
    expect_failure msm_archive_verify "$MSM_BACKUPS/conflict.tar.gz"
}

tests=(
    test_roundtrip_complete_files_and_names
    test_running_service_and_existing_archive_are_rejected
    test_source_links_special_files_and_control_names_are_rejected
    test_cross_filesystem_source_is_rejected
    test_checksum_damage_and_untrusted_backup_files_are_rejected
    test_archive_location_and_extraction_destination_are_confined
    test_archive_absolute_parent_and_foreign_paths_are_rejected
    test_archive_links_and_escaped_names_are_rejected
    test_duplicate_missing_metadata_and_parent_conflict_are_rejected
)
passed=0
failed=0
for test_name in "${tests[@]}"; do
    if (fixture; "$test_name"); then
        printf 'PASS %s\n' "$test_name"
        passed=$((passed + 1))
    else
        printf 'FAIL %s\n' "$test_name" >&2
        failed=$((failed + 1))
    fi
done
printf 'Archive tests: %s passed, %s failed.\n' "$passed" "$failed"
(( failed == 0 ))
