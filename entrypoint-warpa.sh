#!/bin/sh
set -eu

WARPA_HOME="${WARPA_HOME:-/home/warpa}"
CPA_BIN="${CPA_BIN:-/CLIProxyAPI/CLIProxyAPI}"
CPA_CONFIG="${CPA_CONFIG:-${WARPA_HOME}/config.yaml}"
WARP_COMMAND="${WARP_COMMAND:-/usr/local/bin/warp-entrypoint}"
WARP_RESTART_DELAY="${WARP_RESTART_DELAY:-10}"
WARP_RESTART_MAX_DELAY="${WARP_RESTART_MAX_DELAY:-300}"
WARP_RESTART_STABLE_TIME="${WARP_RESTART_STABLE_TIME:-60}"
CPA_PID=""
WARP_PID=""
WARP_STARTED_AT="0"

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
    WARP_STARTED_AT="$(date +%s)"
}

normalize_uint() {
    value="$1"
    name="$2"

    case "$value" in
        ""|*[!0-9]*)
            log "${name} must be a non-negative integer; got: ${value}" >&2
            exit 2
            ;;
    esac

    value="$(printf '%s' "$value" | sed 's/^0*//')"
    printf '%s\n' "${value:-0}"
}

trap terminate INT TERM

WARP_RESTART_DELAY="$(normalize_uint "$WARP_RESTART_DELAY" WARP_RESTART_DELAY)"
WARP_RESTART_MAX_DELAY="$(normalize_uint "$WARP_RESTART_MAX_DELAY" WARP_RESTART_MAX_DELAY)"
WARP_RESTART_STABLE_TIME="$(normalize_uint "$WARP_RESTART_STABLE_TIME" WARP_RESTART_STABLE_TIME)"
if [ "$WARP_RESTART_DELAY" -gt "$WARP_RESTART_MAX_DELAY" ]; then
    WARP_RESTART_DELAY="$WARP_RESTART_MAX_DELAY"
fi

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
warp_restart_at=0

while kill -0 "$CPA_PID" 2>/dev/null; do
    now="$(date +%s)"

    if [ -n "$WARP_PID" ]; then
        if kill -0 "$WARP_PID" 2>/dev/null; then
            if [ "$restart_delay" -ne "$WARP_RESTART_DELAY" ] && \
                [ $((now - WARP_STARTED_AT)) -ge "$WARP_RESTART_STABLE_TIME" ]; then
                restart_delay="$WARP_RESTART_DELAY"
                log "WARP has remained healthy for ${WARP_RESTART_STABLE_TIME}s; restart delay reset to ${restart_delay}s."
            fi
        else
            warp_status=0
            wait "$WARP_PID" 2>/dev/null || warp_status="$?"
            WARP_PID=""
            warp_restart_at=$((now + restart_delay))
            log "WARP exited with status ${warp_status}; CPA remains available. Retrying in ${restart_delay}s..."

            if [ "$restart_delay" -lt "$WARP_RESTART_MAX_DELAY" ]; then
                restart_delay=$((restart_delay * 2))
                if [ "$restart_delay" -gt "$WARP_RESTART_MAX_DELAY" ]; then
                    restart_delay="$WARP_RESTART_MAX_DELAY"
                fi
            fi
        fi
    elif [ "$now" -ge "$warp_restart_at" ]; then
        start_warp
    fi

    sleep 2
done

cpa_status=0
wait "$CPA_PID" 2>/dev/null || cpa_status="$?"
log "CLIProxyAPI exited with status ${cpa_status}; stopping WARP and exiting container..."

if [ -n "$WARP_PID" ] && kill -0 "$WARP_PID" 2>/dev/null; then
    kill -TERM "$WARP_PID" 2>/dev/null || true
fi
[ -z "$WARP_PID" ] || wait "$WARP_PID" 2>/dev/null || true
exit "$cpa_status"
