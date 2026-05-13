# warpa

`warpa` 是一个面向 Azure App Service 单容器部署的 Docker 镜像：底层以 userspace Cloudflare WARP 代理为基础，主要服务是 CLIProxyAPI（下文简称 CPA）。容器内部启动 WARP 代理后，再启动 CPA Web 管理与 API 服务。

发布镜像：

```text
ghcr.io/suiyunsy/warpa:latest
```

## 工作方式

- CPA 对外提供 HTTP 服务，监听容器端口 `8317`。
- WARP 只在容器内部作为出站代理使用，默认端口为 `127.0.0.1:9091`。
- 不建议把 `9091` 暴露到公网；生产环境只需要让 Azure App Service 路由 `8317`。
- warpa 是“以 WARP 为基、以 CPA 为主”的部署方式：日常配置、渠道、鉴权和管理都应在 CPA 管理面板中完成。
- 优先建议在 CPA 的单独渠道里配置 SOCKS5 代理：`socks5://127.0.0.1:9091`。不建议在容器启动脚本中全局强制设置 HTTP/SOCKS 代理。

## 持久化路径

镜像按 Azure App Service 的持久化目录 `/home` 设计，warpa 自身数据统一放在 `/home/warpa`。`/CLIProxyAPI` 是镜像内置的 CPA 程序目录，只用于存放可执行文件和示例配置，不应作为持久化目录使用。

warpa 只使用以下持久化路径：

```text
/home/warpa/config.yaml  # CPA 配置文件
/home/warpa/auths        # CPA auth 文件目录
/home/warpa/logs         # CPA 日志目录
/home/warpa/static       # CPA management HTML 静态文件目录
```

首次启动时，如果 `/home/warpa/config.yaml` 不存在，入口脚本会从 `/CLIProxyAPI/config.example.yaml` 复制一份默认配置，并只调整以下必要项：

```yaml
auth-dir: "/home/warpa/auths"
logging-to-file: true
logs-max-total-size-mb: 10
```

`host`、`port` 等默认值保持 CPA 官方 `config.example.yaml` 的内容；入口脚本不会写入 `proxy-url`，也不会强制 CPA 全局走 WARP。

## Azure App Service 配置

在 Azure App Service 创建 Linux Web App，并选择自定义容器镜像：

```text
ghcr.io/suiyunsy/warpa:latest
```

应用设置（Environment variables）至少需要配置：

```text
MANAGEMENT_PASSWORD=<你的CPA管理密码>
WEBSITES_PORT=8317
```

建议同时启用 App Service 持久化存储：

```text
WEBSITES_ENABLE_APP_SERVICE_STORAGE=true
```

镜像内已保留以下默认环境变量，一般不需要在 Azure 中重复设置：

```text
TZ=Asia/Shanghai
DEPLOY=cloud
NET_PORT=9091
WARP_START_DELAY=8
```

部署完成后，进入 CPA 管理面板，在需要通过 WARP 出站的单独渠道里设置代理地址：

```text
socks5://127.0.0.1:9091
```

这样可以让指定渠道走 WARP，同时避免把所有 CPA 流量在启动阶段强制改为同一个代理。

## 端口与安全

- 对公网只暴露 `8317`。
- 不要公开、映射或反向代理 `9091`。
- `9091` 是容器内部 WARP 代理端口，供 CPA 渠道按需使用。
- 必须设置 `MANAGEMENT_PASSWORD`，避免 CPA 管理面板无密码暴露。

## GitHub Actions 构建发布

`.github/workflows/build.yml` 会构建并发布 `linux/amd64`、`linux/arm64` 多架构镜像到 GHCR。触发方式包括：

- 推送到 `main`；
- 在 GitHub Actions 页面手动触发；
- 每日定时构建：北京时间 00:00（UTC 16:00）。

发布标签包括：

```text
latest
sha-<commit>
YYYYMMDD-HHmm
```
