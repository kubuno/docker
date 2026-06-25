# syntax=docker/dockerfile:1
# ─────────────────────────────────────────────────────────────────────────────
# Kubuno — image « tout-en-un » (core + tous les modules) pour self-hosting.
#
# Le core est un superviseur : au démarrage il scanne /usr/lib/kubuno/modules/,
# lance chaque binaire module en processus enfant et lui injecte sa config
# (URL du core, internal_secret, identifiants DB). Cette image reproduit donc le
# layout d'installation .deb, puis lance `kubuno-core` ; le superviseur démarre
# les modules tout seul.
#
# La liste des modules est pilotée par l'ARG MODULES (cf. _tools/docker/build.sh,
# qui compile composant par composant avec `cargo clean` pour borner le disque).
#
#   docker compose up --build
#   # ou un sous-ensemble :
#   docker build --build-arg MODULES="drive calendar notes" -t kubuno .
#
# ⚠️ Build complet gourmand : prévoir ~10 Go libres sur la partition Docker.
# ─────────────────────────────────────────────────────────────────────────────

# Liste par défaut = tous les modules (ARG global, partagé par les deux stages).
ARG MODULES="app books calendar chat code contacts drive flow forms forum jarvis keestore mail maps media notes office paintsharp photos tasks wiki"

# ── Stage 1 : compilation (Rust + Node) ──────────────────────────────────────
# buildpack-deps (base de l'image rust) fournit déjà git, curl, pkg-config et
# libssl-dev — nécessaires pour les crates -sys (reqwest/native-tls, etc.).
FROM rust:1-bookworm AS builder
ARG MODULES

# Node 22 (Vite 8 / rolldown exige Node >= 20.19).
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build
COPY . /build/
RUN MODULES="${MODULES}" SRC=/build OUT=/out CLEAN=1 bash _tools/docker/build.sh


# ── Stage 2 : runtime minimal ────────────────────────────────────────────────
FROM debian:bookworm-slim AS runtime
ARG MODULES

# libssl3 : reqwest/native-tls · curl : healthcheck · ffmpeg : transcodage media.
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates libssl3 curl ffmpeg \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --system --no-create-home --shell /usr/sbin/nologin kubuno

# Rootfs assemblé par le builder (binaires + frontends + configs).
COPY --from=builder /out/ /

# Répertoires runtime : données host + un dossier data/temp/config par module.
RUN set -eux; \
    mkdir -p /var/lib/kubuno/files /var/lib/kubuno/themes /var/log/kubuno; \
    for m in ${MODULES}; do \
      mkdir -p "/var/lib/kubuno/modules/$m/data" "/var/lib/kubuno/modules/$m/temp" "/etc/kubuno/modules/$m"; \
    done; \
    chown -R kubuno:kubuno /var/lib/kubuno /var/log/kubuno

ENV KV__SERVER__HOST=0.0.0.0 \
    KV__SERVER__PORT=8080 \
    KV__SERVER__FRONTEND_DIST=/usr/share/kubuno/frontend \
    KV__SERVER__MODULES_DIR=/usr/lib/kubuno/modules \
    KV__STORAGE__BACKEND=local \
    KV__STORAGE__LOCAL_PATH=/var/lib/kubuno/files \
    KV__DATABASE__RUN_MIGRATIONS=true \
    KV__LOGGING__FILE_ENABLED=false \
    KV__LOGGING__FORMAT=json

EXPOSE 8080
USER kubuno
WORKDIR /var/lib/kubuno

HEALTHCHECK --interval=15s --timeout=5s --start-period=40s --retries=6 \
    CMD curl -fsS http://localhost:8080/health || exit 1

ENTRYPOINT ["/usr/bin/kubuno-core"]
