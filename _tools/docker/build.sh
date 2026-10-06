#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# build.sh — compile le core + les modules listés et assemble le layout
# d'installation Kubuno dans $OUT (= rootfs prêt à copier dans une image).
#
# Conçu pour tourner DANS le builder Docker (SRC=/build, OUT=/out) ou sur
# l'HÔTE (SRC=$PWD, OUT=$PWD/_artifacts/docker-rootfs).
#
# Variables :
#   SRC      racine des dépôts (défaut: /build)
#   OUT      répertoire de sortie = rootfs (défaut: /out)
#   MODULES  liste séparée par des espaces (défaut: vide = core seul)
#   CLEAN    1 = `cargo clean` après chaque composant pour borner le pic disque
#            (indispensable sur petite partition). 0 = conserver les caches.
#
# Le layout produit est IDENTIQUE à celui des paquets .deb :
#   $OUT/usr/bin/{kubuno-core,kubuno}
#   $OUT/usr/share/kubuno/frontend/                     (frontend host)
#   $OUT/usr/lib/kubuno/modules/<id>/{kubuno-<id>,module.toml,frontend/}
#   $OUT/etc/kubuno/{config.toml.example,modules/<id>/config.toml}
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SRC="${SRC:-/build}"
OUT="${OUT:-/out}"
MODULES="${MODULES:-}"
CLEAN="${CLEAN:-1}"
export SQLX_OFFLINE=true   # drive/media embarquent un cache .sqlx ; inoffensif ailleurs

# Résilience réseau (flakes crates.io en CI : reset HTTP/2, downloads échoués).
export CARGO_NET_RETRY="${CARGO_NET_RETRY:-10}"
export CARGO_HTTP_MULTIPLEXING="${CARGO_HTTP_MULTIPLEXING:-false}"
export CARGO_NET_GIT_FETCH_WITH_CLI="${CARGO_NET_GIT_FETCH_WITH_CLI:-true}"

# Repository layouts (both accepted while the repositories move, 2026-10): the platform layout has the
# server in server/ (Cargo.toml, src/, migrations/, config.toml.example) and the frontend in web/; the older
# one has them at the root and in frontend/. module.toml stays at the root in both.
server_dir() {  # $1 = repository → its server folder
  if [ -f "$1/server/Cargo.toml" ]; then echo "$1/server"; else echo "$1"; fi
}
web_dir() {  # $1 = repository → its frontend folder (may not exist: a module without UI)
  if [ -f "$1/web/package.json" ]; then echo "$1/web"; else echo "$1/frontend"; fi
}

build_frontend() {  # $1 = répertoire frontend
  ( cd "$1" && { [ -f package-lock.json ] && npm ci || npm install; } && npm run build )
  # node_modules est volumineux et inutile une fois dist/ produit
  rm -rf "$1/node_modules"
}

maybe_clean() {  # $1 = répertoire cargo
  [ "$CLEAN" = "1" ] && ( cd "$1" && cargo clean ) || true
}

# ── core ─────────────────────────────────────────────────────────────────────
echo "==> core"
S="$(server_dir "$SRC/core")"; W="$(web_dir "$SRC/core")"
cd "$S"
cargo build --release --bin kubuno-core --bin kubuno
build_frontend "$W"
install -D -m755 target/release/kubuno-core "$OUT/usr/bin/kubuno-core"
install -D -m755 target/release/kubuno      "$OUT/usr/bin/kubuno"
mkdir -p "$OUT/usr/share/kubuno/frontend"
cp -r "$W/dist/." "$OUT/usr/share/kubuno/frontend/"
install -D -m644 config.toml.example "$OUT/etc/kubuno/config.toml.example"
maybe_clean "$S"

# ── modules ──────────────────────────────────────────────────────────────────
for m in $MODULES; do
  echo "==> module $m"
  S="$(server_dir "$SRC/$m")"; W="$(web_dir "$SRC/$m")"
  cd "$S"
  cargo build --release --bin "kubuno-$m"
  install -D -m755 "target/release/kubuno-$m" "$OUT/usr/lib/kubuno/modules/$m/kubuno-$m"
  install -D -m644 "$SRC/$m/module.toml"       "$OUT/usr/lib/kubuno/modules/$m/module.toml"
  # Tous les modules n'ont pas d'interface : stt est sans écran, et le script
  # échouait sur un `cd` vers un dossier frontend inexistant. Un module sans
  # interface est légitime, pas une erreur.
  if [ -d "$W" ]; then
    build_frontend "$W"
    mkdir -p "$OUT/usr/lib/kubuno/modules/$m/frontend"
    cp -r "$W/dist/." "$OUT/usr/lib/kubuno/modules/$m/frontend/"
  else
    echo "    (pas d'interface)"
  fi
  # config.toml du module (rôle du postinst .deb) : fixe ses chemins de stockage.
  # URL core / secret / DB restent surchargés par le superviseur (KUBUNO_*).
  [ -f config.toml.example ] && install -D -m644 config.toml.example "$OUT/etc/kubuno/modules/$m/config.toml"
  maybe_clean "$S"
done

echo "==> build terminé → $OUT"
