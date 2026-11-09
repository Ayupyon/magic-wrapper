#!/usr/bin/env bash
set -euo pipefail
umask 077

source_directory=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
source "$source_directory/common.sh"
initialize_context

if [[ $# != 2 ]]; then
    fail "Usage: $0 SUBSCRIPTION_URL 'MIN HOUR DAY MONTH WEEKDAY'"
fi
subscription_url=$1
schedule=$2
validate_url "$subscription_url"
if ! validate_cron "$schedule"; then
    fail 'Invalid cron expression. Use five numeric fields, with *, lists, ranges, and steps on * or ranges.'
fi
if [[ $subscription_url == http://* ]]; then
    printf '%s\n' 'Warning: HTTP is unencrypted. Subscription tokens and configuration can be read or modified in transit.'
    printf 'Install using this HTTP subscription anyway? [y/N] '
    read -r answer || answer=
    if [[ $answer != y && $answer != Y ]]; then
        printf '%s\n' 'Installation cancelled.'
        exit 0
    fi
fi
for dependency in curl crontab; do
    if ! command -v "$dependency" >/dev/null; then
        fail "Missing dependency: $dependency"
    fi
done
if [[ $platform == Linux ]]; then
    if ! command -v systemctl >/dev/null; then
        fail 'Linux requires systemd.'
    fi
fi
if [[ ! -x $source_directory/mihomo ]]; then
    fail 'Place an executable mihomo binary beside install.sh.'
fi
if [[ -L $installation_directory ]]; then
    fail 'The installation directory cannot be a symbolic link.'
fi
if [[ -f $installation_directory/subscription-url ]]; then
    printf 'Replace existing %s installation settings? [y/N] ' "$scope"
    read -r answer || answer=
    if [[ $answer != y && $answer != Y ]]; then
        printf '%s\n' 'Installation cancelled.'
        exit 0
    fi
fi
if [[ ! -f $installation_directory/scope ]] && service_exists; then
    fail 'A service with the wrapper name already exists without wrapper settings; refusing to overwrite it.'
fi
mkdir -p "$installation_directory"
chmod 700 "$installation_directory"
if ! acquire_lock; then
    fail 'Another wrapper operation is running; check the installation .lock directory.'
fi
temporary_directory=$(mktemp -d "$installation_directory/.install.XXXXXX")
trap '
    rm -rf "$temporary_directory"
    release_lock
' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

download_configuration "$subscription_url" "$temporary_directory/config.yaml"
validate_configuration "$source_directory/mihomo" "$temporary_directory/config.yaml"
managed_files=(
    common.sh run.sh install.sh update.sh uninstall.sh mihomo
    subscription-url schedule scope config.yaml controller.env
)
mkdir "$temporary_directory/previous"
for filename in "${managed_files[@]}"; do
    if [[ -L $installation_directory/$filename ]]; then
        fail 'Managed files cannot be symbolic links.'
    fi
    if [[ -f $installation_directory/$filename ]]; then
        cp -p "$installation_directory/$filename" "$temporary_directory/previous/$filename"
    fi
done
read_crontab "$temporary_directory/original-crontab"
previous_installation=false
if [[ -f $installation_directory/scope ]]; then
    previous_installation=true
fi

rollback_installation() {
    local exit_status=$?
    trap - EXIT
    if (( exit_status != 0 )); then
        printf '%s\n' 'Installation failed; restoring the previous installation.' >&2
        remove_service || true
        for filename in "${managed_files[@]}"; do
            rm -f "$installation_directory/$filename"
            if [[ -f $temporary_directory/previous/$filename ]]; then
                cp -p "$temporary_directory/previous/$filename" "$installation_directory/$filename"
            fi
        done
        if ! crontab "$temporary_directory/original-crontab"; then
            printf '%s\n' 'Failed to restore crontab; manual recovery is required.' >&2
        fi
        if $previous_installation; then
            if ! register_service || ! restart_service; then
                printf '%s\n' 'Failed to restart the previous service; manual recovery is required.' >&2
            fi
        fi
    fi
    rm -rf "$temporary_directory"
    release_lock
    exit "$exit_status"
}
trap rollback_installation EXIT

if $previous_installation; then
    stop_service
fi
for filename in common.sh run.sh install.sh update.sh uninstall.sh mihomo; do
    cp "$source_directory/$filename" "$temporary_directory/$filename"
    chmod 700 "$temporary_directory/$filename"
    mv -f "$temporary_directory/$filename" "$installation_directory/$filename"
done

printf '%s\n' "$subscription_url" > "$installation_directory/subscription-url"
printf '%s\n' "$schedule" > "$installation_directory/schedule"
printf '%s\n' "$scope" > "$installation_directory/scope"
mv -f "$temporary_directory/config.yaml" "$installation_directory/config.yaml"
initialize_controller
register_service
write_schedule "$schedule"
restart_service
reload_configuration
printf 'Installed %s service in %s\n' "$scope" "$installation_directory"
