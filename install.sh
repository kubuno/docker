#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Kubuno — installateur tout-en-un pour un serveur Linux (Docker).
#
# Installe Docker au besoin, récupère les fichiers de déploiement, génère les
# secrets, tire l'image publique ghcr.io/kubuno/kubuno et démarre la stack.
# Idempotent : relancer met à jour (re-pull + up) sans toucher aux secrets.
#
# Usage rapide :
#   curl -fsSL https://raw.githubusercontent.com/kubuno/docker/main/install.sh | sudo bash
#
# Avec HTTPS automatique (Let's Encrypt via Caddy) :
#   curl -fsSL https://raw.githubusercontent.com/kubuno/docker/main/install.sh \
#     | sudo DOMAIN=cloud.mondomaine.fr ACME_EMAIL=moi@mondomaine.fr bash
#
# Variables (toutes optionnelles) :
#   INSTALL_DIR  répertoire d'install        (défaut /opt/kubuno)
#   KUBUNO_TAG   tag d'image                 (défaut latest ; ex 0.1.2)
#   KUBUNO_PORT  port HTTP exposé            (défaut 8080 ; ignoré si DOMAIN)
#   DOMAIN       domaine → HTTPS auto (Caddy)
#   ACME_EMAIL   e-mail Let's Encrypt        (recommandé avec DOMAIN)
#   ADMIN_USER / ADMIN_PASSWORD / ADMIN_EMAIL  admin initial (sinon admin/kubuno)
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

REPO_TARBALL="${KUBUNO_REPO_TARBALL:-https://github.com/kubuno/docker/archive/refs/heads/main.tar.gz}"
INSTALL_DIR="${INSTALL_DIR:-/opt/kubuno}"
KUBUNO_TAG="${KUBUNO_TAG:-latest}"
KUBUNO_PORT="${KUBUNO_PORT:-8080}"
DOMAIN="${DOMAIN:-}"
ACME_EMAIL="${ACME_EMAIL:-}"
IMAGE="${KUBUNO_IMAGE:-ghcr.io/kubuno/kubuno}"

log() { printf '\033[1;35m▸ %s\033[0m\n' "$*"; }
err() { printf '\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

SUDO=""; [ "$(id -u)" -ne 0 ] && SUDO="sudo"

# Petit générateur de secret portable (openssl sinon /dev/urandom).
rand() { # $1 = -hex|-base64, $2 = nb octets
  if command -v openssl >/dev/null 2>&1; then openssl rand "$1" "$2"
  elif [ "$1" = "-hex" ]; then head -c "$2" /dev/urandom | od -An -tx1 | tr -d ' \n'
  else head -c "$2" /dev/urandom | base64 | tr -d '\n'; fi
}

# ── 1. Docker ────────────────────────────────────────────────────────────────
if ! command -v docker >/dev/null 2>&1; then
  log "Installation de Docker…"
  curl -fsSL https://get.docker.com | $SUDO sh
fi
$SUDO docker compose version >/dev/null 2>&1 || err "Le plugin 'docker compose' (v2) est requis."

# ── 2. Fichiers de déploiement ───────────────────────────────────────────────
log "Déploiement dans $INSTALL_DIR"
$SUDO mkdir -p "$INSTALL_DIR"
log "Téléchargement des fichiers (kubuno/docker)…"
curl -fsSL "$REPO_TARBALL" | $SUDO tar xz --strip-components=1 -C "$INSTALL_DIR"
cd "$INSTALL_DIR"

# ── 3. .env (généré une seule fois ; secrets préservés ensuite) ───────────────
if [ ! -f .env ]; then
  log "Génération de .env (secrets aléatoires)"
  PORT_BIND="${KUBUNO_PORT}"; [ -n "$DOMAIN" ] && PORT_BIND="127.0.0.1:${KUBUNO_PORT}"
  {
    echo "POSTGRES_USER=kubuno"
    echo "POSTGRES_PASSWORD=$(rand -hex 16)"
    echo "POSTGRES_DB=kubuno"
    echo "KUBUNO_JWT_SECRET=$(rand -base64 48)"
    echo "KUBUNO_INTERNAL_SECRET=$(rand -hex 32)"
    echo "KUBUNO_TAG=${KUBUNO_TAG}"
    echo "KUBUNO_PORT=${PORT_BIND}"
    [ -n "$DOMAIN" ] && echo "DOMAIN=${DOMAIN}"
    [ -n "${ADMIN_USER:-}" ]     && echo "KUBUNO_ADMIN_USER=${ADMIN_USER}"
    [ -n "${ADMIN_PASSWORD:-}" ] && echo "KUBUNO_ADMIN_PASSWORD=${ADMIN_PASSWORD}"
    [ -n "${ADMIN_EMAIL:-}" ]    && echo "KUBUNO_ADMIN_EMAIL=${ADMIN_EMAIL}"
  } | $SUDO tee .env >/dev/null
  $SUDO chmod 600 .env
else
  log ".env existant conservé (secrets inchangés)"
fi

# DOMAIN effectif (argument, sinon valeur du .env)
[ -z "$DOMAIN" ] && DOMAIN="$(grep -E '^DOMAIN=' .env 2>/dev/null | cut -d= -f2- || true)"

# ── 4. Fichiers compose à utiliser ───────────────────────────────────────────
FILES=(-f docker-compose.yml -f docker-compose.prod.yml)

# ── 5. HTTPS optionnel via Caddy ─────────────────────────────────────────────
if [ -n "$DOMAIN" ]; then
  log "HTTPS automatique (Caddy) pour ${DOMAIN}"
  {
    [ -n "$ACME_EMAIL" ] && printf '{\n\temail %s\n}\n\n' "$ACME_EMAIL"
    printf '%s {\n\treverse_proxy kubuno:8080\n}\n' "$DOMAIN"
  } | $SUDO tee Caddyfile >/dev/null
  $SUDO tee docker-compose.caddy.yml >/dev/null <<'YAML'
services:
  kubuno:
    environment:
      KV__SERVER__SECURE_COOKIES: "true"
  caddy:
    image: caddy:2
    restart: unless-stopped
    depends_on: [kubuno]
    ports: ["80:80", "443:443"]
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy-data:/data
      - caddy-config:/config
volumes:
  caddy-data:
  caddy-config:
YAML
  FILES+=(-f docker-compose.caddy.yml)
fi

# ── 6. Déploiement ───────────────────────────────────────────────────────────
log "Pull de ${IMAGE}:${KUBUNO_TAG}…"
$SUDO docker compose "${FILES[@]}" pull
log "Démarrage de la stack…"
$SUDO docker compose "${FILES[@]}" up -d

# ── 7. Résumé ────────────────────────────────────────────────────────────────
echo
log "Kubuno est démarré 🎉"
if [ -n "$DOMAIN" ]; then
  echo "  URL     : https://${DOMAIN}  (certificat TLS automatique sous ~1 min)"
else
  IP="$(hostname -I 2>/dev/null | awk '{print $1}')"; [ -z "$IP" ] && IP="<ip-serveur>"
  echo "  URL     : http://${IP}:${KUBUNO_PORT}"
fi
echo "  Admin   : ${ADMIN_USER:-admin} / ${ADMIN_PASSWORD:-kubuno}   (à changer dès la 1re connexion)"
echo "  Dossier : ${INSTALL_DIR}   (config : ${INSTALL_DIR}/.env)"
echo "  Logs    : cd ${INSTALL_DIR} && docker compose ${FILES[*]} logs -f"
echo "  Arrêt   : cd ${INSTALL_DIR} && docker compose ${FILES[*]} down"
