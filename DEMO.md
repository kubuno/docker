# Déployer une démo Kubuno isolée (Docker rootless + nginx)

Objectif : héberger une démo publique en **n'exposant pas l'hôte**. Stratégie de
défense en profondeur :

- **VPS dédié** à la démo (rien d'autre dessus).
- **Docker rootless** : le `root` du conteneur = un utilisateur **non-privilégié**
  de l'hôte → une évasion ne donne pas root sur la machine.
- **Durcissement conteneur** (`docker-compose.demo.yml`) : `cap_drop: ALL`,
  `no-new-privileges`, rootfs en lecture seule + `tmpfs`, limites mém/CPU/PIDs.
- **Réseau** : app bindée en **loopback** (jamais sur l'IP publique), Postgres
  interne ; seul **nginx** (sur l'hôte) y accède et termine le TLS.
- **Hygiène démo** : petits quotas, limite de débit, reset périodique optionnel.

---

## Installation automatisée (recommandé)

Sur un VPS **dédié**, en root, une seule commande met tout en place :

```bash
curl -fsSL https://raw.githubusercontent.com/kubuno/docker/main/install-demo.sh | sudo bash
# options : --port 8090 --cap-mb 1024 --quota-mb 100 --ttl-hours 24 --tag latest
```

`install-demo.sh` applique automatiquement les garanties :

| Contrainte | Mécanisme |
|---|---|
| **≤ 1 Go disque (total)** | volumes posés sur un **loopback ext4** de `--cap-mb` Mo (plafond physique) |
| **≤ 100 Mo / compte** | défaut `quota_bytes` fixé en base à `--quota-mb` Mo (appliqué au boot) |
| **comptes supprimés après 24 h** | cron horaire `demo-cleanup.sh` → suppression via l'API admin (nettoyage des fichiers) |
| isolation hôte | Docker **rootless** + `cap_drop`/`read-only`/limites + bind **loopback** |
| à jour | **auto-update** quotidien (cron) ; relancer le script met aussi à jour |

Il reste juste à **brancher ton nginx** devant `http://127.0.0.1:<port>` (§4).

> Les sections ci-dessous décrivent les mêmes étapes **manuellement** (pour
> comprendre/ajuster).

---

## 1. Préparer l'hôte (en root, une fois)

```bash
# Paquets requis pour le rootless
apt-get update && apt-get install -y uidmap dbus-user-session slirp4netns fuse-overlayfs

# Utilisateur dédié, non-privilégié, sans sudo
adduser --disabled-password --gecos "" kubuno-demo
# Autorise ses services systemd à tourner hors session (au boot)
loginctl enable-linger kubuno-demo
```

## 2. Installer Docker rootless (en tant que `kubuno-demo`)

```bash
sudo -iu kubuno-demo
# (désormais dans le shell de kubuno-demo)
curl -fsSL https://get.docker.com/rootless | sh

# Ajoute à ~/.bashrc puis recharge :
export PATH=$HOME/bin:$PATH
export DOCKER_HOST=unix:///run/user/$(id -u)/docker.sock

systemctl --user enable --now docker
docker version    # doit répondre, sans sudo
```

> Limites mém/CPU/PIDs : nécessitent cgroup v2 délégué (standard sur les distros
> systemd récentes). Si `docker info` signale « No cpu/memory limit support »,
> active la délégation cgroup pour l'utilisateur (doc Docker rootless).

## 3. Déployer la démo (toujours en `kubuno-demo`)

```bash
cd ~
curl -fsSL https://github.com/kubuno/docker/archive/refs/heads/main.tar.gz \
  | tar xz && mv docker-main kubuno && cd kubuno

# Secrets + config
cat > .env <<EOF
POSTGRES_USER=kubuno
POSTGRES_PASSWORD=$(openssl rand -hex 16)
POSTGRES_DB=kubuno
KUBUNO_JWT_SECRET=$(openssl rand -base64 48)
KUBUNO_INTERNAL_SECRET=$(openssl rand -hex 32)
KUBUNO_TAG=latest
KUBUNO_PORT=8090
EOF

# Lancement durci (base + image publiée + durcissement)
docker compose -f docker-compose.yml -f docker-compose.prod.yml -f docker-compose.demo.yml pull
docker compose -f docker-compose.yml -f docker-compose.prod.yml -f docker-compose.demo.yml up -d
```

L'app écoute alors sur **`127.0.0.1:8090`** (loopback) — invisible depuis l'extérieur.

## 4. Reverse-proxy nginx (sur l'hôte, en root) + TLS

```nginx
server {
    listen 443 ssl http2;
    server_name demo.kubuno.com;

    ssl_certificate     /etc/letsencrypt/live/demo.kubuno.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/demo.kubuno.com/privkey.pem;

    client_max_body_size 100m;            # uploads démo

    location / {
        proxy_pass http://127.0.0.1:8090;
        proxy_http_version 1.1;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;   # → cookies Secure côté core
        # WebSocket (/ws) :
        proxy_set_header Upgrade           $http_upgrade;
        proxy_set_header Connection        "upgrade";
    }
}
```

Firewall : n'ouvre que **80/443**. Le port `8090` reste sur la loopback, donc
inaccessible de l'extérieur même sans règle dédiée.

## 5. Hygiène de démo (recommandé)

- **Quotas** : dans la console admin, baisse le quota par défaut (ex. 200 Mo) et la
  taille max d'upload.
- **Admin** : change le mot de passe `admin` / `kubuno` (ou fixe-le au 1er boot via
  `KUBUNO_ADMIN_PASSWORD=…` dans `.env`).
- **Reset périodique** (repartir propre chaque nuit) — cron de `kubuno-demo` :
  ```bash
  # crontab -e (utilisateur kubuno-demo)
  0 4 * * *  cd ~/kubuno && docker compose -f docker-compose.yml -f docker-compose.prod.yml -f docker-compose.demo.yml down -v && docker compose -f docker-compose.yml -f docker-compose.prod.yml -f docker-compose.demo.yml up -d
  ```
  (`down -v` efface les volumes → base + fichiers remis à zéro, admin re-seedé.)

---

## Notes

- `read_only: true` est la mesure la plus stricte ; si un module a besoin d'écrire
  hors des volumes (ex. transcodage `media`), retire **uniquement** `read_only`
  pour `kubuno` — le reste du durcissement reste valable.
- Le core lance ses modules en sous-processus : compatible avec `cap_drop: ALL` +
  `no-new-privileges` (aucune capability nécessaire pour `fork`/`exec`).
- Mises à jour : modifie `KUBUNO_TAG` dans `.env` puis relance `pull` + `up -d`.
