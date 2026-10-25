#!/usr/bin/env bash
set -Eeuo pipefail
export LC_ALL=C
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
msm_source_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
if [[ ${1:-} == --help || ${1:-} == -h ]]; then
    exec /bin/bash "$msm_source_root/bin/msm" install --help
fi
[[ $EUID == 0 ]] || { printf 'Run install.sh with sudo.\n' >&2; exit 1; }
msm_eula=false
for msm_argument in "$@"; do [[ $msm_argument != --accept-eula ]] || msm_eula=true; done
[[ $msm_eula == true ]] || { printf 'Read https://aka.ms/MinecraftEULA and pass --accept-eula if you agree.\n' >&2; exit 1; }
[[ -d /run/systemd/system ]] || { printf 'A systemd host is required.\n' >&2; exit 1; }
[[ -r /etc/os-release ]] || exit 1
msm_distribution=$(sed -n 's/^ID=//p' /etc/os-release | tr -d '"')
msm_release=$(sed -n 's/^VERSION_ID=//p' /etc/os-release | tr -d '"')
case $msm_distribution in
    debian) [[ ${msm_release%%.*} -ge 12 ]] || exit 1 ;;
    ubuntu) [[ ${msm_release%%.*} -ge 22 ]] || exit 1 ;;
    *) printf 'Supported hosts: Debian 12+ and Ubuntu 22.04+.\n' >&2; exit 1 ;;
esac
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends bash ca-certificates curl jq xmlstarlet unzip tar gzip coreutils findutils util-linux passwd
exec /bin/bash "$msm_source_root/bin/msm" install "$@"
