#!/bin/sh
set -eu

WARPA_HOME="${WARPA_HOME:-/home/warpa}"
WARP_HOME="${WARP_HOME:-${WARPA_HOME}/warp}"
WARP_CREDENTIALS="${WARP_CREDENTIALS:-${WARP_HOME}/credentials.json}"
WARP_CONFIG="${WARP_CONFIG:-${WARP_HOME}/config.json}"
WARP_REGISTER_ENDPOINT="${WARP_REGISTER_ENDPOINT:-https://api.cloudflareclient.com/v0a2025/reg}"
WARP_SERVER="${WARP_SERVER:-engage.cloudflareclient.com}"
WARP_PORT="${WARP_PORT:-2408}"
NET_PORT="${NET_PORT:-9091}"

log() {
    printf '%s %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*"
}

register_warp() {
    log "Registering a persistent Cloudflare WARP identity..."
    secret_key="$(openssl genpkey -algorithm X25519 2>/dev/null)"
    private_key="$(printf '%s\n' "$secret_key" | openssl pkey -outform DER 2>/dev/null | tail -c 32 | base64 | tr -d '\n')"
    public_key="$(printf '%s\n' "$secret_key" | openssl pkey -pubout -outform DER 2>/dev/null | tail -c 32 | base64 | tr -d '\n')"
    tos="$(date -u +'%Y-%m-%dT%H:%M:%S.000Z')"
    payload="$(jq -cn --arg tos "$tos" --arg key "$public_key" '{tos: $tos, key: $key, referrer: ""}')"
    response_file="$(mktemp "${WARP_HOME}/registration.XXXXXX")"

    if ! curl --fail --silent --show-error --location \
        --connect-timeout 15 --max-time 60 --retry 5 --retry-all-errors \
        --header 'Content-Type: application/json' \
        --request POST --data "$payload" \
        "$WARP_REGISTER_ENDPOINT" --output "$response_file"; then
        rm -f "$response_file"
        return 1
    fi

    client_id="$(jq -r '.config.client_id // .client_id // .client // empty' "$response_file")"
    peer_public_key="$(jq -r '.config.peers[0].public_key // .public_key // .key // empty' "$response_file")"
    address_v4="$(jq -r '.config.interface.addresses.v4 // .interface.addresses.v4 // .addresses.v4 // .v4 // empty' "$response_file")"
    address_v6="$(jq -r '.config.interface.addresses.v6 // .interface.addresses.v6 // .addresses.v6 // .v6 // empty' "$response_file")"

    if [ -z "$client_id" ] || [ -z "$peer_public_key" ] || [ -z "$address_v4" ] || [ -z "$address_v6" ]; then
        log "Cloudflare registration response is missing required fields."
        rm -f "$response_file"
        return 1
    fi

    credentials_tmp="${WARP_CREDENTIALS}.tmp"
    jq -cn \
        --arg client "$client_id" \
        --arg v4 "$address_v4" \
        --arg v6 "$address_v6" \
        --arg key "$peer_public_key" \
        --arg secret "$private_key" \
        '{client: $client, v4: $v4, v6: $v6, key: $key, secret: $secret}' \
        > "$credentials_tmp"
    chmod 0600 "$credentials_tmp"
    mv -f "$credentials_tmp" "$WARP_CREDENTIALS"
    rm -f "$response_file"
}

credentials_valid() {
    [ -s "$WARP_CREDENTIALS" ] &&
        jq -e '
            (.client | type == "string" and length > 0) and
            (.v4 | type == "string" and length > 0) and
            (.v6 | type == "string" and length > 0) and
            (.key | type == "string" and length > 0) and
            (.secret | type == "string" and length > 0)
        ' "$WARP_CREDENTIALS" >/dev/null 2>&1
}

umask 077
mkdir -p "$WARP_HOME"

if [ "${WARP_RESET_CREDENTIALS:-0}" = "1" ]; then
    log "WARP_RESET_CREDENTIALS=1; removing saved WARP identity."
    rm -f "$WARP_CREDENTIALS"
fi

if ! credentials_valid; then
    rm -f "$WARP_CREDENTIALS"
    register_warp
else
    log "Using persistent WARP identity at ${WARP_CREDENTIALS}"
fi

client_id="$(jq -r '.client' "$WARP_CREDENTIALS")"
address_v4="$(jq -r '.v4' "$WARP_CREDENTIALS")"
address_v6="$(jq -r '.v6' "$WARP_CREDENTIALS")"
peer_public_key="$(jq -r '.key' "$WARP_CREDENTIALS")"
private_key="$(jq -r '.secret' "$WARP_CREDENTIALS")"

reserved_bytes="$(printf '%s' "$client_id" | base64 -d 2>/dev/null | od -An -t u1 || true)"
set -- $reserved_bytes
if [ "$#" -lt 3 ]; then
    log "Saved WARP client ID is invalid. Set WARP_RESET_CREDENTIALS=1 once to replace it."
    exit 1
fi
reserved="[$1,$2,$3]"

jq -n \
    --arg server "$WARP_SERVER" \
    --argjson warp_port "$WARP_PORT" \
    --argjson net_port "$NET_PORT" \
    --arg address_v4 "${address_v4}/32" \
    --arg address_v6 "${address_v6}/128" \
    --arg private_key "$private_key" \
    --arg peer_public_key "$peer_public_key" \
    --argjson reserved "$reserved" \
    --arg cache_path "${WARP_HOME}/cache.db" \
    '{
        log: {level: "info", timestamp: true},
        dns: {
            servers: [
                {
                    type: "https",
                    tag: "dns-remote",
                    server: "1.1.1.1",
                    server_port: 443,
                    path: "/dns-query",
                    detour: "WARP",
                    domain_resolver: "dns-local"
                },
                {type: "local", tag: "dns-local"}
            ],
            rules: [{ip_is_private: true, server: "dns-local"}],
            final: "dns-remote",
            strategy: "prefer_ipv4"
        },
        experimental: {cache_file: {enabled: true, path: $cache_path}},
        inbounds: [
            {
                type: "mixed",
                tag: "mixed-in",
                listen: "127.0.0.1",
                listen_port: $net_port
            }
        ],
        outbounds: [{tag: "direct", type: "direct"}],
        endpoints: [
            {
                type: "wireguard",
                tag: "WARP",
                mtu: 1408,
                address: [$address_v4, $address_v6],
                private_key: $private_key,
                peers: [
                    {
                        address: $server,
                        port: $warp_port,
                        public_key: $peer_public_key,
                        allowed_ips: ["0.0.0.0/0", "::/0"],
                        persistent_keepalive_interval: 25,
                        reserved: $reserved
                    }
                ],
                domain_resolver: "dns-local"
            }
        ],
        route: {
            rules: [
                {action: "sniff"},
                {protocol: "dns", action: "hijack-dns"},
                {ip_is_private: true, outbound: "direct"},
                {
                    ip_cidr: [
                        "0.0.0.0/8",
                        "10.0.0.0/8",
                        "127.0.0.0/8",
                        "169.254.0.0/16",
                        "172.16.0.0/12",
                        "192.168.0.0/16",
                        "224.0.0.0/4",
                        "240.0.0.0/4",
                        "52.80.0.0/16",
                        "112.95.0.0/16"
                    ],
                    outbound: "direct"
                }
            ],
            final: "WARP",
            auto_detect_interface: true,
            default_domain_resolver: {server: "dns-local"}
        }
    }' > "${WARP_CONFIG}.tmp"

chmod 0600 "${WARP_CONFIG}.tmp"
mv -f "${WARP_CONFIG}.tmp" "$WARP_CONFIG"

sing-box check -c "$WARP_CONFIG"
log "WARP configuration is valid; starting sing-box."
exec sing-box -c "$WARP_CONFIG" run
