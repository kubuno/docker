#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Kubuno — installateur de DÉMO durcie (à lancer en ROOT sur un VPS dédié).
#
# Met en place une démo isolée au maximum :
#   • Docker ROOTLESS sous un utilisateur dédié non-privilégié
#   • Conteneurs durcis (cap_drop, no-new-privileges, rootfs read-only, limites)
#   • App bindée en loopback (127.0.0.1) → à exposer via TON nginx (TLS)
#   • Cap disque TOTAL  : volumes posés sur un loopback ext4 de --cap-mb Mo (déf. 1024)
#   • Quota par compte  : --quota-mb Mo (déf. 100) appliqué en base
#   • TTL des comptes   : suppression auto au bout de --ttl-hours h (déf. 24, cron)
#   • Auto-update        : pull + up quotidien (cron) ; relancer ce script met aussi à jour
#
#   curl -fsSL https://raw.githubusercontent.com/kubuno/docker/main/install-demo.sh | sudo bash
#   ... | sudo bash -s -- --port 8090 --cap-mb 1024 --quota-mb 100 --ttl-hours 24
#
# Désinstaller complètement (conteneurs + volumes + images + cap disque + user) :
#   curl -fsSL .../install-demo.sh | sudo bash -s -- --uninstall
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

DEMO_USER="kubuno-demo"
INSTALL_DIR=""                 # défaut: /home/<user>/kubuno
KUBUNO_PORT=8090
KUBUNO_TAG="0.1.2"
CAP_MB=1024                    # plafond disque total (volumes)
QUOTA_MB=100                   # quota par compte
TTL_HOURS=24                   # durée de vie d'un compte
AUTO_UPDATE=1
UNINSTALL=0
TARBALL="${KUBUNO_REPO_TARBALL:-https://github.com/kubuno/docker/archive/refs/heads/main.tar.gz}"

while [ $# -gt 0 ]; do
  case "$1" in
    --user) DEMO_USER="$2"; shift 2;;
    --dir) INSTALL_DIR="$2"; shift 2;;
    --port) KUBUNO_PORT="$2"; shift 2;;
    --tag) KUBUNO_TAG="$2"; shift 2;;
    --cap-mb) CAP_MB="$2"; shift 2;;
    --quota-mb) QUOTA_MB="$2"; shift 2;;
    --ttl-hours) TTL_HOURS="$2"; shift 2;;
    --no-auto-update) AUTO_UPDATE=0; shift;;
    --uninstall) UNINSTALL=1; shift;;
    -h|--help) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) echo "Option inconnue: $1" >&2; exit 1;;
  esac
done

log() { printf '\033[1;35m▸ %s\033[0m\n' "$*"; }
err() { printf '\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || err "Lance ce script en root (config user/loopback/montage)."

QUOTA_BYTES=$(( QUOTA_MB * 1024 * 1024 ))
USER_HOME="/home/${DEMO_USER}"
[ -n "$INSTALL_DIR" ] || INSTALL_DIR="${USER_HOME}/kubuno"
DATA_IMG="/var/lib/${DEMO_USER}-data.img"

# ── Désinstallation complète ─────────────────────────────────────────────────
if [ "$UNINSTALL" = 1 ]; then
  log "Désinstallation complète de la démo Kubuno…"
  if id "$DEMO_USER" >/dev/null 2>&1; then
    DUID="$(id -u "$DEMO_USER")"; RT="/run/user/${DUID}"; VOL_DIR="${USER_HOME}/.local/share/docker/volumes"
    asu() { runuser -u "$DEMO_USER" -- env HOME="$USER_HOME" XDG_RUNTIME_DIR="$RT" \
              DBUS_SESSION_BUS_ADDRESS="unix:path=$RT/bus" DOCKER_HOST="unix://$RT/docker.sock" \
              PATH="$USER_HOME/bin:/usr/sbin:/usr/bin:/sbin:/bin" bash -c "$*"; }
    systemctl start "user@${DUID}.service" 2>/dev/null || true
    [ -x "$INSTALL_DIR/compose.sh" ] && asu "'$INSTALL_DIR/compose.sh' down -v --rmi all --remove-orphans" 2>/dev/null || true
    asu "crontab -r" 2>/dev/null || true
    asu "dockerd-rootless-setuptool.sh uninstall -f" 2>/dev/null || true
    asu "systemctl --user stop docker" 2>/dev/null || true
    mountpoint -q "$VOL_DIR" 2>/dev/null && umount "$VOL_DIR" 2>/dev/null || true
    loginctl disable-linger "$DEMO_USER" 2>/dev/null || true
    deluser --remove-home "$DEMO_USER" >/dev/null 2>&1 || userdel -r "$DEMO_USER" 2>/dev/null || true
  fi
  sed -i "\|${DATA_IMG}|d" /etc/fstab 2>/dev/null || true
  rm -f "$DATA_IMG"
  log "Désinstallé : conteneurs, volumes, images, cap disque, crons et utilisateur ${DEMO_USER} supprimés."
  log "(Le moteur Docker système, si présent, n'est pas touché.)"
  exit 0
fi

# ── 1. Paquets ───────────────────────────────────────────────────────────────
log "Installation des prérequis…"
apt-get update -qq
apt-get install -y -qq uidmap dbus-user-session slirp4netns fuse-overlayfs curl ca-certificates e2fsprogs >/dev/null

# ── 2. Utilisateur dédié + linger ────────────────────────────────────────────
if ! id "$DEMO_USER" >/dev/null 2>&1; then
  log "Création de l'utilisateur $DEMO_USER"
  adduser --disabled-password --gecos "" "$DEMO_USER" >/dev/null
fi
loginctl enable-linger "$DEMO_USER"
DEMO_UID="$(id -u "$DEMO_USER")"
RT="/run/user/${DEMO_UID}"
VOL_DIR="${USER_HOME}/.local/share/docker/volumes"

# Exécute une commande en tant que l'utilisateur, avec l'environnement rootless
# (sans login-shell, pour ne pas écraser le PATH/env qu'on fournit).
as_user() {
  runuser -u "$DEMO_USER" -- env \
    HOME="$USER_HOME" XDG_RUNTIME_DIR="$RT" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=$RT/bus" \
    DOCKER_HOST="unix://$RT/docker.sock" \
    PATH="$USER_HOME/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    bash -c "$*"
}

# ── 3. Loopback ext4 = cap disque TOTAL des volumes ──────────────────────────
if [ ! -f "$DATA_IMG" ]; then
  log "Création du conteneur disque ${CAP_MB} Mo ($DATA_IMG)"
  fallocate -l "${CAP_MB}M" "$DATA_IMG" 2>/dev/null || dd if=/dev/zero of="$DATA_IMG" bs=1M count="$CAP_MB" status=none
  mkfs.ext4 -q "$DATA_IMG"
fi

# ── 4. Session systemd utilisateur + Docker rootless ─────────────────────────
# Prérequis rootless : plages subuid/subgid pour l'utilisateur.
grep -q "^${DEMO_USER}:" /etc/subuid || echo "${DEMO_USER}:100000:65536" >> /etc/subuid
grep -q "^${DEMO_USER}:" /etc/subgid || echo "${DEMO_USER}:100000:65536" >> /etc/subgid

# Démarrer le gestionnaire systemd de l'utilisateur (crée /run/user/<uid> + bus DBus),
# sinon `systemctl --user` échoue avec « Failed to connect to bus ».
systemctl start "user@${DEMO_UID}.service" 2>/dev/null || true
for _ in $(seq 1 30); do [ -S "$RT/bus" ] && break; sleep 1; done
[ -S "$RT/bus" ] || err "Session systemd de $DEMO_USER indisponible ($RT/bus). Vérifie 'loginctl enable-linger $DEMO_USER'."

log "Installation de Docker rootless…"
# Récupère les binaires rootless si absents (sinon réutilise ceux déjà présents).
as_user "command -v dockerd-rootless-setuptool.sh >/dev/null 2>&1 || curl -fsSL https://get.docker.com/rootless | sh"
# ⚠️ Étape qui CRÉE le service utilisateur ~/.config/systemd/user/docker.service.
# Indispensable et idempotente (--force) : ne PAS la sauter même si les binaires existent.
as_user "dockerd-rootless-setuptool.sh install --force" \
  || err "Échec de 'dockerd-rootless-setuptool.sh install' (voir au-dessus). Vérifie subuid/subgid, slirp4netns, cgroup v2."
as_user "systemctl --user daemon-reload"
as_user "systemctl --user enable --now docker"   # 1er démarrage → crée ~/.local/share/docker

# Monter le loopback SUR le dossier des volumes rootless (volumes nommés → cap disque).
as_user "systemctl --user stop docker"
as_user "mkdir -p '$VOL_DIR'"
if ! mountpoint -q "$VOL_DIR"; then
  log "Montage du cap disque sur $VOL_DIR"
  mount -o loop "$DATA_IMG" "$VOL_DIR"
fi
grep -q "$DATA_IMG" /etc/fstab || echo "$DATA_IMG $VOL_DIR ext4 loop,nofail 0 2" >> /etc/fstab
chown -R "$DEMO_USER:$DEMO_USER" "$VOL_DIR"
as_user "systemctl --user start docker"
as_user "docker version >/dev/null" || err "Docker rootless ne répond pas (voir 'journalctl --user -u docker' sous $DEMO_USER)."

# ── 5. Fichiers de déploiement + .env ────────────────────────────────────────
as_user "mkdir -p '$INSTALL_DIR' && curl -fsSL '$TARBALL' | tar xz --strip-components=1 -C '$INSTALL_DIR'"
if ! as_user "test -f '$INSTALL_DIR/.env'"; then
  log "Génération de .env (secrets)"
  as_user "umask 177; { \
    echo POSTGRES_USER=kubuno; \
    echo POSTGRES_PASSWORD=\$(openssl rand -hex 16); \
    echo POSTGRES_DB=kubuno; \
    echo KUBUNO_JWT_SECRET=\$(openssl rand -base64 48); \
    echo KUBUNO_INTERNAL_SECRET=\$(openssl rand -hex 32); \
    echo KUBUNO_TAG=$KUBUNO_TAG; \
    echo KUBUNO_PORT=$KUBUNO_PORT; \
  } > '$INSTALL_DIR/.env'"
else
  log ".env existant conservé (mise à jour du tag → $KUBUNO_TAG)"
  as_user "sed -i 's|^KUBUNO_TAG=.*|KUBUNO_TAG=$KUBUNO_TAG|' '$INSTALL_DIR/.env'"
fi

# ── 6. Wrapper compose (self-contained : env rootless + tous les -f) ──────────
COMPOSE_FILES="-f docker-compose.yml -f docker-compose.prod.yml -f docker-compose.demo.yml"
as_user "cat > '$INSTALL_DIR/compose.sh' <<WRAP
#!/usr/bin/env bash
export XDG_RUNTIME_DIR='$RT' DOCKER_HOST='unix://$RT/docker.sock' PATH=\"\\\$HOME/bin:\\\$PATH\"
cd \"\\\$(dirname \"\\\$0\")\"
exec docker compose $COMPOSE_FILES \"\\\$@\"
WRAP
chmod +x '$INSTALL_DIR/compose.sh'"

# ── 7. Déploiement / mise à jour ─────────────────────────────────────────────
log "Pull + démarrage (image ghcr.io/kubuno/kubuno:${KUBUNO_TAG})…"
as_user "'$INSTALL_DIR/compose.sh' pull"
as_user "'$INSTALL_DIR/compose.sh' up -d --remove-orphans"

# ── 8. Quota 100 Mo/compte (attendre que le core ait migré la base) ──────────
log "Application du quota ${QUOTA_MB} Mo/compte…"
as_user "for i in \$(seq 1 60); do curl -fsS http://127.0.0.1:$KUBUNO_PORT/health >/dev/null 2>&1 && break; sleep 2; done"
as_user "'$INSTALL_DIR/compose.sh' exec -T db psql -U kubuno -d kubuno -v ON_ERROR_STOP=1 -c \
  \"ALTER TABLE core.users ALTER COLUMN quota_bytes SET DEFAULT $QUOTA_BYTES; \
    UPDATE core.users SET quota_bytes=$QUOTA_BYTES WHERE role <> 'admin'; \
    UPDATE core.settings SET value='$QUOTA_BYTES' WHERE key='storage.default_quota_bytes';\"" \
  || log "⚠ quota non appliqué (la base n'était peut-être pas prête) — relance le script."

# ── 9. Crons : purge TTL + auto-update ───────────────────────────────────────
CRON_CLEAN="17 * * * * TTL_HOURS=$TTL_HOURS KUBUNO_BASE=http://127.0.0.1:$KUBUNO_PORT bash $INSTALL_DIR/demo-cleanup.sh >> \$HOME/demo-cleanup.log 2>&1"
CRON_UPDATE="30 4 * * * $INSTALL_DIR/compose.sh pull -q && $INSTALL_DIR/compose.sh up -d --remove-orphans >> \$HOME/demo-update.log 2>&1"
log "Installation des tâches cron (purge ${TTL_HOURS}h$([ "$AUTO_UPDATE" = 1 ] && echo ' + auto-update quotidien'))"
as_user "( crontab -l 2>/dev/null | grep -v 'demo-cleanup.sh' | grep -v 'compose.sh pull'; \
           echo \"$CRON_CLEAN\"; [ $AUTO_UPDATE = 1 ] && echo \"$CRON_UPDATE\" ) | crontab -"

# ── 10. Résumé ───────────────────────────────────────────────────────────────
echo
log "Démo Kubuno installée 🎉"
echo "  Accès interne : http://127.0.0.1:${KUBUNO_PORT}   → expose-le via ton nginx (proxy_pass + TLS, cf. DEMO.md)"
echo "  Admin         : admin / kubuno  (à changer)"
echo "  Utilisateur   : ${DEMO_USER} (Docker rootless)   Dossier : ${INSTALL_DIR}"
echo "  Cap disque    : ${CAP_MB} Mo total · ${QUOTA_MB} Mo/compte · comptes supprimés après ${TTL_HOURS}h"
echo "  Gérer         : sudo -iu ${DEMO_USER}  puis  ${INSTALL_DIR}/compose.sh ps|logs|down"
echo "  Mise à jour   : relancer ce script (ou via le cron quotidien)"
