# warpa

`warpa` 是面向 Azure App Service 单容器部署的镜像，在一个非特权容器中同时运行：

- CLIProxyAPI（CPA），对外提供管理页面和 API；
- sing-box 用户态 Cloudflare WARP，只在容器内部提供 SOCKS5 代理；
- CPA 原生动态库插件。

发布镜像：

```text
ghcr.io/suiyunsy/warpa:latest
```

## 架构

最终运行层直接使用 CPA 官方 `eceasy/cli-proxy-api:latest` 镜像，因此 CPA 和插件共享 Debian/glibc 运行环境。sing-box 固定为经过 SHA256 校验的 glibc 版本，不继承 Alpine/musl，也不需要 `gcompat`、TUN、`NET_ADMIN` 或特权容器。

CPA 对外监听 `8317`。WARP 的 mixed/SOCKS 入站只监听：

```text
127.0.0.1:9091
```

在需要通过 WARP 出站的 CPA 渠道或认证项中配置：

```text
socks5h://127.0.0.1:9091
```

不要把 `9091` 暴露到公网，也不建议通过环境变量强制 CPA 全局走 WARP。

CPA 是容器主服务。WARP 异常退出时，入口脚本会保留 CPA 并以指数退避方式单独重启 WARP；只有 CPA 自身退出时容器才会退出。这可以避免临时 WARP 故障触发 Azure 502 和容器重启循环。

## 持久化路径

所有运行数据都位于 Azure App Service 可持久化的 `/home` 下：

```text
/home/warpa/config.yaml              # CPA 配置
/home/warpa/auths                    # CPA 认证文件
/home/warpa/data                     # CPA/插件数据
/home/warpa/logs                     # CPA 日志
/home/warpa/plugins                  # CPA 动态库插件
/home/warpa/static                   # Management Center 静态文件
/home/warpa/warp/credentials.json    # WARP 身份和私钥
/home/warpa/warp/config.json         # 生成的 sing-box 配置
/home/warpa/warp/cache.db            # sing-box DNS 缓存
```

首次启动会注册一个 WARP 身份并以 `0600` 权限保存，后续容器重启直接复用，不会每次重新注册。如确实需要更换身份，可临时设置：

```text
WARP_RESET_CREDENTIALS=1
```

成功生成新身份后应立即删除该设置，否则每次启动都会重置。

首次启动时，如果 `/home/warpa/config.yaml` 不存在，镜像会复制 CPA 官方示例配置，并设置：

```yaml
auth-dir: "/home/warpa/auths"
logging-to-file: true
logs-max-total-size-mb: 10
```

CPA 默认插件目录 `plugins` 相对于工作目录 `/home/warpa`，因此管理中心安装的插件会持久化到 `/home/warpa/plugins`。

CAP Token Usage Tracker 建议配置：

```yaml
plugins:
  enabled: true
  dir: "/home/warpa/plugins"
  configs:
    cap-token-usage-tracker:
      enabled: true
      priority: 0
      data_path: "/home/warpa/data/token-usage-tracker.db"
      retention_days: 30
      flush_interval: 5s
      flush_max_records: 100
      sync_on_record: true
```

## Azure App Service 配置

使用 Linux 自定义容器，并设置镜像：

```text
ghcr.io/suiyunsy/warpa:latest
```

应用设置至少包括：

```text
MANAGEMENT_PASSWORD=<CPA管理密码>
WEBSITES_PORT=8317
WEBSITES_ENABLE_APP_SERVICE_STORAGE=true
WEBSITES_CONTAINER_START_TIME_LIMIT=1800
```

镜像自带的默认环境变量：

```text
TZ=Asia/Shanghai
DEPLOY=cloud
NET_PORT=9091
WARP_RESTART_DELAY=10
WARP_RESTART_MAX_DELAY=300
WARP_RESTART_STABLE_TIME=60
```

`WARP_SERVER` 和 `WARP_PORT` 可覆盖 Cloudflare endpoint，通常不需要修改。

WARP 重启退避期间入口脚本仍会每两秒检查 CPA；CPA 退出后容器会及时退出。WARP 连续稳定运行 `WARP_RESTART_STABLE_TIME` 秒后，退避时间会恢复为初始值。

## 更新策略

- 推送和手动触发始终构建；每天北京时间 00:00 检查一次 CPA；
- 定时检查只有在 CPA 镜像 digest 或 warpa 提交变化时才构建，否则直接跳过；
- 构建开始时解析 `eceasy/cli-proxy-api:latest` 对应的 CPA 版本和 digest，并按 digest 固定本次构建，避免构建过程中上游标签漂移；
- sing-box 固定为 `v1.13.13` 并校验 amd64/arm64 SHA256；
- 发布 `latest`、`cpa-v<CPA版本>`、`sha-<commit>`、组合状态标签、Action run 标签和 UTC 时间戳标签。

例如 CPA `v7.2.83` 会生成 `cpa-v7.2.83`；组合标签形如 `sha-b17c45e-cpa-v7.2.83-2d402a3edfbf`。Azure 使用 `latest` 可以在重新拉取镜像时获得最新 CPA。需要严格回滚时，优先使用不会重复的 `run-<Action run ID>` 标签。

## 本地验证

构建：

```sh
docker build -t warpa:test .
```

运行并持久化 `/home`：

```sh
docker run --rm \
  -p 8317:8317 \
  -e MANAGEMENT_PASSWORD=change-me \
  -v warpa-home:/home \
  warpa:test
```

检查 CPA：

```sh
curl -fsS http://127.0.0.1:8317/
```

检查容器内 WARP：

```sh
docker exec <container> \
  curl --proxy socks5h://127.0.0.1:9091 \
  -fsSL https://www.cloudflare.com/cdn-cgi/trace
```

输出中应包含：

```text
warp=on
```
