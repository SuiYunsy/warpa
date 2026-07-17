#!/bin/sh
set -eu

WARPA_HOME="${WARPA_HOME:-/home/warpa}"
CPA_BIN="${CPA_BIN:-/CLIProxyAPI/CLIProxyAPI}"
CPA_CONFIG="${CPA_CONFIG:-${WARPA_HOME}/config.yaml}"
WARP_COMMAND="${WARP_COMMAND:-/usr/local/bin/warp-entrypoint}"
WARP_RESTART_DELAY="${WARP_RESTART_DELAY:-10}"
WARP_RESTART_MAX_DELAY="${WARP_RESTART_MAX_DELAY:-300}"
CPA_PID=""
WARP_PID=""

log() {
    printf '%s %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*"
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

    if [ -n "$WARP_PID" ] && kill -0 "$WARP_PID" 2>/dev/null; then
        kill -TERM "$WARP_PID" 2>/dev/null || true
    fi
    if [ -n "$CPA_PID" ] && kill -0 "$CPA_PID" 2>/dev/null; then
        kill -TERM "$CPA_PID" 2>/dev/null || true
    fi

    [ -z "$WARP_PID" ] || wait "$WARP_PID" 2>/dev/null || true
    [ -z "$CPA_PID" ] || wait "$CPA_PID" 2>/dev/null || true
}

terminate() {
    log "Received termination signal; stopping child processes..."
    stop_children
    exit 143
}

start_warp() {
    log "Starting userspace WARP SOCKS proxy on 127.0.0.1:${NET_PORT:-9091}..."
    "$WARP_COMMAND" &
    WARP_PID="$!"
}

trap terminate INT TERM

mkdir -p \
    "${WARPA_HOME}/auths" \
    "${WARPA_HOME}/data" \
    "${WARPA_HOME}/logs" \
    "${WARPA_HOME}/plugins" \
    "${WARPA_HOME}/static" \
    "${WARPA_HOME}/warp"
export MANAGEMENT_STATIC_PATH="${WARPA_HOME}/static"
export WARPA_HOME

if [ ! -f "$CPA_CONFIG" ]; then
    log "Creating default CLIProxyAPI config at ${CPA_CONFIG}"
    cp /CLIProxyAPI/config.example.yaml "$CPA_CONFIG"
    set_yaml_key "auth-dir" "\"${WARPA_HOME}/auths\"" "$CPA_CONFIG"
    set_yaml_key "logging-to-file" "true" "$CPA_CONFIG"
    set_yaml_key "logs-max-total-size-mb" "10" "$CPA_CONFIG"
else
    log "Using existing CLIProxyAPI config at ${CPA_CONFIG}"
fi

log "Starting CLIProxyAPI with config ${CPA_CONFIG}..."
cd "$WARPA_HOME"
"$CPA_BIN" -config "$CPA_CONFIG" &
CPA_PID="$!"

start_warp
restart_delay="$WARP_RESTART_DELAY"

while kill -0 "$CPA_PID" 2>/dev/null; do
    if ! kill -0 "$WARP_PID" 2>/dev/null; then
        warp_status=0
        wait "$WARP_PID" 2>/dev/null || warp_status="$?"
        log "WARP exited with status ${warp_status}; CPA remains available. Retrying in ${restart_delay}s..."
        sleep "$restart_delay"

        if ! kill -0 "$CPA_PID" 2>/dev/null; then
            break
        fi

        start_warp
        if [ "$restart_delay" -lt "$WARP_RESTART_MAX_DELAY" ]; then
            restart_delay=$((restart_delay * 2))
            if [ "$restart_delay" -gt "$WARP_RESTART_MAX_DELAY" ]; then
                restart_delay="$WARP_RESTART_MAX_DELAY"
            fi
        fi
    fi
    sleep 2
done

cpa_status=0
wait "$CPA_PID" 2>/dev/null || cpa_status="$?"
log "CLIProxyAPI exited with status ${cpa_status}; stopping WARP and exiting container..."

if kill -0 "$WARP_PID" 2>/dev/null; then
    kill -TERM "$WARP_PID" 2>/dev/null || true
fi
wait "$WARP_PID" 2>/dev/null || true
exit "$cpa_status"
