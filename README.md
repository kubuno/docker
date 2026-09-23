<!--
  SPDX-FileCopyrightText: 2026 Kubuno contributors
  SPDX-License-Identifier: AGPL-3.0-or-later
-->

<div align="center">

<img src=".github/logo.png" alt="Kubuno logo" width="120">

# Kubuno — Docker

[![License: AGPL v3](https://img.shields.io/badge/License-AGPL_v3-blue.svg)](https://github.com/kubuno/core/blob/main/LICENSE)
![Docker](https://img.shields.io/badge/Docker-all--in--one-2496ED.svg)
![Registry](https://img.shields.io/badge/ghcr.io-kubuno%2Fkubuno-4D38DB.svg)
![Status](https://img.shields.io/badge/status-alpha-yellow.svg)

**The all-in-one Docker image of [Kubuno](https://github.com/kubuno) — the self-hosted, libre (AGPLv3) cloud platform, a sovereign alternative to Google Workspace and Microsoft 365.**

One image with the core and every module, published to the GitHub Container Registry.

</div>

---

```
ghcr.io/kubuno/kubuno:<version>
ghcr.io/kubuno/kubuno:latest
```

## Why a single image

The Kubuno core is a **supervisor**: on startup it scans its module directory
(`/usr/lib/kubuno/modules/` in the image), launches each module binary as a child
process and injects its configuration (core URL, internal secret, database
credentials). The image therefore reproduces the native install layout and runs
`kubuno-core` — the supervisor starts the modules on its own. One image, one root
process, configuration entirely through environment variables.

The image aggregates the **core and 22 modules** (`kubuno/core`, `kubuno/drive`,
`kubuno/calendar`, …, `kubuno/stt`). Each component is built from the **git tag
pinned in [`VERSIONS`](VERSIONS)** — never from a moving branch — and the manifest is
copied into the image (`cat /etc/kubuno/VERSIONS`), so a running container always
says exactly which version of every component it contains.

## One-line install (Linux server)

Installs Docker if needed, fetches everything, generates the secrets and starts Kubuno:

```bash
curl -fsSL https://raw.githubusercontent.com/kubuno/docker/main/install.sh | sudo bash
# → http://<server-ip>:8080
#   The installer prints the administrator password it generated — there is no default one.
```

Pass options after `bash -s --` (reliable through `curl | bash`). Custom port:

```bash
curl -fsSL https://raw.githubusercontent.com/kubuno/docker/main/install.sh | sudo bash -s -- --port 9000
```

Automatic HTTPS (Let's Encrypt via Caddy) — just give a domain (ports 80/443 must be open, DNS pointing to the server):

```bash
curl -fsSL https://raw.githubusercontent.com/kubuno/docker/main/install.sh \
  | sudo bash -s -- --domain cloud.example.com --email you@example.com
# → https://cloud.example.com
```

Re-run the same command at any time to update (it pulls and restarts; secrets are kept).
Options: `--port`, `--domain`, `--email`, `--tag`, `--dir`, `--admin-user`, `--admin-password`,
`--admin-email` (`install.sh --help`).

## Quick start (manual, from the published image)

```bash
cp .env.docker.example .env     # fill in the secrets
KUBUNO_TAG=latest docker compose -f docker-compose.yml -f docker-compose.prod.yml pull
KUBUNO_TAG=latest docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d
# → http://localhost:8080
```

There is **no default administrator password**. Set `KUBUNO_ADMIN_PASSWORD`, or leave
it empty: the server then draws a random one, writes it to
`/var/lib/kubuno/initial-admin-password` (readable by the service account only) and
asks for a new one at first sign-in.

## Build it yourself

```bash
docker compose up --build -d                          # builds every module locally
docker build --build-arg MODULES="drive calendar" .   # a subset
```

Hosting a **public demo**? See **[DEMO.md](DEMO.md)** for a hardened, host-isolated
setup (rootless Docker, dropped capabilities, read-only root filesystem, loopback-only,
reverse proxy).

See **[DOCKER.md](DOCKER.md)** for the full guide (configuration, HTTPS, persistence,
disk requirements, choosing modules, publishing).

## Continuous delivery

`.github/workflows/build.yml` builds and pushes the image to GHCR:

- **on a `v*` tag** → publishes `:<version>` and `:latest`;
- **manually** (`workflow_dispatch`) → optional module subset, push on/off.

The workflow derives the module list from `VERSIONS` (the single source of truth),
clones every component **at its pinned tag**, builds them one by one (`cargo clean`
between each to bound disk usage) and pushes the image. `media` requires `ffmpeg`,
installed in the runtime image; `stt` has no user interface, which the assembly
handles.

To cut a release:

```bash
git tag -a v0.1.0 -m "kubuno image v0.1.0"
git push origin v0.1.0
```

## Layout

| Path | Purpose |
|------|---------|
| `Dockerfile` | All-in-one image (multi-stage, `ARG MODULES`) |
| `Dockerfile.local` | Runtime-only image from host-built binaries |
| `VERSIONS` | Component → pinned git tag (generated, never edited by hand) |
| `docker-compose.yml` | `postgres:16` + `kubuno` |
| `docker-compose.prod.yml` | Deploy from the published image (pull, no build) |
| `docker-compose.local.yml` | Use a locally pre-built image |
| `docker-compose.demo.yml` | Hardened public-demo deployment (see `DEMO.md`) |
| `install.sh` | One-line server installer |
| `_tools/docker/build.sh` | Shared, disk-bounded build script |
| `_tools/docker/publish.sh` | Manual build + tag + push |
| `sync.sh` | Refresh the tooling from a sibling workspace checkout |

## Security

Please report vulnerabilities privately — see [`SECURITY.md`](SECURITY.md).

## License

[AGPL-3.0-or-later](https://github.com/kubuno/core/blob/main/LICENSE) © Kubuno contributors, like the rest of Kubuno.
