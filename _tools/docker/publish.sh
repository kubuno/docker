#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# publish.sh — construit l'image Kubuno tout-en-un et la pousse vers un registre.
#
# ⚠️ Le `docker push` est une action SORTANTE → à lancer par l'UTILISATEUR
#    (préfixe `!` dans Claude), jamais par l'agent.
#
# Pré-requis : être authentifié au registre, p.ex. GHCR :
#    echo "$GHCR_TOKEN" | docker login ghcr.io -u kubuno-dev --password-stdin
#    (token = PAT avec scope write:packages, ou `gh auth token` s'il l'a)
#
# Variables (toutes optionnelles) :
#    REGISTRY   défaut ghcr.io
#    NAMESPACE  défaut kubuno            (org GitHub → ghcr.io/kubuno/…)
#    IMAGE      défaut kubuno
#    VERSION    défaut = version de core/Cargo.toml (ex: 0.1.0-alpha)
#    MODULES    défaut = tous (laisser vide pour reprendre le défaut du Dockerfile)
#    DOCKER     défaut "docker"          (mettre "sudo docker" si pas dans le groupe docker)
#    PUSH       défaut 1                 (0 = build + tag seulement, pas de push)
#
# Exemples :
#    bash _tools/docker/publish.sh
#    VERSION=0.1.0 MODULES="drive calendar notes mail photos" bash _tools/docker/publish.sh
#    DOCKER="sudo docker" bash _tools/docker/publish.sh
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail
cd "$(dirname "$0")/../.."   # racine du workspace

REGISTRY="${REGISTRY:-ghcr.io}"
NAMESPACE="${NAMESPACE:-kubuno}"
IMAGE="${IMAGE:-kubuno}"
VERSION="${VERSION:-$(grep -m1 '^version' core/Cargo.toml | sed -E 's/.*"([^"]+)".*/\1/')}"
DOCKER="${DOCKER:-docker}"
PUSH="${PUSH:-1}"

REF="${REGISTRY}/${NAMESPACE}/${IMAGE}"
echo "==> Image : ${REF}:${VERSION}  (+ :latest)"

# ARG MODULES : ne le passer que s'il est explicitement défini (sinon défaut Dockerfile = tous).
BUILD_ARGS=()
[ -n "${MODULES:-}" ] && BUILD_ARGS+=(--build-arg "MODULES=${MODULES}")

echo "==> Build…"
$DOCKER build "${BUILD_ARGS[@]}" -t "${REF}:${VERSION}" -t "${REF}:latest" .

if [ "$PUSH" = "1" ]; then
  echo "==> Push…"
  $DOCKER push "${REF}:${VERSION}"
  $DOCKER push "${REF}:latest"
  echo "✓ Publié : ${REF}:${VERSION} et ${REF}:latest"
  echo "  Déploiement : KUBUNO_TAG=${VERSION} docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d"
else
  echo "✓ Build + tag faits (PUSH=0). Pour pousser :"
  echo "    $DOCKER push ${REF}:${VERSION} && $DOCKER push ${REF}:latest"
fi
