# syntax=docker/dockerfile:1.7

ARG CPA_IMAGE=eceasy/cli-proxy-api:latest

FROM --platform=$TARGETPLATFORM ${CPA_IMAGE}

ARG TARGETARCH
ARG SING_BOX_VERSION=1.13.13
ARG SING_BOX_SHA256_AMD64=a74001a9304c1722fdcd01a5145526a22ff35b0da9cd73a4887e910c1ce9b480
ARG SING_BOX_SHA256_ARM64=e58c2c6c44d9714d72c9230d81698df366fa2b4ecd6e5a551a4b77ec85b629f9

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends curl jq openssl tini; \
    rm -rf /var/lib/apt/lists/*; \
    case "${TARGETARCH}" in \
        amd64) sing_box_sha256="${SING_BOX_SHA256_AMD64}" ;; \
        arm64) sing_box_sha256="${SING_BOX_SHA256_ARM64}" ;; \
        *) echo "Unsupported architecture: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    archive="sing-box-${SING_BOX_VERSION}-linux-${TARGETARCH}-glibc.tar.gz"; \
    curl --fail --location --retry 5 --retry-all-errors \
        "https://github.com/SagerNet/sing-box/releases/download/v${SING_BOX_VERSION}/${archive}" \
        --output "/tmp/${archive}"; \
    echo "${sing_box_sha256}  /tmp/${archive}" | sha256sum --check --strict; \
    tar -xzf "/tmp/${archive}" -C /tmp; \
    install -m 0755 "/tmp/sing-box-${SING_BOX_VERSION}-linux-${TARGETARCH}-glibc/sing-box" /usr/local/bin/sing-box; \
    rm -rf "/tmp/${archive}" "/tmp/sing-box-${SING_BOX_VERSION}-linux-${TARGETARCH}-glibc"; \
    mkdir -p \
        /home/warpa/auths \
        /home/warpa/data \
        /home/warpa/logs \
        /home/warpa/plugins \
        /home/warpa/static \
        /home/warpa/warp

COPY entrypoint-warpa.sh /usr/local/bin/entrypoint-warpa
COPY warp-entrypoint.sh /usr/local/bin/warp-entrypoint

RUN chmod 0755 /usr/local/bin/entrypoint-warpa /usr/local/bin/warp-entrypoint

WORKDIR /home/warpa

EXPOSE 8317

ENV TZ=Asia/Shanghai \
    DEPLOY=cloud \
    NET_PORT=9091 \
    WARP_RESTART_DELAY=10 \
    WARP_RESTART_MAX_DELAY=300 \
    WARP_RESTART_STABLE_TIME=60

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint-warpa"]
