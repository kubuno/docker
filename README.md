# kubuno/docker

Docker packaging for **[Kubuno](https://github.com/kubuno)** — the self-hosted,
free (AGPLv3) cloud platform. This repository builds a single **all-in-one image**
(the core + every module) and publishes it to the GitHub Container Registry.

```
ghcr.io/kubuno/kubuno:<version>
ghcr.io/kubuno/kubuno:latest
```

## Why a single image

The Kubuno core is a **supervisor**: on startup it scans `/usr/lib/kubuno/modules/`,
launches each module binary as a child process and injects its configuration (core
URL, internal secret, database credentials). The image therefore just reproduces the
Debian install layout and runs `kubuno-core` — the supervisor starts the modules on
its own. One image, one root process, configuration entirely through environment
variables.

The image aggregates ~21 component repositories (`kubuno/core`, `kubuno/drive`,
`kubuno/calendar`, …). The build clones them on the fly, so this repository only
holds the Docker tooling.

## One-line install (Linux server)

Installs Docker if needed, fetches everything, generates secrets and starts Kubuno:

```bash
curl -fsSL https://raw.githubusercontent.com/kubuno/docker/main/install.sh | sudo bash
# → http://<server-ip>:8080   (default admin: admin / kubuno — change it!)
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

Re-run the same command anytime to update (it re-pulls and restarts; secrets are kept).
Options: `--port`, `--domain`, `--email`, `--tag`, `--dir`, `--admin-user/-password/-email`
(`install.sh --help`).

## Quick start (manual, from the published image)

```bash
cp .env.docker.example .env     # fill in the secrets
KUBUNO_TAG=latest docker compose -f docker-compose.yml -f docker-compose.prod.yml pull
KUBUNO_TAG=latest docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d
# → http://localhost:8080   (default admin: admin / kubuno — change it!)
```

## Build it yourself

```bash
docker compose up --build -d                          # builds all modules locally
docker build --build-arg MODULES="drive calendar" .   # a subset
```

See **[DOCKER.md](DOCKER.md)** for the full guide (configuration, HTTPS, persistence,
disk requirements, choosing modules, publishing).

## Continuous delivery

`.github/workflows/build.yml` builds and pushes the image to GHCR:

- **on a `v*` tag** → publishes `:<version>` and `:latest`;
- **manually** (`workflow_dispatch`) → optional module subset, push on/off.

To cut a release:

```bash
git tag -a v0.1.0 -m "kubuno image v0.1.0"
git push origin v0.1.0
```

The workflow clones every component repo (latest `main`), builds the image
component-by-component (`cargo clean` between each to bound disk usage), and pushes
it. `media` requires `ffmpeg`, which is installed in the runtime image.

## Layout

| Path | Purpose |
|------|---------|
| `Dockerfile` | All-in-one image (multi-stage, `ARG MODULES`) |
| `Dockerfile.local` | Runtime-only image from host-built binaries |
| `docker-compose.yml` | `postgres:16` + `kubuno` |
| `docker-compose.prod.yml` | Deploy from the published image (pull, no build) |
| `docker-compose.local.yml` | Use a locally pre-built image |
| `_tools/docker/build.sh` | Shared, disk-bounded build script |
| `_tools/docker/publish.sh` | Manual build + tag + push |
| `sync.sh` | Refresh the tooling from a sibling workspace checkout |

## License

AGPL-3.0, like the rest of Kubuno.
