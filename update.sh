#!/usr/bin/env bash
set -euo pipefail
umask 077

source_directory=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
source "$source_directory/common.sh"
initialize_context

if [[ ! -f $installation_directory/scope ]]; then
    fail 'No wrapper installation found for the current user/scope.'
fi
if ! acquire_lock; then
    printf '%s\n' 'Another wrapper operation is running; skipping update.'
    exit 0
fi
temporary_directory=$(mktemp -d "$installation_directory/.update.XXXXXX")
trap '
    rm -rf "$temporary_directory"
    release_lock
' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

subscription_url=$(cat "$installation_directory/subscription-url")
if ! load_controller; then
    fail 'Controller settings are missing or invalid; reinstall the wrapper.'
fi
download_configuration "$subscription_url" "$temporary_directory/config.yaml"
validate_configuration "$installation_directory/mihomo" "$temporary_directory/config.yaml"
if cmp -s "$temporary_directory/config.yaml" "$installation_directory/config.yaml"; then
    printf '%s\n' 'Configuration unchanged.'
    exit 0
fi

cp -p "$installation_directory/config.yaml" "$temporary_directory/config.previous.yaml"
mv -f "$temporary_directory/config.previous.yaml" "$installation_directory/config.previous.yaml"
mv -f "$temporary_directory/config.yaml" "$installation_directory/config.yaml"
if ! reload_configuration; then
    cp -p "$installation_directory/config.previous.yaml" "$temporary_directory/restore.yaml"
    mv -f "$temporary_directory/restore.yaml" "$installation_directory/config.yaml"
    if ! reload_configuration; then
        printf '%s\n' 'The previous file was restored, but its reload failed; manual recovery is required.' >&2
    fi
    fail 'Mihomo reload failed; restored the previous configuration.'
fi
printf '%s\n' 'Configuration updated and Mihomo reloaded.'
