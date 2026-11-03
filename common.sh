#!/usr/bin/env bash

fail() {
    printf '%s\n' "$*" >&2
    exit 1
}

load_controller() {
    if [[ ! -f $installation_directory/controller.env ]]; then
        printf '%s\n' 'Reinstall the wrapper to enable configuration reload.' >&2
        return 1
    fi
    controller_address=$(sed -n 's/^CLASH_OVERRIDE_EXTERNAL_CONTROLLER=//p' "$installation_directory/controller.env")
    controller_secret=$(sed -n 's/^CLASH_OVERRIDE_SECRET=//p' "$installation_directory/controller.env")
    if ! [[ $controller_address =~ ^127\.0\.0\.1:([0-9]{4,5})$ && $controller_secret =~ ^[0-9a-f]{64}$ ]]; then
        return 1
    fi
    (( ${controller_address##*:} >= 1024 && ${controller_address##*:} <= 65535 ))
}

initialize_controller() {
    if [[ ! -f $installation_directory/controller.env ]]; then
        local random_port secret
        random_port=$(od -An -N2 -tu2 /dev/urandom)
        secret=$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n')
        printf 'CLASH_OVERRIDE_EXTERNAL_CONTROLLER=127.0.0.1:%s\nCLASH_OVERRIDE_SECRET=%s\n' \
            "$((49152 + random_port % 16384))" "$secret" > "$installation_directory/controller.env"
        chmod 600 "$installation_directory/controller.env"
    fi
    load_controller
}

reload_configuration() {
    if ! load_controller; then
        return 1
    fi
    local http_status
    http_status=$(printf 'header = "Authorization: Bearer %s"\n' "$controller_secret" | \
        curl --config - --noproxy '*' --silent --show-error --connect-timeout 5 --max-time 120 \
        --request PUT --header 'Content-Type: application/json' --data '{"path":""}' \
        --output /dev/null --write-out '%{http_code}' "http://$controller_address/configs?force=true") || return 1
    [[ $http_status == 204 ]]
}

initialize_context() {
    platform=$(uname -s)
    scope=user
    if [[ $(id -u) == 0 ]]; then
        scope=system
    fi
    case "$platform:$scope" in
        Linux:user)
            installation_directory="$HOME/.local/share/magic-wrapper"
            ;;
        Darwin:user)
            installation_directory="$HOME/Library/Application Support/magic-wrapper"
            ;;
        Linux:system)
            installation_directory=/var/lib/magic-wrapper
            ;;
        Darwin:system)
            installation_directory='/Library/PrivilegedHelperTools/magic-wrapper'
            ;;
        *)
            fail 'Supported Unix platforms are systemd Linux and macOS.'
            ;;
    esac
    if [[ $installation_directory == *$'\n'* || $installation_directory == *$'\r'* ]]; then
        fail 'Installation paths cannot contain newlines.'
    fi
    service_name=magic-wrapper.service
    launch_label=one.metacubex.magic-wrapper
    if [[ $platform == Linux ]]; then
        if [[ $scope == system ]]; then
            service_file="/etc/systemd/system/$service_name"
        else
            service_file="$HOME/.config/systemd/user/$service_name"
            export XDG_RUNTIME_DIR="/run/user/$(id -u)"
            export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
        fi
    else
        launch_domain="gui/$(id -u)"
        service_file="$HOME/Library/LaunchAgents/$launch_label.plist"
        if [[ $scope == system ]]; then
            launch_domain=system
            service_file="/Library/LaunchDaemons/$launch_label.plist"
        fi
    fi
}

validate_url() {
    local subscription_url=$1
    if [[ $subscription_url != https://?* || $subscription_url == *$'\n'* || $subscription_url == *$'\r'* ]]; then
        fail 'The subscription URL must be an HTTPS URL without newlines.'
    fi
}

validate_cron() {
    local expression=$1
    local field part base step start end minimum maximum
    local field_index=0
    local -a fields parts bounds
    if [[ $expression == *$'\n'* || $expression == *$'\r'* ]]; then
        return 1
    fi
    read -r -a fields <<< "$expression"
    if [[ ${#fields[@]} != 5 ]]; then
        return 1
    fi
    for field in "${fields[@]}"; do
        case $field_index in
            0)
                minimum=0
                maximum=59
                ;;
            1)
                minimum=0
                maximum=23
                ;;
            2)
                minimum=1
                maximum=31
                ;;
            3)
                minimum=1
                maximum=12
                ;;
            4)
                minimum=0
                maximum=7
                ;;
        esac
        if [[ $field == ,* || $field == *, || $field == *,,* ]]; then
            return 1
        fi
        IFS=, read -r -a parts <<< "$field"
        for part in "${parts[@]}"; do
            if [[ ! $part =~ ^(\*|[0-9]{1,2}(-[0-9]{1,2})?)(/[0-9]{1,9})?$ ]]; then
                return 1
            fi
            base=${part%%/*}
            if [[ $part == */* ]]; then
                if [[ $base != '*' && $base != *-* ]]; then
                    return 1
                fi
                step=${part##*/}
                if (( 10#$step <= 0 )); then
                    return 1
                fi
            fi
            if [[ $base != '*' ]]; then
                IFS=- read -r -a bounds <<< "$base"
                start=$((10#${bounds[0]}))
                end=$start
                if [[ ${#bounds[@]} == 2 ]]; then
                    end=$((10#${bounds[1]}))
                fi
                if (( start < minimum || end > maximum || start > end )); then
                    return 1
                fi
            fi
        done
        field_index=$((field_index + 1))
    done
}

acquire_lock() {
    # shortcut: SIGKILL can leave this lock behind; remove it only after checking the recorded PID.
    if ! mkdir "$installation_directory/.lock" 2>/dev/null; then
        return 1
    fi
    printf '%s\n' "$$" > "$installation_directory/.lock/pid"
}

release_lock() {
    rm -f "$installation_directory/.lock/pid"
    rmdir "$installation_directory/.lock"
}

systemctl_command() {
    if [[ $scope == user ]]; then
        systemctl --user "$@"
    else
        systemctl "$@"
    fi
}

service_exists() {
    if [[ $platform == Linux ]]; then
        [[ -e $service_file ]] || systemctl_command cat "$service_name" >/dev/null 2>&1
    else
        [[ -e $service_file ]] || launchctl print "$launch_domain/$launch_label" >/dev/null 2>&1
    fi
}

stop_service() {
    if [[ $platform == Linux ]]; then
        systemctl_command stop "$service_name"
    elif launchctl print "$launch_domain/$launch_label" >/dev/null 2>&1; then
        launchctl bootout "$launch_domain/$launch_label"
    fi
}

restart_service() {
    if [[ $platform == Linux ]]; then
        systemctl_command restart "$service_name" || return
    elif launchctl print "$launch_domain/$launch_label" >/dev/null 2>&1; then
        launchctl kickstart -k "$launch_domain/$launch_label" || return
    else
        launchctl bootstrap "$launch_domain" "$service_file" || return
    fi
    sleep 2
    if [[ $platform == Linux ]]; then
        systemctl_command is-active --quiet "$service_name"
    else
        launchctl print "$launch_domain/$launch_label" | awk '$1 == "pid" && $2 == "=" { running = 1 } END { exit !running }'
    fi
}

systemd_quote() {
    local value=$1
    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    value=${value//%/%%}
    value=${value//\$/\$\$}
    printf '"%s"' "$value"
}

xml_escape() {
    printf '%s' "$1" | sed \
        -e 's/\&/\&amp;/g' \
        -e 's/</\&lt;/g' \
        -e 's/>/\&gt;/g' \
        -e 's/"/\&quot;/g' \
        -e "s/'/\&apos;/g"
}

register_service() {
    local executable arguments service_target program_arguments
    executable="$installation_directory/mihomo"
    arguments="-d $(systemd_quote "$installation_directory") -f $(systemd_quote "$installation_directory/config.yaml")"
    if [[ -f $installation_directory/controller.env ]]; then
        executable=/bin/bash
        arguments=$(systemd_quote "$installation_directory/run.sh")
    fi
    mkdir -p "$(dirname "$service_file")"
    if [[ $platform == Linux ]]; then
        if [[ $scope == user ]]; then
            service_target=default.target
        else
            service_target=multi-user.target
        fi
        cat > "$service_file" <<EOF
[Unit]
Description=Magic Mihomo wrapper
After=network.target

[Service]
ExecStart=$(systemd_quote "$executable") $arguments
Restart=on-failure
RestartSec=5
UMask=0077

[Install]
WantedBy=$service_target
EOF
        chmod 600 "$service_file"
        systemctl_command daemon-reload
        systemctl_command enable "$service_name"
    else
        if [[ -f $installation_directory/controller.env ]]; then
            program_arguments=$(printf '<string>/bin/bash</string><string>%s</string>\n' \
                "$(xml_escape "$installation_directory/run.sh")")
        else
            program_arguments=$(printf '<string>%s</string><string>-d</string><string>%s</string><string>-f</string><string>%s</string>\n' \
                "$(xml_escape "$installation_directory/mihomo")" \
                "$(xml_escape "$installation_directory")" \
                "$(xml_escape "$installation_directory/config.yaml")")
        fi
        cat > "$service_file" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$launch_label</string>
<key>ProgramArguments</key><array>
$program_arguments
</array>
<key>RunAtLoad</key><true/><key>KeepAlive</key><true/>
<key>Umask</key><integer>63</integer>
<key>StandardOutPath</key><string>$(xml_escape "$installation_directory/mihomo.log")</string>
<key>StandardErrorPath</key><string>$(xml_escape "$installation_directory/mihomo.log")</string>
</dict></plist>
EOF
        chmod 600 "$service_file"
    fi
}

remove_service() {
    if [[ $platform == Linux ]]; then
        if service_exists; then
            systemctl_command disable --now "$service_name"
            rm -f "$service_file"
            systemctl_command daemon-reload
        fi
    else
        stop_service
        rm -f "$service_file"
    fi
}

read_crontab() {
    local destination=$1
    if LC_ALL=C crontab -l > "$destination" 2> "$destination.error"; then
        rm -f "$destination.error"
    elif [[ $(cat "$destination.error") == *'no crontab for '* ]]; then
        : > "$destination"
        rm -f "$destination.error"
    else
        cat "$destination.error" >&2
        return 1
    fi
}

shell_quote() {
    printf "'%s'" "${1//\'/\'\\\'\'}"
}

write_schedule() {
    local expression=${1-}
    local command
    read_crontab "$temporary_directory/crontab"
    awk '$0 !~ / # magic-wrapper$/' "$temporary_directory/crontab" > "$temporary_directory/crontab.new"
    if [[ -n $expression ]]; then
        command="/bin/bash $(shell_quote "$installation_directory/update.sh") >> $(shell_quote "$installation_directory/update.log") 2>&1"
        command=${command//%/\\%}
        printf '%s %s # magic-wrapper\n' "$expression" "$command" >> "$temporary_directory/crontab.new"
    fi
    crontab "$temporary_directory/crontab.new"
}

download_configuration() {
    local subscription_url=$1
    local destination=$2
    local escaped_url
    validate_url "$subscription_url"
    escaped_url=${subscription_url//\\/\\\\}
    escaped_url=${escaped_url//\"/\\\"}
    # Keep subscription tokens out of the download process's command line.
    if ! printf 'url = "%s"\n' "$escaped_url" | curl --config - --noproxy '*' \
        --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
        --connect-timeout 15 --max-time 120 --retry 2 --output "$destination" \
        2> "$temporary_directory/download.error"; then
        printf '%s\n' 'Subscription download failed; the active configuration was preserved.' >&2
        return 1
    fi
    if [[ ! -s $destination ]]; then
        printf '%s\n' 'The subscription returned an empty file.' >&2
        return 1
    fi
}

validate_configuration() {
    local executable=$1
    local configuration=$2
    if ! "$executable" -t -d "$installation_directory" -f "$configuration" > "$installation_directory/validation.log" 2>&1; then
        printf '%s\n' "Invalid Mihomo configuration; see $installation_directory/validation.log." >&2
        return 1
    fi
}
