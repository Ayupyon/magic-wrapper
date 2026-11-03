#!/usr/bin/env bash
set -euo pipefail
umask 077

source_directory=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
source "$source_directory/common.sh"
initialize_context

if [[ ! -f $installation_directory/scope ]]; then
    printf '%s\n' 'No wrapper installation found for the current user/scope.'
    exit 0
fi
if ! acquire_lock; then
    fail 'Another wrapper operation is running; check the installation .lock directory.'
fi
temporary_directory=$(mktemp -d "$installation_directory/.uninstall.XXXXXX")
trap '
    rm -rf "$temporary_directory"
    release_lock
' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

write_schedule
remove_service
rm -f "$installation_directory/scope"
printf 'Uninstalled the %s service and update schedule. Files are preserved in %s\n' "$scope" "$installation_directory"
