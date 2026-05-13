# warpa

`warpa` 是一个面向 Azure App Service 单容器部署的 Docker 镜像：**以用户态 Cloudflare WARP 为基础，以 CLIProxyAPI（CPA）为主服务**。

它在同一个容器内启动：

1. 用户态 WARP mixed proxy：仅监听容器内部 `127.0.0.1:9091` / `NET_PORT=9091`。
2. CLIProxyAPI：作为公网入口服务，监听 App Service 暴露的 `8317`。

最终镜像地址：

```text
ghcr.io/suiyunsy/warpa:latest
```

## 适用场景

Azure App Service 后续不再适合依赖 Docker Compose 多服务部署时，可以直接使用这个单镜像部署 CPA，并让需要走 WARP 的 CPA 渠道单独使用容器内的 WARP 代理。

这个镜像不是“公开 WARP 代理服务”，而是“CPA 内部按需走 WARP”。生产环境只应开放 CPA 的 `8317` 端口，不要开放 `9091`。

## Azure App Service 必填设置

在 Azure App Service 中使用单 Docker 镜像：

```text
ghcr.io/suiyunsy/warpa:latest
```

应用设置至少需要：

```text
MANAGEMENT_PASSWORD=请填写一个强密码
WEBSITES_PORT=8317
```

建议同时开启 App Service 持久化存储：

```text
WEBSITES_ENABLE_APP_SERVICE_STORAGE=true
```

镜像内已经默认设置：

```text
TZ=Asia/Shanghai
DEPLOY=cloud
NET_PORT=9091
WARP_START_DELAY=8
```

## 持久化路径

全新部署时，容器会使用 `/home/warpa` 作为持久化目录：

```text
/home/warpa/config.yaml  # CPA 配置文件
/home/warpa/auths        # CPA auth 文件
/home/warpa/logs         # CPA 日志文件
```

如果 `/home/warpa/config.yaml` 不存在，启动脚本会从 `/CLIProxyAPI/config.example.yaml` 生成一份，并只修改这些配置：

```yaml
auth-dir: "/home/warpa/auths"
logging-to-file: true
logs-max-total-size-mb: 10
```

启动脚本不会强制修改 `host`、`port`，也不会写入全局 `proxy-url`。

## WARP 代理使用方式

容器内 WARP mixed proxy 地址为：

```text
socks5://127.0.0.1:9091
```

优先建议使用 SOCKS5 代理。不要在 CPA 配置里设置全局代理；请进入 CPA 管理面板，在需要走 WARP 的单独渠道里设置代理：

```text
socks5://127.0.0.1:9091
```

这样可以避免所有渠道被强制走 WARP，也能更清楚地控制哪些渠道需要 WARP 出口。

## 端口说明

公网只暴露：

```text
8317
```

不要在生产环境暴露：

```text
9091
```

`9091` 只给同容器内的 CPA 访问。如果未来确实需要把 WARP 做成独立 HTTP/SOCKS 代理服务，应另开独立镜像/仓库，并且必须加认证和 IP 白名单。

## 权限说明

本镜像基于用户态 WARP 镜像：

```text
ghcr.io/mon-ius/docker-warp-socks:v5
```

不需要以下高权限或内核能力：

```text
privileged
NET_ADMIN
SYS_MODULE
/dev/net/tun
sysctls
```

## 自动构建

GitHub Actions 会在以下情况构建并发布多架构镜像到 GHCR：

- push 到 `main`；
- 在 Actions 页面手动 `Run workflow`；
- 每天北京时间 0 点自动重建一次。

发布架构：

```text
linux/amd64
linux/arm64
```

发布标签：

```text
latest
sha-<commit>
YYYYMMDD-HHmm
```
