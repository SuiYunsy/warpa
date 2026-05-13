#!/bin/sh
set -eu

WARPA_HOME="/home/warpa"
CPA_CONFIG="${WARPA_HOME}/config.yaml"
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

mkdir -p "${WARPA_HOME}/auths" "${WARPA_HOME}/logs" /CLIProxyAPI

# CLIProxyAPI cloud mode may resolve its log directory to /home/logs.
# Keep that path pointing at the warpa log directory on fresh deployments.
if [ ! -e /home/logs ]; then
    ln -s "${WARPA_HOME}/logs" /home/logs 2>/dev/null || true
fi

if [ ! -f "$CPA_CONFIG" ]; then
    log "Creating default CLIProxyAPI config at ${CPA_CONFIG}"
    cp /CLIProxyAPI/config.example.yaml "$CPA_CONFIG"
    set_yaml_key "auth-dir" '"/home/warpa/auths"' "$CPA_CONFIG"
    set_yaml_key "logging-to-file" "true" "$CPA_CONFIG"
    set_yaml_key "logs-max-total-size-mb" "10" "$CPA_CONFIG"
else
    log "Using existing CLIProxyAPI config at ${CPA_CONFIG}"
fi

log "Starting userspace WARP proxy on NET_PORT=${NET_PORT:-9091}..."
/run/entrypoint.sh rws-cli-v5 &
WARP_PID="$!"

log "Waiting ${WARP_START_DELAY}s for WARP startup..."
sleep "$WARP_START_DELAY"

log "Starting CLIProxyAPI with config ${CPA_CONFIG}..."
cd "$WARPA_HOME"
/CLIProxyAPI/CLIProxyAPI -config "$CPA_CONFIG" &
CPA_PID="$!"

while :; do
    if ! kill -0 "$WARP_PID" 2>/dev/null; then
        STATUS=0
        wait "$WARP_PID" 2>/dev/null || STATUS="$?"
        log "WARP process exited with status ${STATUS}; stopping CLIProxyAPI..."
        stop_children
        exit "$STATUS"
    fi

    if ! kill -0 "$CPA_PID" 2>/dev/null; then
        STATUS=0
        wait "$CPA_PID" 2>/dev/null || STATUS="$?"
        log "CLIProxyAPI process exited with status ${STATUS}; stopping WARP..."
        stop_children
        exit "$STATUS"
    fi

    sleep 1
done
