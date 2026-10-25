#!/bin/bash
set -Eeuo pipefail
source /usr/local/lib/msm/lib/common.sh

[[ $# == 0 && $EUID != 0 && $(id -un) == minecraft ]] || msm_die 'This launcher must run as minecraft without arguments.'
msm_trusted_file "$MSM_CONFIG/runtime.json"
msm_trusted_file "$MSM_CONFIG/settings.json"
msm_validate_runtime "$MSM_CONFIG/runtime.json"
msm_validate_settings "$MSM_CONFIG/settings.json"
msm_validate_properties
java_home=$(jq -r .java_home "$MSM_CONFIG/runtime.json")
arguments=$(msm_runtime_launch_file "$MSM_CONFIG/runtime.json")
minimum=$(jq -r .memory_min "$MSM_CONFIG/settings.json")
maximum=$(jq -r .memory_max "$MSM_CONFIG/settings.json")
[[ -d $MSM_SERVER && ! -L $MSM_SERVER && -x $java_home/bin/java && ! -L $java_home ]] || msm_die 'The server or Java directory is incomplete.'
[[ -f $MSM_SERVER/$arguments && ! -L $MSM_SERVER/$arguments && -s $MSM_SERVER/$arguments ]] || msm_die 'The runtime launch file is missing or unsafe.'
unset JAVA_TOOL_OPTIONS _JAVA_OPTIONS JDK_JAVA_OPTIONS CLASSPATH
cd -- "$MSM_SERVER"
if [[ $(jq -r '.loader // "neoforge"' "$MSM_CONFIG/runtime.json") != neoforge ]]; then
    exec "$java_home/bin/java" "-Xms$minimum" "-Xmx$maximum" -Dfile.encoding=UTF-8 -jar "$arguments" nogui
fi
exec "$java_home/bin/java" "-Xms$minimum" "-Xmx$maximum" -Dfile.encoding=UTF-8 "@$arguments" nogui
