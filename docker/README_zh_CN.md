# FlClash Docker 使用指南

[English](README.md)

Docker 镜像通过 [LinuxServer Webtop](https://docs.linuxserver.io/images/docker-webtop/)
在 XFCE 桌面中运行 Linux 版 FlClash，并将桌面渲染到浏览器中。它不是无界面的
Clash API 容器。

镜像发布在 `ghcr.io/pickrui/flclash`，支持 `linux/amd64` 和
`linux/arm64`。每个稳定版本会同时发布 `latest` 和不带前导 `v` 的版本标签，
例如 `0.8.93`。

## 运行要求

- Linux 宿主机和 Docker Engine，推荐使用 Docker Compose v2。
- 为浏览器桌面分配至少 1 GB 共享内存。
- 仅在使用 FlClash TUN 模式时需要 `/dev/net/tun` 和 `NET_ADMIN` 权限。

启用 TUN 前先检查宿主机：

```bash
test -c /dev/net/tun && echo "TUN is available"
```

普通 Linux 发行版缺少该设备时，可运行 `sudo modprobe tun` 加载模块。NAS
系统可能需要在管理界面中单独启用 TUN。

## 使用 Docker Compose

在仓库根目录运行：

```bash
docker compose -f docker/docker-compose.yml pull
docker compose -f docker/docker-compose.yml up -d
docker compose -f docker/docker-compose.yml logs -f
```

容器启动后访问 `https://<宿主机地址>:3001`。Webtop 默认使用自签名证书，
首次访问时出现浏览器证书警告属于正常现象。

端口 `3000` 提供纯 HTTP，适合在反向代理后使用。直接访问时应使用 `3001`
端口的 HTTPS，否则浏览器的音频、视频和剪贴板等功能可能无法正常工作。

## 使用 Docker CLI

```bash
docker run -d \
  --name flclash \
  --restart unless-stopped \
  -e PUID="$(id -u)" \
  -e PGID="$(id -g)" \
  -e TZ=Asia/Shanghai \
  -p 3000:3000 \
  -p 3001:3001 \
  --cap-add NET_ADMIN \
  --device /dev/net/tun:/dev/net/tun \
  -v flclash-config:/config \
  --shm-size 1g \
  ghcr.io/pickrui/flclash:latest
```

不使用 TUN 模式时，可以移除 `--cap-add NET_ADMIN` 和
`--device /dev/net/tun:/dev/net/tun`。

## 配置说明

| 配置 | 用途 |
| --- | --- |
| `PUID` / `PGID` | `/config` 文件所用的用户和组 ID，可通过 `id` 查询 |
| `TZ` | 容器时区，例如 `Asia/Shanghai` 或 `Etc/UTC` |
| `CUSTOM_USER` / `PASSWORD` | 可选的基础身份验证，仅适合可信局域网 |
| `3000/tcp` | Web 桌面的 HTTP 入口，应放在反向代理后使用 |
| `3001/tcp` | Web 桌面的 HTTPS 入口，默认使用自签名证书 |
| `/config` | 持久化 Webtop 用户目录和 FlClash 数据 |
| `/dev/net/tun` + `NET_ADMIN` | TUN 设备访问权限，不使用 TUN 时可移除 |
| `shm_size: 1gb` | 桌面会话所需的共享内存大小 |

仓库自带的 Compose 文件使用命名卷 `flclash-config`。如需将数据直接保存到
宿主机目录，可将卷映射替换为：

```yaml
volumes:
  - /absolute/path/to/flclash-config:/config
```

请确保该目录可由 `PUID` 和 `PGID` 对应的用户写入。

## 访问安全

Web 桌面默认没有身份验证，并且其中的终端可以在容器内免密码使用 `sudo`。
不要将 `3000` 或 `3001` 端口直接暴露到公网。

在可信局域网内使用时，可以将以下变量加入 Compose 服务并重建容器，从而启用
基础身份验证：

```yaml
environment:
  - CUSTOM_USER=flclash
  - PASSWORD=请替换为高强度密码
```

基础身份验证不足以保护公网入口。远程访问时，应仅将 Webtop 端口绑定到本机，
再通过带有 HTTPS 和可靠身份验证的反向代理提供服务：

```yaml
ports:
  - "127.0.0.1:3001:3001"
```

反向代理可以连接 `3001` 端口的 HTTPS 上游并允许其自签名证书，也可以连接
`3000` 端口的 HTTP 上游，但不得将该 HTTP 端口直接公开。

## 流量作用范围

FlClash 运行在容器网络命名空间中。启用系统代理或 TUN 模式只会影响容器桌面，
不会自动接管 Docker 宿主机或其他局域网设备的流量。

如需从容器外使用 FlClash 的代理监听端口，应先在 FlClash 中配置监听端口并允许
局域网访问，再通过 Docker 发布同一个端口。例如混合代理端口配置为 `7890` 时：

```yaml
ports:
  - "7890:7890"
```

请同时通过宿主机防火墙限制来源，切勿将无身份验证的代理端口暴露到公网。

## 更新镜像

重建容器时，`/config` 卷中的应用数据会保留。Compose 部署可通过以下命令更新：

```bash
docker compose -f docker/docker-compose.yml pull
docker compose -f docker/docker-compose.yml up -d
```

如需固定版本，将 Compose 文件中的镜像改为
`ghcr.io/pickrui/flclash:<版本号>`。版本标签不包含前导 `v`。

## 常见问题

首先检查容器状态和日志：

```bash
docker compose -f docker/docker-compose.yml ps
docker compose -f docker/docker-compose.yml logs --tail=200 flclash
```

- **浏览器无法连接：** 确认容器正在运行，并访问
  `https://<宿主机地址>:3001`。在可信局域网中可接受自签名证书警告。
- **TUN 模式提示权限或设备错误：** 确认 `/dev/net/tun` 存在，并同时配置
  `NET_ADMIN` 和设备映射。
- **桌面空白或应用立即退出：** 较旧的内核或 libseccomp 版本可能需要添加
  `security_opt: [seccomp:unconfined]`。该配置会关闭 Docker 的重要安全层，
  仅应在确认默认 seccomp 配置导致问题时使用。
- **无法写入 `/config`：** 将 `PUID` 和 `PGID` 设为宿主机目录所有者的
  ID，然后重建容器。
- **宿主机没有经过代理：** 发布 Webtop 端口只会提供远程桌面。需要按照“流量
  作用范围”一节显式发布已配置的代理监听端口。

## 本地构建

选择一个包含对应 Linux `.deb` 文件的 FlClash 版本，然后在仓库根目录运行：

```bash
docker buildx build --load \
  --platform linux/amd64 \
  --build-arg FLCLASH_VERSION=0.8.93 \
  -t flclash:local \
  docker
```

构建 ARM64 镜像时使用 `--platform linux/arm64`。BuildKit 会为 Dockerfile
提供对应的 `TARGETARCH` 值。