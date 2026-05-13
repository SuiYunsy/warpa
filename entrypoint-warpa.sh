#!/bin/sh
set -eu

CONFIG_FILE="/home/warpa/config.yaml"
WARP_START_DELAY="${WARP_START_DELAY:-8}"
CPA_PID=""
WARP_PID=""

log() {
    printf '%s\n' "$*"
}

set_yaml_key() {
    key="$1"
    value="$2"
    file="$3"

    if grep -q "^${key}:" "$file"; then
        sed -i "s|^${key}:.*|${key}: ${value}|" "$file"
    else
        printf '%s: %s\n' "$key" "$value" >> "$file"
    fi
}

stop_children() {
    trap - INT TERM

    if [ -n "$CPA_PID" ] && kill -0 "$CPA_PID" 2>/dev/null; then
        kill -TERM "$CPA_PID" 2>/dev/null || true
    fi

    if [ -n "$WARP_PID" ] && kill -0 "$WARP_PID" 2>/dev/null; then
        kill -TERM "$WARP_PID" 2>/dev/null || true
    fi

    wait ${CPA_PID:-} 2>/dev/null || true
    wait ${WARP_PID:-} 2>/dev/null || true
}

terminate() {
    log "Received termination signal; stopping child processes..."
    stop_children
    exit 143
}

trap terminate INT TERM

mkdir -p /home/warpa/auths /home/warpa/logs /CLIProxyAPI

if [ ! -f "$CONFIG_FILE" ]; then
    log "Creating default CLIProxyAPI config at ${CONFIG_FILE}"
    cp /CLIProxyAPI/config.example.yaml "$CONFIG_FILE"
    set_yaml_key "auth-dir" '"/home/warpa/auths"' "$CONFIG_FILE"
    set_yaml_key "logging-to-file" "true" "$CONFIG_FILE"
    set_yaml_key "logs-max-total-size-mb" "10" "$CONFIG_FILE"
else
    log "Using existing CLIProxyAPI config at ${CONFIG_FILE}"
fi

log "Starting userspace WARP mixed proxy on NET_PORT=${NET_PORT:-9091}..."
/run/entrypoint.sh rws-cli-v5 &
WARP_PID="$!"

log "Waiting ${WARP_START_DELAY}s for WARP startup..."
sleep "$WARP_START_DELAY"

log "Starting CLIProxyAPI with config ${CONFIG_FILE}..."
/CLIProxyAPI/CLIProxyAPI -config "$CONFIG_FILE" &
CPA_PID="$!"

while :; do
    if ! kill -0 "$WARP_PID" 2>/dev/null; then
        wait "$WARP_PID" 2>/dev/null || STATUS="$?"
        STATUS="${STATUS:-0}"
        log "WARP process exited with status ${STATUS}; stopping CLIProxyAPI..."
        stop_children
        exit "$STATUS"
    fi

    if ! kill -0 "$CPA_PID" 2>/dev/null; then
        wait "$CPA_PID" 2>/dev/null || STATUS="$?"
        STATUS="${STATUS:-0}"
        log "CLIProxyAPI process exited with status ${STATUS}; stopping WARP..."
        stop_children
        exit "$STATUS"
    fi

    sleep 1
done
