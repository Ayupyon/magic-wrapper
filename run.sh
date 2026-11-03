#!/usr/bin/env bash
set -euo pipefail

installation_directory=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
source "$installation_directory/common.sh"

load_controller
export CLASH_OVERRIDE_EXTERNAL_CONTROLLER="$controller_address"
export CLASH_OVERRIDE_SECRET="$controller_secret"

exec "$installation_directory/mihomo" -d "$installation_directory" -f "$installation_directory/config.yaml"
