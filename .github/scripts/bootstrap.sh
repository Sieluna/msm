#!/usr/bin/env bash
# Release packaging replaces these constants with the tested payload identity.
msm_bootstrap() (
    set -Eeuo pipefail
    export LC_ALL=C
    export PATH=/usr/sbin:/usr/bin:/sbin:/bin
    unset BASH_ENV ENV CDPATH
    local version='@MSM_VERSION@' digest='@MSM_SHA256@' argument accepted=false work
    if [[ ${1:-} == --help || ${1:-} == -h ]]; then
        printf 'Install msm %s on Debian 12+ or Ubuntu 22.04+ with systemd.\n' "$version"
        printf 'Read https://aka.ms/MinecraftEULA and pass --accept-eula if you agree.\n'
        printf 'Other arguments are forwarded to the msm installer.\n'
        exit 0
    fi
    [[ $EUID == 0 ]] || { printf 'Run this installer with sudo bash.\n' >&2; exit 1; }
    for argument in "$@"; do [[ $argument != --accept-eula ]] || accepted=true; done
    [[ $accepted == true ]] || { printf 'Read https://aka.ms/MinecraftEULA and pass --accept-eula if you agree.\n' >&2; exit 1; }
    [[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && $digest =~ ^[a-f0-9]{64}$ ]] || exit 1
    umask 077
    work=$(mktemp -d)
    trap 'rm -rf -- "$work"' EXIT
    wget --https-only --timeout=30 --tries=3 -qO "$work/msm.tar.gz" \
        "https://github.com/Sieluna/msm/releases/download/latest/msm-$version.tar.gz"
    printf '%s  %s\n' "$digest" "$work/msm.tar.gz" | sha256sum --check --status
    tar --extract --gzip --file="$work/msm.tar.gz" --directory="$work" --no-same-owner
    bash "$work/msm-$version/install.sh" "$@"
)

msm_bootstrap "$@"
