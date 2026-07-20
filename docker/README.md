# FlClash Docker Guide

[简体中文](README_zh_CN.md)

The Docker image runs the Linux version of FlClash in an XFCE desktop provided
by [LinuxServer Webtop](https://docs.linuxserver.io/images/docker-webtop/). The
desktop is rendered in a browser; this is not a headless Clash API container.

Images are published for `linux/amd64` and `linux/arm64` at
`ghcr.io/pickrui/flclash`. Each stable release publishes both `latest` and a
version tag without the leading `v`, such as `0.8.93`.

## Requirements

- A Linux host with Docker Engine. Docker Compose v2 is recommended.
- At least 1 GB of shared memory for the browser desktop.
- `/dev/net/tun` and the `NET_ADMIN` capability only when FlClash TUN mode is
  required.

Check TUN support on the host before enabling it:

```bash
test -c /dev/net/tun && echo "TUN is available"
```

If the device is missing on a regular Linux distribution, load the module with
`sudo modprobe tun`. NAS systems may require TUN to be enabled in their own
administration interface.

## Quick Start With Docker Compose

Run the following commands from the repository root:

```bash
docker compose -f docker/docker-compose.yml pull
docker compose -f docker/docker-compose.yml up -d
docker compose -f docker/docker-compose.yml logs -f
```

Open `https://<host>:3001` after the container has started. Webtop uses a
self-signed certificate by default, so a browser certificate warning is
expected on first access.

Port `3000` provides plain HTTP and is intended for use behind a reverse proxy.
Use HTTPS on port `3001` for direct access because browser audio, video, and
clipboard features may not work over an insecure connection.

## Quick Start With Docker CLI

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

Remove `--cap-add NET_ADMIN` and `--device /dev/net/tun:/dev/net/tun` when TUN
mode is not needed.

## Configuration

| Option | Purpose |
| --- | --- |
| `PUID` / `PGID` | User and group IDs used for files under `/config`; obtain them with `id` |
| `TZ` | Container time zone, for example `Asia/Shanghai` or `Etc/UTC` |
| `CUSTOM_USER` / `PASSWORD` | Optional basic authentication for trusted local networks |
| `3000/tcp` | Web desktop over HTTP; use behind a reverse proxy |
| `3001/tcp` | Web desktop over HTTPS with a self-signed certificate |
| `/config` | Persistent Webtop home directory and FlClash data |
| `/dev/net/tun` + `NET_ADMIN` | TUN device access; optional when TUN mode is unused |
| `shm_size: 1gb` | Shared memory recommended for the desktop session |

The supplied Compose file uses the named volume `flclash-config`. To use a host
directory instead, replace its volume mapping with:

```yaml
volumes:
  - /absolute/path/to/flclash-config:/config
```

Ensure that the directory is writable by the configured `PUID` and `PGID`.

## Access Security

The web desktop has no authentication by default, and its terminal provides
passwordless `sudo` inside the container. Do not publish ports `3000` or `3001`
directly to the Internet.

For access on a trusted local network, basic authentication can be enabled by
adding these variables to the Compose service and recreating the container:

```yaml
environment:
  - CUSTOM_USER=flclash
  - PASSWORD=replace-with-a-strong-password
```

Basic authentication is not sufficient for public exposure. For remote access,
bind the Webtop port to the loopback interface and place it behind a reverse
proxy with HTTPS and robust authentication:

```yaml
ports:
  - "127.0.0.1:3001:3001"
```

The reverse proxy must connect to the HTTPS upstream on port `3001` and allow
its self-signed certificate, or connect to the HTTP upstream on port `3000`
without exposing that port publicly.

## Traffic Scope

FlClash runs inside the container. Enabling system proxy or TUN mode affects the
container desktop; it does not automatically route traffic from the Docker host
or other LAN devices.

To use a FlClash proxy listener from outside the container, first configure the
listener and LAN access in FlClash, then publish the same configured port in
Docker. For example, if the configured mixed proxy port is `7890`:

```yaml
ports:
  - "7890:7890"
```

Restrict that port with host firewall rules and never expose an unauthenticated
proxy listener to the public Internet.

## Updating

The `/config` volume keeps application data when the container is recreated.
Update a Compose deployment with:

```bash
docker compose -f docker/docker-compose.yml pull
docker compose -f docker/docker-compose.yml up -d
```

Use `ghcr.io/pickrui/flclash:<version>` instead of `latest` in the Compose file
to pin a release. Version tags do not include the leading `v`.

## Troubleshooting

Inspect container status and logs first:

```bash
docker compose -f docker/docker-compose.yml ps
docker compose -f docker/docker-compose.yml logs --tail=200 flclash
```

- **The browser cannot connect:** confirm that the container is running and use
  `https://<host>:3001`. Accept the self-signed certificate warning for trusted
  local access.
- **TUN mode reports a permission or device error:** verify that
  `/dev/net/tun` exists and that both `NET_ADMIN` and the device mapping are
  present.
- **The desktop is blank or an application exits immediately:** older kernels
  or libseccomp versions may require `security_opt: [seccomp:unconfined]`. This
  disables an important Docker security layer, so use it only when the default
  profile is confirmed to be the cause.
- **Files under `/config` are not writable:** set `PUID` and `PGID` to the owner
  of the host directory, then recreate the container.
- **The host is not using the proxy:** publishing the Webtop ports only exposes
  the remote desktop. Follow the traffic scope section to publish a configured
  proxy listener explicitly.

## Building Locally

Choose a FlClash release that contains the matching Linux `.deb` asset, then run
from the repository root:

```bash
docker buildx build --load \
  --platform linux/amd64 \
  --build-arg FLCLASH_VERSION=0.8.93 \
  -t flclash:local \
  docker
```

Use `--platform linux/arm64` for an ARM64 image. BuildKit supplies the matching
`TARGETARCH` value used by the Dockerfile.