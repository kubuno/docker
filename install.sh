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
# Avec options (passer les arguments APRÈS `bash -s --`, fiable via curl|bash) :
#   curl -fsSL .../install.sh | sudo bash -s -- --port 9000
#   curl -fsSL .../install.sh | sudo bash -s -- --domain cloud.exemple.fr --email moi@exemple.fr
#
# Options :
#   --port <p>            port HTTP exposé           (défaut 8080 ; ignoré si --domain)
#   --domain <d>          domaine → HTTPS auto (Caddy, Let's Encrypt)
#   --email <e>           e-mail Let's Encrypt       (recommandé avec --domain)
#   --tag <t>             tag d'image                (défaut latest ; ex 0.1.2)
#   --dir <path>          répertoire d'install       (défaut /opt/kubuno)
#   --admin-user <u>      identifiant admin initial  (défaut admin)
#   --admin-password <p>  mot de passe admin initial (défaut kubuno)
#   --admin-email <e>     e-mail admin initial
#   --no-auto-update      ne pas installer le cron de mise à jour quotidienne
#   --uninstall           désinstalle tout (conteneurs + volumes + images + cron + dossier)
# (Les variables d'environnement de mêmes noms — KUBUNO_PORT, DOMAIN, … — restent
#  acceptées en repli.)
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# Valeurs par défaut (surchargées par les options CLI ci-dessous).
REPO_TARBALL="${KUBUNO_REPO_TARBALL:-https://github.com/kubuno/docker/archive/refs/heads/main.tar.gz}"
IMAGE="${KUBUNO_IMAGE:-ghcr.io/kubuno/kubuno}"
INSTALL_DIR="${INSTALL_DIR:-/opt/kubuno}"
KUBUNO_TAG="${KUBUNO_TAG:-latest}"
KUBUNO_PORT="${KUBUNO_PORT:-8080}"
DOMAIN="${DOMAIN:-}"
ACME_EMAIL="${ACME_EMAIL:-}"
ADMIN_USER="${ADMIN_USER:-}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"
ADMIN_EMAIL="${ADMIN_EMAIL:-}"
AUTO_UPDATE="${AUTO_UPDATE:-1}"
UNINSTALL=0
PORT_SET=""; TAG_SET=""

usage() { sed -n '2,33p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

# ── Parsing des options ──────────────────────────────────────────────────────
while [ $# -gt 0 ]; do
  case "$1" in
    --port)           KUBUNO_PORT="${2:?--port requiert une valeur}"; PORT_SET=1; shift 2;;
    --domain)         DOMAIN="${2:?--domain requiert une valeur}"; shift 2;;
    --email)          ACME_EMAIL="${2:?--email requiert une valeur}"; shift 2;;
    --tag)            KUBUNO_TAG="${2:?--tag requiert une valeur}"; TAG_SET=1; shift 2;;
    --dir)            INSTALL_DIR="${2:?--dir requiert une valeur}"; shift 2;;
    --admin-user)     ADMIN_USER="${2:?}"; shift 2;;
    --admin-password) ADMIN_PASSWORD="${2:?}"; shift 2;;
    --admin-email)    ADMIN_EMAIL="${2:?}"; shift 2;;
    --no-auto-update) AUTO_UPDATE=0; shift;;
    --uninstall)      UNINSTALL=1; shift;;
    -h|--help)        usage 0;;
    *) printf 'Option inconnue : %s\n\n' "$1" >&2; usage 1;;
  esac
done

log() { printf '\033[1;35m▸ %s\033[0m\n' "$*"; }
err() { printf '\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
SUDO=""; [ "$(id -u)" -ne 0 ] && SUDO="sudo"

# ── Désinstallation complète ─────────────────────────────────────────────────
if [ "$UNINSTALL" = 1 ]; then
  log "Désinstallation de Kubuno…"
  if [ -x "$INSTALL_DIR/compose.sh" ]; then
    "$INSTALL_DIR/compose.sh" down -v --rmi all --remove-orphans 2>/dev/null || true
  elif [ -d "$INSTALL_DIR" ]; then
    ( cd "$INSTALL_DIR" && $SUDO docker compose -f docker-compose.yml -f docker-compose.prod.yml \
        down -v --rmi all --remove-orphans 2>/dev/null ) || true
  fi
  $SUDO docker image rm -f "${IMAGE}:${KUBUNO_TAG}" "${IMAGE}:latest" 2>/dev/null || true
  $SUDO rm -f /etc/cron.d/kubuno-update
  $SUDO rm -rf "$INSTALL_DIR"
  log "Désinstallé : conteneurs, volumes et images supprimés, ${INSTALL_DIR} retiré."
  log "(Le moteur Docker système n'est pas touché.)"
  exit 0
fi

# Générateur de secret portable (openssl sinon /dev/urandom).
rand() { # $1 = -hex|-base64, $2 = nb octets
  if command -v openssl >/dev/null 2>&1; then openssl rand "$1" "$2"
  elif [ "$1" = "-hex" ]; then head -c "$2" /dev/urandom | od -An -tx1 | tr -d ' \n'
  else head -c "$2" /dev/urandom | base64 | tr -d '\n'; fi
}

# Insère ou remplace une clé KEY=VALUE dans .env.
upsert_env() {
  if grep -qE "^$1=" .env 2>/dev/null; then
    $SUDO sed -i "s|^$1=.*|$1=$2|" .env
  else
    printf '%s=%s\n' "$1" "$2" | $SUDO tee -a .env >/dev/null
  fi
}

# Valeur de KUBUNO_PORT (avec liaison 127.0.0.1 quand un domaine/HTTPS est utilisé).
port_bind() { if [ -n "$DOMAIN" ]; then echo "127.0.0.1:${KUBUNO_PORT}"; else echo "${KUBUNO_PORT}"; fi; }

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

# ── 3. .env (créé une fois ; secrets préservés ensuite) ───────────────────────
if [ ! -f .env ]; then
  log "Génération de .env (secrets aléatoires)"
  {
    echo "POSTGRES_USER=kubuno"
    echo "POSTGRES_PASSWORD=$(rand -hex 16)"
    echo "POSTGRES_DB=kubuno"
    echo "KUBUNO_JWT_SECRET=$(rand -base64 48)"
    echo "KUBUNO_INTERNAL_SECRET=$(rand -hex 32)"
    echo "KUBUNO_TAG=${KUBUNO_TAG}"
    echo "KUBUNO_PORT=$(port_bind)"
    [ -n "$DOMAIN" ]         && echo "DOMAIN=${DOMAIN}"
    [ -n "$ADMIN_USER" ]     && echo "KUBUNO_ADMIN_USER=${ADMIN_USER}"
    [ -n "$ADMIN_PASSWORD" ] && echo "KUBUNO_ADMIN_PASSWORD=${ADMIN_PASSWORD}"
    [ -n "$ADMIN_EMAIL" ]    && echo "KUBUNO_ADMIN_EMAIL=${ADMIN_EMAIL}"
  } | $SUDO tee .env >/dev/null
  $SUDO chmod 600 .env
else
  log ".env existant conservé (secrets inchangés)"
fi

# Mises à jour idempotentes : appliquer les options explicitement passées.
[ -n "$PORT_SET" ] && { upsert_env KUBUNO_PORT "$(port_bind)"; log "Port → $(port_bind)"; }
[ -n "$TAG_SET" ]  && { upsert_env KUBUNO_TAG  "$KUBUNO_TAG";  log "Tag → $KUBUNO_TAG"; }

# DOMAIN effectif (option, sinon valeur du .env existant).
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
log "Pull de $(grep -E '^KUBUNO_TAG=' .env | cut -d= -f2- | sed "s|^|${IMAGE}:|")…"
$SUDO docker compose "${FILES[@]}" pull
log "Démarrage de la stack…"
$SUDO docker compose "${FILES[@]}" up -d

# ── 6b. Wrapper + auto-update ────────────────────────────────────────────────
# Wrapper qui mémorise le jeu de fichiers compose (pour les commandes & le cron).
$SUDO tee "$INSTALL_DIR/compose.sh" >/dev/null <<WRAP
#!/usr/bin/env bash
cd "\$(dirname "\$0")"
exec docker compose ${FILES[*]} "\$@"
WRAP
$SUDO chmod +x "$INSTALL_DIR/compose.sh"

if [ "$AUTO_UPDATE" = 1 ]; then
  log "Auto-update quotidien (cron) — re-pull + restart si l'image a changé"
  printf '30 4 * * * root %s/compose.sh pull -q && %s/compose.sh up -d --remove-orphans >> /var/log/kubuno-update.log 2>&1\n' \
    "$INSTALL_DIR" "$INSTALL_DIR" | $SUDO tee /etc/cron.d/kubuno-update >/dev/null
fi

# ── 7. Résumé ────────────────────────────────────────────────────────────────
EFF_PORT="$(grep -E '^KUBUNO_PORT=' .env | cut -d= -f2- | awk -F: '{print $NF}')"
echo
log "Kubuno est démarré 🎉"
if [ -n "$DOMAIN" ]; then
  echo "  URL     : https://${DOMAIN}  (certificat TLS automatique sous ~1 min)"
else
  IP="$(hostname -I 2>/dev/null | awk '{print $1}')"; [ -z "$IP" ] && IP="<ip-serveur>"
  echo "  URL     : http://${IP}:${EFF_PORT}"
fi
echo "  Admin   : ${ADMIN_USER:-admin} / ${ADMIN_PASSWORD:-kubuno}   (à changer dès la 1re connexion)"
echo "  Dossier : ${INSTALL_DIR}   (config : ${INSTALL_DIR}/.env)"
echo "  Logs    : ${INSTALL_DIR}/compose.sh logs -f"
echo "  Arrêt   : ${INSTALL_DIR}/compose.sh down"
echo "  Update  : relancer ce script$( [ "$AUTO_UPDATE" = 1 ] && echo ' (ou via le cron quotidien)' )"
