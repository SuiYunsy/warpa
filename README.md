# warpa

`warpa` packages **CLIProxyAPI + userspace Cloudflare WARP mixed proxy** into a single Docker image for platforms such as Azure App Service that expect a single HTTP entrypoint.

The container starts a userspace WARP mixed proxy internally on `127.0.0.1:9091`, then starts CLIProxyAPI on port `8317`. CLIProxyAPI is configured to use the internal WARP proxy as its outbound proxy.

Published image:

```text
ghcr.io/suiyunsy/warpa:latest
```

## Ports and security model

Only port `8317` is exposed by the image and should be published in production. Port `9091` is the internal WARP mixed proxy port for CLIProxyAPI only; do **not** expose `9091` publicly.

This image uses `ghcr.io/mon-ius/docker-warp-socks:v5` and does not require `privileged`, `NET_ADMIN`, `SYS_MODULE`, `/dev/net/tun`, or custom `sysctls`.

## Persistent paths

The image is designed for Azure App Service storage and uses `/home` for persistent data:

```text
/home/config.yaml  # CLIProxyAPI config
/home/auths        # CLIProxyAPI auth directory
/home/logs         # CLIProxyAPI logs
```

If `/home/config.yaml` does not exist at startup, the entrypoint copies `/CLIProxyAPI/config.example.yaml` and sets these values:

```yaml
host: "0.0.0.0"
port: 8317
auth-dir: "/home/auths"
logging-to-file: true
proxy-url: "http://127.0.0.1:9091"
```

`host: "0.0.0.0"` binds CLIProxyAPI to all container interfaces so the published port works; only publish `8317` as described in the Ports and security model section.

If `/home/config.yaml` already exists, it is used as-is and is not overwritten.

## Local run

```bash
docker run --rm -it \
  -p 8317:8317 \
  -v "$PWD/config.yaml:/home/config.yaml" \
  -v "$PWD/auths:/home/auths" \
  -v "$PWD/logs:/home/logs" \
  ghcr.io/suiyunsy/warpa:latest
```

If you want the container to generate the initial config for you, create the directories and omit the config bind mount for the first run:

```bash
mkdir -p auths logs
docker run --rm -it \
  -p 8317:8317 \
  -v "$PWD/auths:/home/auths" \
  -v "$PWD/logs:/home/logs" \
  ghcr.io/suiyunsy/warpa:latest
```

## Azure App Service

Use the GHCR image:

```text
ghcr.io/suiyunsy/warpa:latest
```

Recommended App Service environment variables:

```text
WEBSITES_PORT=8317
WEBSITES_ENABLE_APP_SERVICE_STORAGE=true
CPA_CONFIG=/home/config.yaml
CPA_PROXY_URL=http://127.0.0.1:9091
NET_PORT=9091
DEPLOY=cloud
```

For a single-container App Service deployment, the only required HTTP entry port is:

```text
WEBSITES_PORT=8317
```

Do not expose or route `9091` in production. The image is intended for “CPA internally goes through WARP”, not as a public WARP proxy service.

## Testing WARP locally

For a temporary local check only, you can publish or exec into an environment where `9091` is reachable and run:

```bash
curl -x "http://127.0.0.1:9091" https://www.cloudflare.com/cdn-cgi/trace
```

If WARP is active, the response includes:

```text
warp=on
```

Do not expose `9091` in production. If a future deployment needs WARP as a standalone HTTP/SOCKS proxy service, use a separate image/repository and add authentication plus IP allowlisting.

## GitHub Actions publishing

The workflow in `.github/workflows/build.yml` builds and publishes a multi-architecture image for `linux/amd64` and `linux/arm64` to GHCR when:

- code is pushed to `main`;
- the workflow is manually run from the Actions tab;
- the daily scheduled rebuild runs.

Published tags include:

```text
latest
sha-<commit>
YYYYMMDD-HHmm
```
