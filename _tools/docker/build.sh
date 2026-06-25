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
cd "$SRC/core"
cargo build --release --bin kubuno-core --bin kubuno
build_frontend "$SRC/core/frontend"
install -D -m755 target/release/kubuno-core "$OUT/usr/bin/kubuno-core"
install -D -m755 target/release/kubuno      "$OUT/usr/bin/kubuno"
mkdir -p "$OUT/usr/share/kubuno/frontend"
cp -r frontend/dist/. "$OUT/usr/share/kubuno/frontend/"
install -D -m644 config.toml.example "$OUT/etc/kubuno/config.toml.example"
maybe_clean "$SRC/core"

# ── modules ──────────────────────────────────────────────────────────────────
for m in $MODULES; do
  echo "==> module $m"
  cd "$SRC/$m"
  cargo build --release --bin "kubuno-$m"
  build_frontend "$SRC/$m/frontend"
  install -D -m755 "target/release/kubuno-$m" "$OUT/usr/lib/kubuno/modules/$m/kubuno-$m"
  install -D -m644 module.toml                 "$OUT/usr/lib/kubuno/modules/$m/module.toml"
  mkdir -p "$OUT/usr/lib/kubuno/modules/$m/frontend"
  cp -r frontend/dist/. "$OUT/usr/lib/kubuno/modules/$m/frontend/"
  # config.toml du module (rôle du postinst .deb) : fixe ses chemins de stockage.
  # URL core / secret / DB restent surchargés par le superviseur (KUBUNO_*).
  [ -f config.toml.example ] && install -D -m644 config.toml.example "$OUT/etc/kubuno/modules/$m/config.toml"
  maybe_clean "$SRC/$m"
done

echo "==> build terminé → $OUT"
