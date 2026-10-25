#!/usr/bin/env bash
# Runs only in disposable, systemd-enabled CI hosts; never called by run.sh.
set -Eeuo pipefail
export LC_ALL=C
project=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
loader=${1:?Usage: smoke.sh vanilla|fabric|neoforge [JDK_JAVA_EXECUTABLE]}
probe_java=${2:-java}
[[ $EUID == 0 && ( $loader == vanilla || $loader == neoforge || $loader == fabric ) ]]
[[ -d /run/systemd/system ]]
work=$(mktemp -d)
cleanup() {
    result=$?
    trap - EXIT
    if (( result != 0 )); then journalctl -u minecraft.service -n 200 --no-pager || true; fi
    if command -v msm >/dev/null; then msm stop || true; fi
    rm -rf -- "$work"
    exit "$result"
}
trap cleanup EXIT
latest=$(curl -fsS --connect-timeout 15 --max-time 60 https://piston-meta.mojang.com/mc/game/version_manifest_v2.json | jq -er .latest.release)
if [[ $loader != vanilla ]]; then
    [[ -f $project/auth/dist/auth-manifest.json ]]
    supported=$(jq -er .mc "$project/auth/dist/auth-manifest.json")
    [[ $latest == "$supported" ]] || {
        printf 'Auth targets Minecraft %s; latest is %s. Update and test auth before releasing.\n' "$supported" "$latest" >&2; exit 1;
    }
fi
cp -- "$project/templates/mods-$loader.json" "$work/mods.json"
options=()
[[ $loader == vanilla ]] || options+=(--loader "$loader")
bash "$project/install.sh" --accept-eula "${options[@]}" --template "$work/mods.json" --xms 512M --xmx 2G --startup-timeout 600 --no-start
cat >> /srv/minecraft/server/server.properties <<'PROPERTIES'
server-ip=127.0.0.1
white-list=false
pause-when-empty-seconds=0
view-distance=2
simulation-distance=2
spawn-protection=0
PROPERTIES
if [[ $loader != vanilla ]]; then
    cat >> /srv/minecraft/server/server.properties <<'PROPERTIES'
online-mode=false
enforce-secure-profile=false
enable-rcon=true
rcon.port=25575
rcon.password=auth-integration-only
PROPERTIES
fi
msm start
msm status
jq -e --arg mc "$latest" --arg loader "$loader" '.mc==$mc and .loader==$loader' /etc/msm/runtime.json >/dev/null
[[ $(systemctl show minecraft.service -p Description --value) == 'Minecraft Server' ]]
timeout 10 bash -c 'echo > /dev/tcp/127.0.0.1/25565'
pid=$(systemctl show minecraft.service -p MainPID --value)
tr '\0' '\n' < "/proc/$pid/cmdline" > "$work/arguments"
grep -Fxq -- -Xmx2G "$work/arguments"
if [[ $loader == neoforge ]]; then
    grep -Eq '^@libraries/net/neoforged/neoforge/.+/unix_args.txt$' "$work/arguments"
elif [[ $loader == fabric ]]; then
    grep -Fxq fabric-server-launch.jar "$work/arguments"
else
    grep -Fxq server.jar "$work/arguments"
fi
if [[ $loader != vanilla ]]; then
    jq -e --arg filename "auth-$loader-$latest.jar" '
      ([.mods[]|select(.project=="msm-auth" and .source=="bundled" and .filename==$filename)]|length)==1 and
      ([.mods[]|select(.project!="msm-auth")]|length)>=4' /etc/msm/mods.lock.json >/dev/null
    [[ -s /srv/minecraft/server/mods/auth-$loader-$latest.jar ]]
    timeout 30 bash -c 'until grep -Fq "offline authentication enabled" /srv/minecraft/server/logs/latest.log; do sleep 0.1; done'
    "$probe_java" "$project/auth/integration/ProtocolProbe.java" exercise 25565 25575 auth-integration-only
fi
msm stop
! systemctl is-active --quiet minecraft.service
msm start
timeout 10 bash -c 'echo > /dev/tcp/127.0.0.1/25565'
if [[ $loader != vanilla ]]; then
    "$probe_java" "$project/auth/integration/ProtocolProbe.java" persist 25565 25575 auth-integration-only
    # Exercise the manager's real cold snapshot, JAR replacement and restart path.
    msm mods sync --locked
    "$probe_java" "$project/auth/integration/ProtocolProbe.java" persist 25565 25575 auth-integration-only
fi
msm stop
msm backup
archive=/var/backups/minecraft/$(msm backups | head -n 1)
[[ -n $archive ]]
if [[ $loader != vanilla ]]; then
    mkdir "$work/snapshot"
    tar -xzf "$archive" -C "$work/snapshot" server/config/auth
    diff -r /srv/minecraft/server/config/auth "$work/snapshot/server/config/auth"
fi
printf 'PASS: latest Minecraft, %s full template, managed restart/sync, authentication and cold backup\n' "$loader"
