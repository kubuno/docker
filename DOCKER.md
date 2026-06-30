# Installer Kubuno avec Docker

Déploiement self-hosted de Kubuno via Docker Compose : une image **tout-en-un**
(le core + ses modules) plus un conteneur **PostgreSQL**.

L'image embarque le **core** et l'ensemble des **modules** (drive, calendar,
notes, mail, photos, office, media…). La liste est pilotée par l'argument de build
`MODULES` — on peut donc construire un sous-ensemble (voir
[Choisir les modules](#choisir-les-modules)).

---

## Pourquoi cette architecture

Le core de Kubuno est un **superviseur** : à son démarrage il scanne
`/usr/lib/kubuno/modules/`, lance chaque binaire module en **processus enfant** et
lui injecte sa configuration (URL du core, `internal_secret`, identifiants DB).

L'image Docker ne réinvente donc rien : elle **reproduit le layout d'installation**
(`/usr/lib/kubuno/modules/<id>/`, `/usr/share/kubuno/frontend`, `/etc/kubuno/`) et
lance `kubuno-core`. Le superviseur démarre les modules tout seul — exactement comme
une installation `.deb`. Une seule image, un seul processus racine, configuration
100 % par variables d'environnement.

```
docker compose
├── db       postgres:16     volume kubuno-db     (schéma core + un schéma/module)
└── kubuno   image Kubuno     volume kubuno-data   port 8080
            (core + tous les modules)
```

Le build est **data-driven** : `_tools/docker/build.sh` compile le core puis
chaque module listé dans `MODULES`, **composant par composant** (`cargo clean`
après chacun) pour borner le pic d'espace disque, et assemble le rootfs final.

---

## Prérequis

- Docker Engine + plugin Compose v2 (`docker compose version`).
- L'utilisateur doit pouvoir parler au démon Docker : être dans le groupe `docker`
  (`sudo usermod -aG docker $USER` puis re-login) **ou** préfixer les commandes par
  `sudo`.
- **Espace disque pour le build :** le `cargo clean` par composant borne le pic à
  ~**6–8 Go libres sur la partition de `/var/lib/docker`** (un seul `target/` à la
  fois). Compiler les ~21 modules reste long. Si la partition est trop petite :
  - déplacer le `data-root` de Docker vers une partition plus grande
    (`/etc/docker/daemon.json` → `{"data-root": "/home/docker"}` puis
    `systemctl restart docker`) ;
  - **ou** utiliser l'image pré-buildée (voir
    [Hôte à espace disque limité](#hôte-à-espace-disque-limité)), qui compile sur
    l'hôte et n'empaquette que les binaires.

---

## Démarrage

```bash
cp .env.docker.example .env        # puis éditez .env (secrets !)
docker compose up --build -d       # build + démarrage en arrière-plan
docker compose logs -f kubuno      # suivre le démarrage
```

Renseignez impérativement dans `.env` :

| Variable                  | Rôle                              | Génération                |
|---------------------------|-----------------------------------|---------------------------|
| `POSTGRES_PASSWORD`       | mot de passe PostgreSQL           | au choix                  |
| `KUBUNO_JWT_SECRET`       | signature des JWT (≥ 32 car.)     | `openssl rand -base64 48` |
| `KUBUNO_INTERNAL_SECRET`  | secret core ↔ modules             | `openssl rand -hex 32`    |

Une fois démarré :

```bash
curl http://localhost:8080/health           # {"status":"ok",...}
curl http://localhost:8080/api/v1/modules   # doit lister "drive"
```

### Premier accès

Au premier démarrage, le core crée automatiquement un compte administrateur :

| Identifiant (`login`) | Mot de passe | Email                |
|-----------------------|--------------|----------------------|
| `admin`               | `kubuno`     | `admin@kubuno.local` |

Ouvrez **http://localhost:8080**, connectez-vous avec ces identifiants, puis
**changez immédiatement le mot de passe** (Réglages → Sécurité) — ils sont
identiques sur toute instance fraîche.

Pour fixer d'autres identifiants **dès le premier démarrage**, renseignez (avant
le `up` initial) dans `.env` :

```bash
KUBUNO_ADMIN_USER=monadmin
KUBUNO_ADMIN_PASSWORD=un_mot_de_passe_solide
KUBUNO_ADMIN_EMAIL=admin@mondomaine.fr
```

> Ces variables n'agissent qu'au **seed initial** (quand aucun admin n'existe).
> Les changer après coup ne modifie pas un compte déjà créé.

---

## Configuration

Toute la config passe par des variables `KV__SECTION__CLE` (double underscore),
définies dans `docker-compose.yml` (service `kubuno`). Quelques exemples utiles :

| Variable                          | Défaut (image)               | Description                              |
|-----------------------------------|------------------------------|------------------------------------------|
| `KV__SERVER__PORT`                | `8080`                       | port d'écoute interne                    |
| `KV__SERVER__SECURE_COOKIES`      | `false`                      | mettre `true` derrière un HTTPS          |
| `KV__DATABASE__HOST`              | `db`                         | hôte PostgreSQL                          |
| `KV__STORAGE__BACKEND`            | `local`                      | `local` ou `s3`                          |
| `KV__STORAGE__LOCAL_PATH`         | `/var/lib/kubuno/files`      | racine du stockage local (volume)        |
| `KV__LOGGING__FORMAT`             | `json`                       | `json` ou `pretty`                       |

Le core **répercute automatiquement** les identifiants `KV__DATABASE__*` vers les
modules enfants — pas besoin de les configurer module par module.

### HTTPS

Deux options, au choix :

- **Reverse-proxy** (nginx/Traefik/Caddy) en frontal qui termine le TLS et
  proxifie vers le port 8080 → mettez `KV__SERVER__SECURE_COOKIES=true`.
- **TLS natif du core** : montez vos certificats dans le conteneur et activez
  `KV__SERVER__TLS__ENABLED=true` + `KV__SERVER__TLS__CERT_PATH` /
  `KV__SERVER__TLS__KEY_PATH`.

---

## Données & persistance

- `kubuno-db` — base PostgreSQL.
- `kubuno-data` — `/var/lib/kubuno` (fichiers utilisateurs, données des modules, thèmes).

Sauvegarde minimale : `docker compose exec db pg_dump -U kubuno kubuno` + une copie
du volume `kubuno-data`.

---

## Publier l'image

Le registre par défaut est **GHCR** (`ghcr.io/kubuno/kubuno`), cohérent avec l'org
GitHub `kubuno`. Le `docker push` est une **action sortante** : c'est l'utilisateur
qui la lance.

```bash
# 1. S'authentifier au registre (PAT avec scope write:packages)
echo "$GHCR_TOKEN" | docker login ghcr.io -u kubuno-dev --password-stdin

# 2. Build + tag (:<version> et :latest) + push
bash _tools/docker/publish.sh                 # version lue dans core/Cargo.toml
# variantes :
VERSION=0.1.0 bash _tools/docker/publish.sh   # forcer la version
PUSH=0       bash _tools/docker/publish.sh    # build/tag seulement, sans push
DOCKER="sudo docker" bash _tools/docker/publish.sh   # si hors groupe docker
```

`publish.sh` accepte aussi `REGISTRY` / `NAMESPACE` / `IMAGE` / `MODULES` (cf. en-tête
du script) — par exemple `REGISTRY=docker.io NAMESPACE=moncompte` pour Docker Hub.

**Multi-architecture** (amd64 + arm64) : utiliser buildx
(`docker buildx build --platform linux/amd64,linux/arm64 --push -t ghcr.io/kubuno/kubuno:<v> .`).
Par défaut l'image est mono-arch (celle de la machine de build).

> Automatisation CI : comme l'image agrège les 21 dépôts, héberger le workflow
> dans un dépôt dédié (`kubuno/docker`) qui `checkout` chaque dépôt puis appelle
> `publish.sh` sur push de tag `v*` — même logique que les CI `.deb` par dépôt.

---

## Déployer depuis l'image publiée

Le self-hosteur n'a alors besoin que de `docker-compose.yml`, `docker-compose.prod.yml`
et `.env` (pas des sources) :

```bash
cp .env.docker.example .env     # renseigner les secrets
KUBUNO_TAG=latest docker compose -f docker-compose.yml -f docker-compose.prod.yml pull
KUBUNO_TAG=latest docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d
```

`docker-compose.prod.yml` remplace le `build` par `image: ghcr.io/kubuno/kubuno:<tag>`
(surchargeable via `KUBUNO_IMAGE` / `KUBUNO_TAG`).

---

## Choisir les modules

La liste des modules embarqués est l'argument de build **`MODULES`** (défaut : tous,
défini dans `Dockerfile`). Pour n'en construire qu'un sous-ensemble :

```bash
docker build --build-arg MODULES="drive calendar notes mail photos" -t kubuno .
```

Avec `docker compose`, soit on construit l'image complète par défaut
(`docker compose up --build`), soit on pré-construit avec `MODULES` puis on lance
via l'override image (cf. ci-dessous).

**Ajouter un nouveau module** ne demande aucun bloc Docker : il suffit de l'ajouter
à la liste `MODULES`. `_tools/docker/build.sh` le compile et l'installe au layout
attendu, et le runtime crée ses dossiers `data/temp/config` automatiquement.

> Modules à query SQLx (`drive`, `media`) : le cache `.sqlx` est commité et le build
> tourne en `SQLX_OFFLINE=true` — rien de spécial. `media` nécessite `ffmpeg`, déjà
> installé dans l'image runtime.

---

## Hôte à espace disque limité

Si `/var/lib/docker` n'a pas la place, compilez sur l'hôte (là où vous avez de
l'espace) puis empaquetez le rootfs via `Dockerfile.local` — même script de build :

```bash
# 1. Assembler le rootfs sur l'hôte (compile core + modules).
#    CLEAN=1 borne le pic disque mais EFFACE les caches cargo des dépôts.
MODULES="drive calendar notes" \
SRC="$PWD" OUT="$PWD/_artifacts/docker-rootfs" CLEAN=1 \
bash _tools/docker/build.sh

# 2. Construire l'image runtime (base à glibc >= celle de l'hôte de build ;
#    hôte Ubuntu 24.04 → glibc 2.39).
docker build -f Dockerfile.local \
  --build-arg RUNTIME_BASE=ubuntu:24.04 \
  --build-arg MODULES="drive calendar notes" \
  -t kubuno:local .

# 3. Démarrer (override = image pré-buildée au lieu de la recompiler)
docker compose -f docker-compose.yml -f docker-compose.local.yml up -d
```

`Dockerfile.local.dockerignore` réduit le contexte au seul rootfs assemblé.

---

## Commandes utiles

```bash
docker compose ps                       # état des conteneurs
docker compose logs -f kubuno           # logs du core + modules
docker compose exec kubuno kubuno db:status   # connectivité + migrations (CLI core)
docker compose down                     # arrêt (conserve les volumes)
docker compose down -v                  # arrêt + suppression des données (DESTRUCTIF)
docker compose build --no-cache kubuno  # rebuild complet
```
