# Exercice Docker #11 (TP01) - Reprendre en main une image « historique »

**Objectif :** livrer une image `shopapi` conforme aux standards Shop SAS (taille < 200 Mo, non-root, sans secrets, cache-friendly, healthcheck, labels OCI, tests dans le build, hadolint propre) **sans modifier le code applicatif**.

Fichiers : dossier `exo-11/`

```
exo-11/
├── shopapi/
│   ├── Dockerfile            # Dockerfile final (multi-stage)
│   ├── .dockerignore         # liste blanche
│   ├── Dockerfile.legacy     # Dockerfile d'origine, gardé pour la comparaison
│   ├── package-lock.json     # généré (npm install --package-lock-only), requis par npm ci
│   ├── package.json, src/, test/          # code fourni, non modifié
│   └── .env, dump-prod-2024.sql           # fichiers fournis, exclus de l'image
└── bonus/
    ├── Dockerfile.distroless       # B1
    └── Dockerfile.sans-cache-mount # B2
```

Environnement : Docker Desktop 27.3.1, macOS Apple Silicon (`linux/arm64`).

---

## Livrable 1 : DIAGNOSTIC

### Commandes de diagnostic (sorties réelles)

```bash
$ time docker build -t shopapi:legacy .
...
#7 [3/9] RUN apt-get install -y curl wget vim git build-essential python3
#7 DONE 22.5s
...
#13 [9/9] RUN npm install
#13 DONE 4.6s
real 51.901 s

$ docker image ls shopapi:legacy
REPOSITORY   TAG       IMAGE ID       CREATED         SIZE
shopapi      legacy    f9eca0003e6a   3 seconds ago   715MB

$ docker image inspect shopapi:legacy --format 'size={{.Size}} layers={{len .RootFS.Layers}} user=[{{.Config.User}}] cmd={{json .Config.Cmd}} health={{json .Config.Healthcheck}} labels={{json .Config.Labels}}'
size=715182561 layers=9 user=[] cmd=["/bin/sh","-c","npm start"] health=null labels={"org.opencontainers.image.version":"22.04"}
```

```bash
$ docker history shopapi:legacy --format '{{.Size}}\t{{.CreatedBy}}' --no-trunc
0B      CMD ["/bin/sh" "-c" "npm start"]
0B      EXPOSE map[3000/tcp:{}]
0B      ENV DATABASE_URL=postgres://shop:S3cret!@db.internal:5432/shop
0B      ENV NODE_ENV=development
44.8MB  RUN /bin/sh -c npm install # buildkit
5.63kB  COPY . /app # buildkit
0B      WORKDIR /app
5.1MB   RUN /bin/sh -c npm install -g nodemon # buildkit
160MB   RUN /bin/sh -c apt-get install -y nodejs # buildkit
2.09MB  RUN /bin/sh -c curl -fsSL https://deb.nodesource.com/setup_20.x | bash - # buildkit
353MB   RUN /bin/sh -c apt-get install -y curl wget vim git build-essential python3 # buildkit
80.6MB  RUN /bin/sh -c apt-get update # buildkit
0B      ENV DEBIAN_FRONTEND=noninteractive
0B      /bin/sh -c #(nop)  CMD ["/bin/bash"]
69.8MB  /bin/sh -c #(nop) ADD file:1e8b3941ec80... in /
0B      /bin/sh -c #(nop)  LABEL org.opencontainers.image.version=22.04
```

```bash
$ docker run --rm shopapi:legacy env | grep -i -E 'secret|database|node_env'
NODE_ENV=development
DATABASE_URL=postgres://shop:S3cret!@db.internal:5432/shop

$ docker run --rm shopapi:legacy id
uid=0(root) gid=0(root) groups=0(root)

$ docker run --rm shopapi:legacy ls -la /app
-rw-r--r--   1 root root   179 Oct 26 12:08 .env
-rw-r--r--   1 root root    20 Oct 26 12:08 .gitignore
-rw-------   1 root root   505 Oct 26 12:08 Dockerfile
-rw-r--r--   1 root root    47 Oct 26 12:08 dump-prod-2024.sql
drwxr-xr-x 199 root root  4096 Oct 26 12:09 node_modules
-rw-r--r--   1 root root 96529 Oct 26 12:09 package-lock.json
-rw-r--r--   1 root root   545 Oct 26 12:08 package.json
drwxr-xr-x   2 root root  4096 Oct 26 12:08 src
drwxr-xr-x   2 root root  4096 Oct 26 12:08 test

$ docker run --rm shopapi:legacy cat /app/.env
# fichier local d'un dev, commité par erreur
DATABASE_URL=postgres://shop:S3cret!@localhost:5432/shop
REDIS_URL=redis://localhost:6379
AWS_SECRET_ACCESS_KEY=AKIAFAKEFAKEFAKEFAKE

$ docker run --rm shopapi:legacy sh -c 'ls /app/node_modules | grep -E "^(eslint|nodemon)$"; which nodemon vim git gcc curl wget python3'
eslint
nodemon
/usr/bin/nodemon
/usr/bin/vim
/usr/bin/git
/usr/bin/gcc
/usr/bin/curl
/usr/bin/wget
/usr/bin/python3

$ docker run --rm shopapi:legacy du -sh /app/node_modules /usr/lib/gcc /usr/share/vim /var/lib/apt/lists
32M     /app/node_modules
90M     /usr/lib/gcc
36M     /usr/share/vim
77M     /var/lib/apt/lists
```

```bash
$ docker run --rm -i hadolint/hadolint < Dockerfile
-:4 DL3009 info: Delete the apt lists (/var/lib/apt/lists) after installing something
-:5 DL3008 warning: Pin versions in apt get install.
-:5 DL3015 info: Avoid additional packages by specifying `--no-install-recommends`
-:5 DL3059 info: Multiple consecutive `RUN` instructions. Consider consolidation.
-:6 DL4006 warning: Set the SHELL option -o pipefail before RUN with a pipe in it.
-:7 DL3008 warning: Pin versions in apt get install.
-:7 DL3015 info: Avoid additional packages by specifying `--no-install-recommends`
-:8 DL3059 info: Multiple consecutive `RUN` instructions. Consider consolidation.
-:8 DL3016 warning: Pin versions in npm.
-:15 DL3025 warning: Use arguments JSON notation for CMD and ENTRYPOINT arguments
```

`dive shopapi:legacy` (mode CI) liste notamment des fichiers présents dans plusieurs couches : cache npm `/root/.npm/_cacache/...`, verrous et fichiers apt/dpkg (`/var/lib/apt/lists/*`, `/var/cache/apt/archives/*`, `/var/lib/dpkg/*`).

```bash
$ docker run -d --name api-legacy -p 3001:3000 shopapi:legacy
$ docker top api-legacy -o pid,comm,args
PID     COMMAND   COMMAND
11521   sh        /bin/sh -c npm start
11545   npm       start npm start
11556   sh        sh -c node src/server.js
11557   node      node src/server.js

$ time docker stop api-legacy
api-legacy
real 10.164 s
$ docker inspect api-legacy --format 'ExitCode={{.State.ExitCode}}'
ExitCode=137
```

### Problèmes identifiés (19)

#### A. Taille / performance

| # | Problème | Preuve | Impact |
|---|---|---|---|
| 1 | Image de base `ubuntu:22.04` + Node installé via NodeSource au lieu d'une image Node officielle | `docker image ls` : **715 Mo** ; couche `apt-get install -y nodejs` = 160 Mo | Registre saturé, pulls lents sur chaque nœud, démarrage de pod plus long |
| 2 | Outils de build et d'édition dans l'image finale (`build-essential`, `vim`, `git`, `curl`, `wget`, `python3`) | Couche de **353 Mo** ; `du` : gcc 90 Mo, vim 36 Mo ; `which` trouve tous ces binaires | Près de la moitié de l'image ne sert pas à l'exécution |
| 3 | Listes apt jamais supprimées, `apt-get update` dans un `RUN` séparé | `du /var/lib/apt/lists` = **77 Mo** ; hadolint DL3009, DL3059 | 77 Mo inutiles ; la couche `update` peut rester en cache et installer des paquets obsolètes |
| 4 | Un `RUN` par commande : 9 couches dont plusieurs inutiles | `RootFS.Layers` = 9 ; hadolint DL3059 | Fichiers supprimés plus tard restent dans les couches précédentes, plus d'I/O au pull |
| 5 | `COPY . /app` **avant** `npm install` | Étape 2 : après un simple commentaire dans `server.js`, `RUN npm install` est rejoué | Chaque commit relance l'installation des dépendances en CI (≈ 4 min chez Shop SAS) |
| 6 | Dépendances de dev installées dans l'image (`npm install` sans `--omit=dev`) | `eslint` et `nodemon` présents dans `node_modules` ; `node_modules` = 32 Mo contre 8,56 Mo en prod seule | Image plus lourde, surface d'attaque plus grande |
| 7 | `nodemon` installé globalement et cache npm laissé dans l'image | `which nodemon` → `/usr/bin/nodemon` ; dive liste `/root/.npm/_cacache/*` | Outil de dev inutile en prod, cache npm embarqué |
| 8 | Pas de `.dockerignore` | `ls /app` montre `Dockerfile`, `.gitignore`, `test/`, `dump-prod-2024.sql` | Contexte de build plus gros, et tout changement de n'importe quel fichier (README, doc) invalide le cache |

#### B. Sécurité

| # | Problème | Preuve | Impact |
|---|---|---|---|
| 9 | Le conteneur tourne en **root** | `id` → `uid=0(root)` ; `Config.User` vide | Une faille RCE dans l'API donne root dans le conteneur (et facilite une évasion) |
| 10 | Mot de passe de base de données en clair dans un `ENV` | `env` et `docker history` affichent `DATABASE_URL=postgres://shop:S3cret!@db.internal:5432/shop` | Secret lisible par quiconque peut faire `pull` de l'image ; impossible à faire tourner sans rebuild |
| 11 | Fichier `.env` copié dans l'image | `cat /app/.env` affiche `AWS_SECRET_ACCESS_KEY` et `DATABASE_URL` | Fuite de clés cloud via le registre |
| 12 | Dump de production dans l'image | `ls /app` → `dump-prod-2024.sql` | Données de prod (potentiellement personnelles, RGPD) distribuées avec l'image |
| 13 | `curl ... \| bash` sans `pipefail`, versions apt/npm non épinglées, base non épinglée par digest | hadolint DL4006, DL3008 (x2), DL3016 | Build non reproductible ; un script distant compromis ou une erreur réseau passe inaperçue |
| 14 | Outils exploitables à disposition d'un attaquant (`curl`, `wget`, `git`, `gcc`, `python3`) | `which` les trouve tous | Un attaquant dans le conteneur peut télécharger et compiler des outils |

#### C. Exploitabilité

| # | Problème | Preuve | Impact |
|---|---|---|---|
| 15 | `CMD` en forme shell + `npm start` : le PID 1 est `/bin/sh`, pas `node` | `Config.Cmd` = `["/bin/sh","-c","npm start"]` ; `docker top` : `sh` → `npm` → `sh` → `node` ; hadolint DL3025 | `SIGTERM` n'arrive jamais à `node` : le handler `shutdown()` du code ne s'exécute pas |
| 16 | Arrêt non propre | `time docker stop` = **10,164 s**, `ExitCode=137` (SIGKILL) | Rolling updates lentes, connexions coupées brutalement, pool PostgreSQL non fermé |
| 17 | `NODE_ENV=development` dans l'image | `env` → `NODE_ENV=development` | Express en mode dev (traces d'erreur détaillées, pas d'optimisations) |
| 18 | Aucun `HEALTHCHECK` | `Config.Healthcheck` = `null` | L'orchestrateur ne détecte pas une API bloquée ; pas de statut `healthy` |
| 19 | Pas de labels OCI, et le seul label présent est trompeur | `Labels` = `{"org.opencontainers.image.version":"22.04"}` (hérité d'Ubuntu) | Impossible de savoir quelle version et quel commit tournent en prod |

Les tests ne sont pas non plus exécutés pendant le build : une image cassée peut être publiée.

---

## Étape 2 : invalidation du cache

```bash
$ time docker build -q -t shopapi:legacy .        # rien n'a changé : tout en cache
real 0.828 s

$ echo "// commentaire" >> src/server.js
$ time docker build -t shopapi:legacy .
#9 [2/9] RUN apt-get update                                        CACHED
#8 [3/9] RUN apt-get install -y curl wget vim git build-essential  CACHED
#7 [4/9] RUN curl -fsSL https://deb.nodesource.com/setup_20.x      CACHED
#6 [5/9] RUN apt-get install -y nodejs                             CACHED
#10 [6/9] RUN npm install -g nodemon                               CACHED
#11 [7/9] WORKDIR /app                                             CACHED
#12 [8/9] COPY . /app                                              DONE 0.0s
#13 [9/9] RUN npm install                                          DONE 4.4s
real 5.012 s
```

**Pourquoi `npm install` est rejoué :** Docker calcule la clé de cache d'une instruction `COPY` à partir du contenu des fichiers copiés. `COPY . /app` copie **tout** le dossier : modifier `server.js` (ou un README, faute de `.dockerignore`) change cette clé, la couche est reconstruite, et **toutes les couches suivantes** sont invalidées, dont `RUN npm install`. Ici l'installation ne prend que 4,4 s parce qu'il y a peu de dépendances et un réseau rapide ; en CI sans cache local, c'est l'étape qui coûte les 4 minutes.

**Ordre idéal des couches** (de la plus stable à la plus volatile) :

```
┌─────────────────────────────────────────────┐
│ FROM node:20.20.2-alpine3.22                │  change : montée de version Node
├─────────────────────────────────────────────┤
│ WORKDIR /app                                │
├─────────────────────────────────────────────┤
│ COPY package.json package-lock.json ./      │  change : ajout/màj d'une dépendance
├─────────────────────────────────────────────┤
│ RUN npm ci --omit=dev                       │  ← reste en cache tant que le lockfile ne bouge pas
├─────────────────────────────────────────────┤
│ COPY src ./src                              │  change : à chaque commit de code
├─────────────────────────────────────────────┤
│ USER / HEALTHCHECK / CMD (métadonnées)      │
└─────────────────────────────────────────────┘
```

---

## Étape 3 : Dockerfile réécrit

### `.dockerignore`

Liste blanche plutôt que liste noire : un nouveau fichier sensible ajouté au repo (autre dump, autre `.env`) ne peut pas entrer dans l'image par oubli.

```
# Liste blanche : tout est exclu sauf ce qui est nécessaire au build
*
!package.json
!package-lock.json
!src/
!test/
```

### `Dockerfile`

```dockerfile
# syntax=docker/dockerfile:1.7
# shopapi : image de production (multi-stage)

ARG NODE_IMAGE=node:20.20.2-alpine3.22

# ---- base : manifestes npm uniquement (couche stable, en cache tant que les dépendances ne changent pas)
FROM ${NODE_IMAGE} AS base
WORKDIR /app
COPY package.json package-lock.json ./

# ---- deps : dépendances de production seulement
FROM base AS deps
ENV NODE_ENV=production
RUN --mount=type=cache,target=/root/.npm \
    npm ci --omit=dev --no-audit --no-fund

# ---- test : dépendances complètes + lint + tests (le build échoue si un test échoue)
FROM base AS test
RUN --mount=type=cache,target=/root/.npm \
    npm ci --no-audit --no-fund
COPY src ./src
COPY test ./test
RUN npm run lint && npm test

# ---- runtime : image finale
FROM ${NODE_IMAGE} AS runtime
ARG APP_VERSION=dev
ARG GIT_SHA=unknown
LABEL org.opencontainers.image.title="shopapi" \
      org.opencontainers.image.description="API catalogue produits Shop SAS" \
      org.opencontainers.image.version="${APP_VERSION}" \
      org.opencontainers.image.revision="${GIT_SHA}" \
      org.opencontainers.image.source="https://github.com/christopheutp/docker_ynov_10_26" \
      org.opencontainers.image.licenses="UNLICENSED"
ENV NODE_ENV=production \
    APP_VERSION=${APP_VERSION} \
    PORT=3000
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY package.json ./
# src est copié depuis l'étape test : l'image finale ne peut pas être construite si les tests échouent
COPY --from=test /app/src ./src
# utilisateur node de l'image officielle (uid/gid numériques : vérifiable par Kubernetes runAsNonRoot)
USER 1000:1000
EXPOSE 3000
HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
  CMD ["node", "-e", "fetch('http://127.0.0.1:3000/health').then(r => process.exit(r.ok ? 0 : 1)).catch(() => process.exit(1))"]
CMD ["node", "src/server.js"]
```

### Choix techniques

| Choix | Justification |
|---|---|
| `node:20.20.2-alpine3.22` | Image officielle, version complète épinglée (Node **et** Alpine). Toutes les dépendances sont en JavaScript pur (`pg`, `ioredis`, `express`...), aucun module natif : la libc musl d'Alpine ne pose pas de problème, donc pas besoin de `-slim`. |
| Node 20 précisément | `npm test` lance `node --test test/`. Testé hors Docker : le test **passe sous Node 20** et **échoue sous Node 22** (`Cannot find module '.../test'`), car depuis Node 21 les arguments de `--test` sont des motifs glob et un dossier n'est plus parcouru. Épingler la version évite ce genre de casse silencieuse. |
| `package-lock.json` + `npm ci` | `npm ci` installe exactement le lockfile (reproductible) et échoue s'il est désynchronisé. Le starter n'en avait pas : il a été généré avec `npm install --package-lock-only` (aucun changement du code). |
| 4 étapes `base` / `deps` / `test` / `runtime` | `deps` n'a que la prod (`--omit=dev`) ; `test` a tout pour lint + tests ; `runtime` ne reçoit que `node_modules` de prod et `src`. |
| `COPY --from=test /app/src` | L'étape `runtime` dépend de l'étape `test` : BuildKit est obligé d'exécuter les tests pour construire l'image finale. Si un test échoue, `docker build` échoue. |
| `--mount=type=cache,target=/root/.npm` | Le cache npm est réutilisé entre builds sans jamais être écrit dans une couche de l'image (voir B2). |
| `USER 1000:1000` | Utilisateur `node` déjà présent dans l'image officielle. La forme numérique supprime l'info hadolint DL3066 et permet à Kubernetes de vérifier `runAsNonRoot`. |
| `HEALTHCHECK` en `node -e fetch(...)` | Pas de `wget`/`curl` à ajouter : on utilise `fetch`, natif depuis Node 18. La même commande marche en distroless (B1). |
| `CMD ["node", "src/server.js"]` | Forme exec, sans `npm` : `node` est le PID 1 et reçoit directement `SIGTERM`, donc le `shutdown()` du code s'exécute. |
| Aucun secret dans le Dockerfile | `DATABASE_URL`, `REDIS_URL` sont fournis au `docker run` (`-e`, `--env-file`) ou par l'orchestrateur. Sans eux, l'API fonctionne en mémoire (prévu par le code). |

### Builds

```bash
$ time docker build --progress=plain --build-arg APP_VERSION=1.4.2 --build-arg GIT_SHA=2f0cf15 -t shopapi:1.4.2 .
#12 [test 1/4] RUN --mount=type=cache,target=/root/.npm     npm ci --no-audit --no-fund
#12 2.593 added 222 packages in 2s
#16 [test 4/4] RUN npm run lint && npm test
#16 0.341 lint ok
#16 0.465 # Subtest: le module serveur se charge
#16 0.466 ok 1 - le module serveur se charge
#16 0.471 # tests 1
#16 0.471 # pass 1
#16 0.471 # fail 0
#17 [runtime 5/5] COPY --from=test /app/src ./src
#18 naming to docker.io/library/shopapi:1.4.2 done
real 9.542 s

$ time docker build --target test -t shopapi:test .
#13 [test 4/4] RUN npm run lint && npm test
#13 CACHED
real 0.937 s
```

(`GIT_SHA` = `git rev-parse --short HEAD` du dépôt `exercices-docker`.)

### Cache après le changement de code

```bash
$ echo "// commentaire" >> src/server.js
$ time docker build --build-arg APP_VERSION=1.4.2 --build-arg GIT_SHA=2f0cf15 -t shopapi:1.4.2 .
#8  [base 3/3] COPY package.json package-lock.json ./               CACHED
#10 [test 1/4] RUN npm ci --no-audit --no-fund                      CACHED
#11 [test 2/4] COPY src ./src                                        DONE 0.0s
#12 [test 3/4] COPY test ./test                                      DONE 0.0s
#13 [test 4/4] RUN npm run lint && npm test                          DONE 0.4s
#14 [deps 1/1] RUN npm ci --omit=dev --no-audit --no-fund           CACHED
#15 [runtime 3/5] COPY --from=deps /app/node_modules ./node_modules CACHED
#16 [runtime 4/5] COPY package.json ./                               CACHED
#17 [runtime 5/5] COPY --from=test /app/src ./src                    DONE 0.0s
real 1.232 s

$ echo "# doc" > README.md
$ time docker build --build-arg APP_VERSION=1.4.2 --build-arg GIT_SHA=2f0cf15 -t shopapi:1.4.2 .
...                                                                  (tout CACHED)
real 0.664 s
```

Les deux `npm ci` restent en cache : seuls la copie de `src`, les tests et la dernière couche sont rejoués. Un changement de README ne déclenche **rien**, car le fichier n'entre pas dans le contexte de build (liste blanche du `.dockerignore`).

---

## Étape 4 : conformité

```bash
$ docker image ls shopapi
REPOSITORY   TAG       IMAGE ID       CREATED          SIZE
shopapi      test      0afb9d07f855   4 seconds ago    156MB
shopapi      1.4.2     7fdc91f597c1   4 seconds ago    143MB
shopapi      legacy    497484ab432c   31 seconds ago   715MB

$ docker image inspect shopapi:1.4.2 --format 'size={{.Size}} layers={{len .RootFS.Layers}} user={{.Config.User}} cmd={{json .Config.Cmd}}'
size=143318287 layers=8 user=1000:1000 cmd=["node","src/server.js"]

$ docker run --rm shopapi:1.4.2 id
uid=1000(node) gid=1000(node) groups=1000(node)

$ docker run --rm shopapi:1.4.2 ls -la /app
drwxr-xr-x  114 root     root          4096 Oct 26 12:10 node_modules
-rw-r--r--    1 root     root           545 Oct 26 11:50 package.json
drwxr-xr-x    2 root     root          4096 Oct 26 11:50 src

$ docker run --rm shopapi:1.4.2 env | grep -i -E 'secret|database|node_env|app_version'
NODE_ENV=production
APP_VERSION=1.4.2

$ docker run --rm shopapi:1.4.2 sh -c 'ls /app/node_modules | grep -E "^(eslint|nodemon)$" || echo aucune dependance de dev'
aucune dependance de dev

$ docker inspect shopapi:1.4.2 --format '{{json .Config.Labels}}' | jq
{
  "org.opencontainers.image.description": "API catalogue produits Shop SAS",
  "org.opencontainers.image.licenses": "UNLICENSED",
  "org.opencontainers.image.revision": "2f0cf15",
  "org.opencontainers.image.source": "https://github.com/christopheutp/docker_ynov_10_26",
  "org.opencontainers.image.title": "shopapi",
  "org.opencontainers.image.version": "1.4.2"
}

$ docker history shopapi:1.4.2 --format '{{.Size}}\t{{.CreatedBy}}'
0B      CMD ["node" "src/server.js"]
0B      HEALTHCHECK &{["CMD" "node" "-e" "fetch('http://127.0.0.1:3000/health')..."] "10s" ...
0B      EXPOSE map[3000/tcp:{}]
0B      USER 1000:1000
4.13kB  COPY /app/src ./src # buildkit
545B    COPY package.json ./ # buildkit
8.56MB  COPY /app/node_modules ./node_modules # buildkit
0B      WORKDIR /app
0B      ENV NODE_ENV=production APP_VERSION=1.4.2 PORT=3000
0B      LABEL org.opencontainers.image.title=shopapi ...
...     (couches de l'image node:20.20.2-alpine3.22 : 121 Mo pour Node, 8,58 Mo pour Alpine)
```

Notre application n'ajoute que **8,6 Mo** à l'image de base : tout le reste (≈ 135 Mo) est Node.js et Alpine.

`/app` et son contenu appartiennent à `root` et ne sont qu'en lecture pour `node` : le processus ne peut pas modifier son propre code.

Démarrage et arrêt (port 3005 côté hôte, le 3000 étant pris par un autre projet sur la machine) :

```bash
$ docker run -d --name api -p 3005:3000 shopapi:1.4.2
$ sleep 8 && docker inspect api --format '{{.State.Health.Status}}'
healthy

$ curl -s localhost:3005/products | jq
[
  { "id": 1, "name": "Clavier mécanique", "price": 89.9, "stock": 12 },
  { "id": 2, "name": "Écran 27\"", "price": 249, "stock": 4 },
  { "id": 3, "name": "Souris sans fil", "price": 29.5, "stock": 40 }
]

$ curl -s localhost:3005/ ; echo; curl -s localhost:3005/ready
{"service":"shopapi","version":"1.4.2"}
{"status":"ready","checks":{"db":"skipped","redis":"skipped"}}

$ docker top api -o pid,user,comm,args
PID     USER    COMMAND   COMMAND
12819   1000    node      node src/server.js

$ time docker stop api
api
real 0.155 s

$ docker inspect api --format 'ExitCode={{.State.ExitCode}}'; docker logs api | tail -1
ExitCode=0
{"level":30,...,"pid":1,...,"signal":"SIGTERM","msg":"arrêt demandé"}
```

Un seul processus, `node`, avec l'uid 1000. Le log `"pid":1, "signal":"SIGTERM", "msg":"arrêt demandé"` prouve que `node` est bien le PID 1 et que le handler de la ligne `process.on('SIGTERM')` du code s'exécute.

---

## Livrable 2 : rapport avant / après

| Critère | `shopapi:legacy` | `shopapi:1.4.2` |
|---|---|---|
| Taille | **715 Mo** | **143 Mo** (- 80 %) |
| Nombre de couches | 9 | 8 (dont 3 propres à l'app) |
| Image de base | `ubuntu:22.04` + NodeSource | `node:20.20.2-alpine3.22` (officielle, épinglée) |
| Build complet | 51,9 s | 9,5 s |
| Rebuild après changement de code | 5,0 s (`npm install` rejoué) | 1,2 s (aucun `npm ci` rejoué, tests rejoués) |
| Rebuild après changement de README | réinstallation complète (`COPY .`) | 0,7 s (tout en cache) |
| Utilisateur | `root` (uid 0) | `node` (uid 1000) |
| Secrets dans l'image | `DATABASE_URL` en `ENV`, `.env` avec clé AWS | aucun |
| Fichiers inutiles | `.env`, dump SQL, `test/`, `Dockerfile`, outils de build | aucun (`node_modules` prod, `package.json`, `src`) |
| Dépendances de dev | `eslint`, `nodemon` (+ `nodemon` global) | aucune |
| Tests dans le build | non | oui (étape `test`, bloquante) |
| HEALTHCHECK | aucun | oui, statut `healthy` |
| Labels OCI | aucun (label Ubuntu hérité) | version, revision, source, title, description, licenses |
| `CMD` | forme shell (`sh` → `npm` → `sh` → `node`) | forme exec (`node` = PID 1) |
| Temps d'arrêt (`docker stop`) | **10,16 s**, code 137 (SIGKILL) | **0,155 s**, code 0 (SIGTERM géré) |
| hadolint | 5 warnings, 5 infos | aucune sortie |

### Sortie hadolint du Dockerfile final

```bash
$ docker run --rm -i hadolint/hadolint < Dockerfile && echo 'hadolint: aucune sortie'
hadolint: aucune sortie
```

Même résultat sur `bonus/Dockerfile.distroless` et `bonus/Dockerfile.sans-cache-mount`.

### Pourquoi l'image legacy met 10 s à s'arrêter

`docker stop` envoie `SIGTERM` au **PID 1** du conteneur, attend 10 s (délai par défaut), puis envoie `SIGKILL`.

- **Legacy :** le PID 1 est `/bin/sh -c "npm start"`. Un processus PID 1 n'a pas les gestionnaires de signaux par défaut du noyau : `sh` ne gère pas `SIGTERM` et ne le transmet pas à ses enfants (`npm`, puis encore un `sh`, puis `node`). `node` ne reçoit jamais le signal, son `shutdown()` ne s'exécute pas, Docker attend 10 s puis tue tout : code de sortie **137** (128 + 9, SIGKILL).
- **Nouvelle image :** `node` est directement le PID 1 grâce à la forme exec. Il reçoit `SIGTERM`, le handler `process.on('SIGTERM')` du code ferme le serveur HTTP (`server.close`), puis `process.exit(0)` : arrêt en moins d'une seconde, code **0**.

---

## Bonus

### B1 : variante distroless

Fichier : `bonus/Dockerfile.distroless`. Mêmes étapes `test`, mais l'étape `deps` utilise `node:20.20.2-bookworm-slim` (glibc, comme Debian 12) et le runtime `gcr.io/distroless/nodejs20-debian12:nonroot`.

```bash
$ docker build -f ../bonus/Dockerfile.distroless --build-arg APP_VERSION=1.4.2 --build-arg GIT_SHA=2f0cf15 -t shopapi:1.4.2-distroless .
real 10.084 s

$ docker image ls shopapi
shopapi      1.4.2-distroless   a407cc72ba37   140MB
shopapi      1.4.2              7fdc91f597c1   143MB

$ docker image inspect shopapi:1.4.2-distroless --format 'size={{.Size}} layers={{len .RootFS.Layers}} user={{.Config.User}} entrypoint={{json .Config.Entrypoint}} cmd={{json .Config.Cmd}}'
size=140443577 layers=23 user=65532 entrypoint=["/nodejs/bin/node"] cmd=["src/server.js"]

$ docker run -d --name api-dl -p 3002:3000 shopapi:1.4.2-distroless
$ docker inspect api-dl --format '{{.State.Health.Status}}'; curl -s localhost:3002/health
healthy
{"status":"ok"}

$ docker exec api-dl sh -c id
OCI runtime exec failed: exec failed: unable to start container process: exec: "sh": executable file not found in $PATH: unknown

$ docker exec api-dl /nodejs/bin/node -e 'console.log(process.getuid())'
65532

$ time docker stop api-dl
real 0.139 s
```

**Compromis :**

| | Alpine | Distroless |
|---|---|---|
| Taille | 143 Mo | 140 Mo (gain faible : Node reste l'essentiel du poids) |
| Shell, gestionnaire de paquets | `sh`, `apk` | aucun |
| Debug | `docker exec -it api sh` | impossible : il faut `docker debug`, un conteneur éphémère (`kubectl debug`) ou la variante `:debug` (busybox) |
| Surface d'attaque | faible | minimale : un attaquant n'a ni shell ni outil pour aller plus loin |
| Utilisateur | `node` (1000) défini par nous | `nonroot` (65532) fourni par l'image |
| Healthcheck | `node -e fetch(...)` | même commande avec le chemin absolu `/nodejs/bin/node` |

**Healthcheck sans `wget` :** l'image ne contient que le runtime Node. On réutilise donc le binaire `node` lui-même avec `fetch` (natif depuis Node 18), en forme exec (pas de shell disponible pour la forme `CMD-SHELL`). Le code de sortie (0 si `/health` répond 2xx, 1 sinon) est ce que Docker attend. Autre option : un petit script `healthcheck.js` copié dans l'image, ou un binaire statique dédié.

**Limite :** les dépendances doivent être installées sur une base **glibc** (Debian) et non Alpine, sinon un module natif compilé pour musl ne fonctionnerait pas. Ici il n'y en a aucun, mais l'étape `deps` est quand même construite sur `bookworm-slim` par sécurité.

### B2 : `--no-cache` avec ou sans cache mount

Fichier : `bonus/Dockerfile.sans-cache-mount` (identique au Dockerfile principal, sans les `--mount=type=cache`). Chaque variante est construite deux fois avec `--no-cache`.

```bash
$ time docker build -q --no-cache -f ../bonus/Dockerfile.sans-cache-mount -t shopapi:b2 .
real 4.266 s
$ time docker build -q --no-cache -f ../bonus/Dockerfile.sans-cache-mount -t shopapi:b2 .
real 2.934 s

$ time docker build -q --no-cache -t shopapi:b2 .      # avec cache mount
real 3.217 s
$ time docker build -q --no-cache -t shopapi:b2 .
real 3.127 s
```

| Build `--no-cache` | Sans cache mount | Avec cache mount |
|---|---|---|
| 1er | 4,27 s | 3,22 s |
| 2e | 2,93 s | 3,13 s |

**Analyse :**
- `--no-cache` désactive le cache **des couches**, mais pas les **cache mounts** : avec `--mount=type=cache`, le dossier `/root/.npm` de BuildKit est conservé, donc `npm ci` réutilise les paquets déjà téléchargés au lieu de les reprendre sur le registre.
- Ici, l'écart mesuré est **faible et dans le bruit** (le 2e build sans mount est même le plus rapide). Raisons : 222 petits paquets JavaScript (≈ 15 Mo), un réseau rapide, et le cache HTTP du Mac. Le temps de `npm ci` est dominé par l'extraction et l'écriture des fichiers, pas par le téléchargement.
- Le gain devient net quand le téléchargement domine : grosses dépendances, modules natifs avec binaires précompilés, réseau lent ou registre privé distant, CI avec un builder persistant. Le cache mount a aussi l'avantage de ne **jamais** finir dans l'image (contrairement au cache `/root/.npm` trouvé par dive dans l'image legacy).

### B3 : image reproductible

Builds avec un builder BuildKit `docker-container` (l'export `type=oci` n'est pas supporté par le driver `docker` par défaut) :

```bash
$ docker buildx create --name tp01 --driver docker-container --use

# Sans SOURCE_DATE_EPOCH, deux fois
$ docker buildx build --no-cache --build-arg APP_VERSION=1.4.2 --build-arg GIT_SHA=2f0cf15 --output type=oci,dest=sans-sde-1.tar .
$ docker buildx build --no-cache --build-arg APP_VERSION=1.4.2 --build-arg GIT_SHA=2f0cf15 --output type=oci,dest=sans-sde-2.tar .

# Avec SOURCE_DATE_EPOCH = date du dernier commit, deux fois
$ SOURCE_DATE_EPOCH=$(git log -1 --format=%ct) docker buildx build --no-cache --build-arg APP_VERSION=1.4.2 --build-arg GIT_SHA=2f0cf15 \
    --output type=oci,dest=sde-1.tar,rewrite-timestamp=true .
$ SOURCE_DATE_EPOCH=$(git log -1 --format=%ct) docker buildx build --no-cache --build-arg APP_VERSION=1.4.2 --build-arg GIT_SHA=2f0cf15 \
    --output type=oci,dest=sde-2.tar,rewrite-timestamp=true .

# Digest du manifeste de chaque archive OCI
$ tar -xOf <archive>.tar index.json | jq -r '.manifests[0].digest'
sans-sde-1 manifest: sha256:7dbd2832a4c7fcb74bfb0e416c5bcf84bcd89aeb2cd4668ca776ee8ff856cd12
sans-sde-2 manifest: sha256:f845487d861668abc946e471ffd4e450a7b419aa9fb7ded62aaeabce7a9c05a0
sde-1 manifest:      sha256:702ad37f1ed332afe76c23044138d8073eb24d0299339356e0f7eb6f92037435
sde-2 manifest:      sha256:702ad37f1ed332afe76c23044138d8073eb24d0299339356e0f7eb6f92037435

$ git log -1 --format=%ct
1791554650
```

Sans `SOURCE_DATE_EPOCH`, deux builds identiques donnent deux digests différents. Avec `SOURCE_DATE_EPOCH` + `rewrite-timestamp=true`, **les deux builds donnent le même digest** (`sha256:702ad37f...`).

**Ce qui empêche la reproductibilité :**
- **Horodatages** : date de création dans la config de l'image (`created`, historique) et mtime de chaque fichier écrit pendant le build (`npm ci` crée des milliers de fichiers avec l'heure courante). C'est ce qui différait ici. `SOURCE_DATE_EPOCH` fixe la date de la config ; `rewrite-timestamp=true` réécrit le mtime des fichiers des couches à cette date.
- **Entrées qui bougent** : un tag d'image de base qui pointe vers une nouvelle version (`node:20-alpine`), des dépendances non verrouillées (`npm install` sans lockfile, `apt-get install` sans version), un script distant (`curl | bash`). Ici : version Node + Alpine épinglée, `npm ci` sur lockfile. Pour aller plus loin il faudrait épingler la base par digest (`node:20.20.2-alpine3.22@sha256:...`).
- **Contenu non déterministe produit par les outils** : caches, logs, fichiers temporaires, ordre d'archive. Le cache npm est hors image (cache mount) et le `.dockerignore` en liste blanche évite qu'un fichier local imprévu entre dans le contexte.
- **Métadonnées variables** : un `ARG` comme `GIT_SHA` change les labels donc le digest ; c'est voulu (deux commits différents doivent donner deux images différentes), mais il faut le passer à l'identique pour comparer.
