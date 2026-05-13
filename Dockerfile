# syntax=docker/dockerfile:1.7

ARG WARP_IMAGE=ghcr.io/mon-ius/docker-warp-socks:v5
ARG CPA_IMAGE=eceasy/cli-proxy-api:latest

FROM --platform=$TARGETPLATFORM ${CPA_IMAGE} AS cpa
FROM --platform=$TARGETPLATFORM ${WARP_IMAGE}

COPY --from=cpa /CLIProxyAPI/CLIProxyAPI /CLIProxyAPI/CLIProxyAPI
COPY --from=cpa /CLIProxyAPI/config.example.yaml /CLIProxyAPI/config.example.yaml

COPY entrypoint-warpa.sh /entrypoint-warpa.sh

RUN chmod +x /entrypoint-warpa.sh /CLIProxyAPI/CLIProxyAPI \
    && mkdir -p /CLIProxyAPI /home/warpa/auths /home/warpa/logs

WORKDIR /CLIProxyAPI

EXPOSE 8317

ENV TZ=Asia/Shanghai
ENV DEPLOY=cloud
ENV NET_PORT=9091
ENV WARP_START_DELAY=8

ENTRYPOINT ["/entrypoint-warpa.sh"]
