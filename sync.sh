#!/usr/bin/env bash
# sync.sh — recopie l'outillage Docker depuis un workspace Kubuno voisin vers ce
# dépôt (source de vérité = la racine du workspace où vivent les dépôts côte à côte).
# Utile tant que les fichiers sont édités dans le workspace ; à terme, ce dépôt
# peut devenir l'unique source.
#
#   WORKSPACE=~/projects/kubuno bash sync.sh
set -euo pipefail
cd "$(dirname "$0")"
WS="${WORKSPACE:-..}"

for f in Dockerfile Dockerfile.local Dockerfile.local.dockerignore .dockerignore \
         docker-compose.yml docker-compose.prod.yml docker-compose.local.yml \
         .env.docker.example DOCKER.md; do
  cp "$WS/$f" "./$f"
done
mkdir -p _tools/docker
cp "$WS/_tools/docker/build.sh" "$WS/_tools/docker/publish.sh" _tools/docker/

echo "✓ Outillage synchronisé depuis $WS"
