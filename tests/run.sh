#!/usr/bin/env bash
set -Eeuo pipefail
export LC_ALL=C
test_project=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
test_temporary=$(mktemp -d "$test_project/.test-run.XXXXXXXX")
trap 'rm -rf -- "$test_temporary"' EXIT
export TMPDIR=$test_temporary
for file in "$test_project/bin/msm" "$test_project/install.sh" "$test_project/lib/"*.sh "$test_project/libexec/"*.sh "$test_project/tests/"*.sh "$test_project/.github/scripts/"*.sh; do
    bash -n "$file"
done
for file in "$test_project/tests/"test_*.sh; do
    printf '\n== %s ==\n' "${file##*/}"
    bash "$file"
done
printf '\nPASS: Bash syntax and regression tests.\n'
