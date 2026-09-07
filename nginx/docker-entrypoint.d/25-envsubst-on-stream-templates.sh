#!/usr/bin/env sh
# ============================================================================
#  Renders /etc/nginx/stream-templates/*.conf.template into /etc/nginx/stream.d
#
#  The stock nginx entrypoint only does this for http templates. The stream
#  block (MQTT on 8883) needs the same treatment, so this mirrors what
#  20-envsubst-on-templates.sh does.
# ============================================================================
set -e

ME="$(basename "$0")"
template_dir=/etc/nginx/stream-templates
output_dir=/etc/nginx/stream.d
suffix=.template

[ -d "$template_dir" ] || exit 0
mkdir -p "$output_dir"

# Substitute only variables that actually exist in the environment, so nginx's
# own runtime variables ($remote_addr, $ssl_preread_server_name, ...) survive.
defined_envs="$(printf '${%s} ' $(awk 'END { for (name in ENVIRON) { print name } }' </dev/null))"

find "$template_dir" -follow -type f -name "*$suffix" -print | while read -r template; do
    relative_path="${template#"$template_dir/"}"
    output_path="$output_dir/${relative_path%"$suffix"}"

    subdir="$(dirname "$output_path")"
    mkdir -p "$subdir"

    echo "$ME: rendering $template -> $output_path"
    envsubst "$defined_envs" < "$template" > "$output_path"
done
