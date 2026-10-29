# Exercice Docker #12 (TP04) - Une stack Compose d'entreprise : du poste du dev à la prod

**Objectif :** transformer le `docker-compose.yml` « qui marche sur le poste du dev » de la stack *Shop SAS* (API, worker, PostgreSQL, Redis) en **référence d'exécution** commune au dev, à la CI et à la prod.

Fichiers : dossier `exo-12/`

```
exo-12/
├── compose.yml                 # base commune
├── compose.override.yml        # surcharge dev (appliquée automatiquement)
├── compose.prod.yml            # surcharge prod
├── compose.watch.yml           # bonus B1 (docker compose watch)
├── .env.example                # variables non secrètes (copié en .env, non versionné)
├── Makefile                    # outillage d'équipe
├── smoke-test.sh               # test de fumée de la stack
├── secrets/                    # db_password.txt généré par `make secrets`, non versionné
├── db/
│   ├── init.sql                # schéma + données initiales
│   └── migrations/002-add-sku.sql
├── apps/
│   ├── shopapi/                # API du TP01 (Dockerfile multi-stage du TP01)
│   └── shop-worker/            # worker du TP02 + Dockerfile multi-stage écrit pour ce TP
└── docker-compose.starter.yml  # compose d'origine, gardé pour la comparaison
```

Environnement : Docker Desktop 27.3.1, Compose v2.30.3, macOS Apple Silicon (`linux/arm64`).

Sur cette machine, un PostgreSQL local écoute déjà sur 5432 et un autre projet utilise 3000 et 8080 : les ports de debug du dev sont donc paramétrés dans `.env` (3005, 5434, 8081). Les valeurs par défaut restent 3000, 5432 et 8080.

---

## 1. Critique du compose existant

```yaml
version: '3'
services:
  db:
    image: postgres
    ports: ["5432:5432"]
    environment:
      POSTGRES_PASSWORD: postgres
  redis:
    image: redis
    ports: ["6379:6379"]
  api:
    build: ./apps/shopapi
    ports: ["3000:3000"]
    links: [db, redis]
    environment:
      DATABASE_URL: postgres://postgres:postgres@db:5432/postgres
      REDIS_URL: redis://redis:6379
    command: sh -c "sleep 10 && node src/server.js"
  worker:
    build: ./apps/shop-worker
    links: [db, redis]
    environment:
      DATABASE_URL: postgres://postgres:postgres@db:5432/postgres
      REDIS_URL: redis://redis:6379
    restart: always
```

```bash
$ docker compose -f docker-compose.starter.yml config -q
level=warning msg="docker-compose.starter.yml: the attribute `version` is obsolete, it will be ignored, please remove it to avoid potential confusion"
```

| # | Problème | Impact |
|---|---|---|
| 1 | `version: '3'` | Obsolète avec Compose v2 (avertissement ci-dessus) : ignoré, donne une fausse idée des fonctionnalités disponibles |
| 2 | Images non épinglées (`postgres`, `redis` = `latest`) | Le jour où `latest` passe à une nouvelle majeure, PostgreSQL refuse de démarrer sur l'ancien volume (démontré au TP05) ; builds et déploiements non reproductibles |
| 3 | `5432:5432` et `6379:6379` publiés sur `0.0.0.0` | Base et Redis (sans mot de passe) joignables depuis le réseau local, voire Internet sur un serveur |
| 4 | Mot de passe `postgres` en clair, écrit 3 fois dans un fichier versionné | Fuite dans Git ; impossible de le changer sans modifier le fichier ; l'application utilise le superutilisateur `postgres` et la base `postgres` |
| 5 | `sleep 10` avant de lancer l'API | Course : si la base met plus de 10 s (premier démarrage, machine chargée) l'API plante ; sinon on perd 10 s à chaque démarrage |
| 6 | `links` | Fonctionnalité legacy : la résolution DNS par nom de service existe déjà sur tout réseau Compose ; `links` n'apporte rien et ne garantit pas que la base est prête |
| 7 | Un seul réseau `default` pour tout | Aucune isolation : tout conteneur peut parler à la base ; pas de séparation entre ce qui est exposé et ce qui est interne |
| 8 | Aucun healthcheck | Compose ne sait pas si un service est prêt ; `depends_on` ne peut attendre que le démarrage du processus ; `docker compose up --wait` est impossible |
| 9 | Pas de volumes nommés | PostgreSQL écrit dans un **volume anonyme** (déclaré par l'image) : nom illisible, facile à perdre avec `down -v` / `rm -v` / `volume prune` ; Redis ne persiste rien |
| 10 | `restart` incohérent | Seul le worker redémarre (`always`) ; si la base ou l'API tombe, rien ne la relance ; `always` relance même un conteneur arrêté volontairement après un redémarrage du démon |
| 11 | Pas de limites CPU / mémoire | Un service qui fuit peut affamer toute la machine |
| 12 | Pas de rotation des logs | Le driver `json-file` grossit sans limite et finit par remplir le disque du serveur |
| 13 | API exposée directement sur 3000, pas de reverse proxy | Pas de point d'entrée unique, pas de TLS possible, et un port fixe empêche de lancer plusieurs réplicas (conflit de port) |
| 14 | `build:` dans le seul fichier, utilisé partout | La prod reconstruirait les images sur le serveur au lieu de déployer une image testée et versionnée depuis un registre |
| 15 | Pas d'outillage | Pas d'admin BDD ni de migrations à la demande : chacun bricole avec `docker exec` |

---

## 2. Fichier de base `compose.yml`

### Choix principaux

| Exigence | Mise en oeuvre |
|---|---|
| Nom de projet stable | `name: shop` : réseaux et volumes s'appellent `shop_front`, `shop_pgdata`... quel que soit le nom du dossier |
| Deux réseaux | `front` (proxy ↔ api, adminer) et `back` avec `internal: true` (api, worker ↔ db, redis). L'API est sur les deux |
| Images épinglées | `postgres:16.4-alpine`, `redis:7.4-alpine`, `traefik:v3.1`, `adminer:4.8.1` ; API et worker construits depuis leurs Dockerfiles (images de base épinglées) |
| Healthchecks factorisés | ancre `x-healthcheck-defaults` (interval, timeout, retries, start_period) fusionnée avec `<<: *healthcheck-defaults` ; chaque service ne définit que son `test` |
| Démarrage ordonné | `depends_on` avec `condition: service_healthy` : api et worker attendent db et redis **sains** |
| Secret PostgreSQL | `secrets: db_password` (fichier `./secrets/db_password.txt`, gitignoré, généré par `make secrets`) ; `POSTGRES_PASSWORD_FILE` côté base |
| Volumes | `pgdata`, `redisdata` (nommés) ; `db/init.sql` monté dans `/docker-entrypoint-initdb.d/` |
| Reverse proxy | Traefik piloté par labels : `Host(api.localhost)` → API, healthcheck de backend `/health` ; seul le port 80 est publié |
| Logs et redémarrage | ancre `x-logging` (json-file, 10 Mo x 3) et `restart: unless-stopped` sur chaque service |
| Outils à la demande | profil `tools` (adminer sur `adminer.localhost`) et profil `ops` (service `migrate` à usage unique) |

### Construire `DATABASE_URL` à partir du secret sans modifier le code

L'API et le worker ne lisent que `DATABASE_URL`. Le mot de passe est disponible dans le conteneur sous forme de fichier (`/run/secrets/db_password`). On remplace l'`entrypoint` par un petit shell qui construit l'URL **au démarrage**, puis fait `exec` de la commande du service :

```yaml
x-db-url-entrypoint: &db-url-entrypoint
  - /bin/sh
  - -c
  - 'export DATABASE_URL="postgres://$${POSTGRES_USER}:$$(cat /run/secrets/db_password)@db:5432/$${POSTGRES_DB}"; exec "$$@"'
  - --
```

- `$$` échappe le `$` pour Compose : la substitution est faite par le shell du conteneur, pas au moment de `docker compose config`.
- `exec "$@"` remplace le shell par la commande (`node src/server.js` ou `python -m worker.main`) : l'application reste PID 1 et reçoit `SIGTERM` (acquis du TP01).
- La commande reste dans `command:`, donc la surcharge dev peut la changer (`node --watch ...`) sans redéfinir l'entrypoint.
- Le mot de passe est généré avec `openssl rand -hex 24` : uniquement des caractères hexadécimaux, donc pas d'encodage d'URL à gérer.

### Vérification

```bash
$ docker compose -f compose.yml config      # extrait
name: shop
services:
  api:
    build:
      context: /Users/theosauval/Desktop/exercices-docker/exo-12/apps/shopapi
    command: [node, src/server.js]
    depends_on:
      db:    { condition: service_healthy, required: true }
      redis: { condition: service_healthy, required: true }
    entrypoint:
      - /bin/sh
      - -c
      - export DATABASE_URL="postgres://$${POSTGRES_USER}:$$(cat /run/secrets/db_password)@db:5432/$${POSTGRES_DB}"; exec "$$@"
      - --
    healthcheck:
      test: [CMD, node, -e, "fetch('http://127.0.0.1:3000/ready')..."]
      timeout: 3s
      interval: 5s
      retries: 10
      start_period: 10s
    ...

$ docker compose -f compose.yml config --services
db redis worker api proxy
$ docker compose -f compose.yml --profile tools --profile ops config --services
db migrate proxy redis worker adminer api
```

```bash
$ time docker compose -f compose.yml up -d --build --wait
real 33.986 s

$ docker compose -f compose.yml ps
NAME            IMAGE                  SERVICE   STATUS                    PORTS
shop-api-1      shopapi:local          api       Up 5 seconds (healthy)    3000/tcp
shop-db-1       postgres:16.4-alpine   db        Up 11 seconds (healthy)
shop-proxy-1    traefik:v3.1           proxy     Up 11 seconds (healthy)   0.0.0.0:80->80/tcp
shop-redis-1    redis:7.4-alpine       redis     Up 11 seconds (healthy)
shop-worker-1   shop-worker:local      worker    Up 5 seconds (healthy)
```

Tous les services sont `healthy` quand `up --wait` rend la main. L'API et le worker ont démarré 6 s après db et redis : c'est `depends_on: service_healthy` qui les a fait attendre, sans `sleep`.

**Isolation réseau :**

```bash
$ docker network inspect shop_front shop_back --format '{{.Name}} internal={{.Internal}} containers=...'
shop_front internal=false containers=shop-proxy-1 shop-api-1
shop_back  internal=true  containers=shop-worker-1 shop-db-1 shop-redis-1 shop-api-1

$ docker compose -f compose.yml port db 5432
no port 5432/tcp for container shop-db-1
$ nc -z localhost 6379 || echo 'port 6379 fermé sur hôte'
port 6379 fermé sur hôte

$ docker compose exec -T db wget -T 3 -qO- http://example.com
wget: bad address 'example.com'                          # db -> internet bloqué
$ docker compose exec -T worker python -c "urllib.request.urlopen('http://example.com')"
urllib.error.URLError: <urlopen error [Errno -3] Temporary failure in name resolution>   # worker -> internet bloqué
```

La base et Redis ne publient aucun port et ne peuvent même pas sortir sur Internet : `back` est `internal`, sans passerelle. (Le port 5432 de l'hôte répond, mais c'est le PostgreSQL local de la machine, pas celui de la stack : `docker compose port` confirme qu'aucun port n'est publié.)

**Accès via Traefik uniquement :**

```bash
$ curl -s http://api.localhost/
{"service":"shopapi","version":"dev"}
$ curl -s http://api.localhost/ready
{"status":"ready","checks":{"db":"ok","redis":"ok"}}
$ curl -s -o /dev/null -w '%{http_code}\n' http://localhost/
404                                                      # pas de route sans le bon Host
```

**Secret :**

```bash
$ docker compose exec -T api env | grep -iE 'pass|database' || echo 'aucune variable mot de passe/DATABASE_URL'
aucune variable mot de passe/DATABASE_URL dans env (exec)

$ docker inspect shop-api-1 --format '{{json .Config.Env}}' | jq .
["REDIS_URL=redis://redis:6379", "LOG_LEVEL=info", "POSTGRES_USER=shop", "POSTGRES_DB=shop",
 "PATH=...", "NODE_VERSION=20.20.2", "YARN_VERSION=1.22.22", "NODE_ENV=production", "APP_VERSION=dev", "PORT=3000"]

$ docker compose exec -T api sh -c 'tr "\0" "\n" < /proc/1/environ | grep DATABASE_URL'   # mot de passe masqué ici
DATABASE_URL=postgres://shop:****@db:5432/shop

$ docker compose exec -T api ls -l /run/secrets/
-rw-r--r--    1 node     node            49 Oct 29 13:37 db_password
```

Le mot de passe n'apparaît ni dans les fichiers versionnés, ni dans `docker inspect`, ni dans un `docker exec env` : il n'existe que dans le fichier secret et dans l'environnement du processus applicatif (PID 1). Limite : quelqu'un qui peut faire `docker exec` dans le conteneur peut lire `/proc/1/environ` ou le fichier secret. C'est le compromis accepté pour ne pas modifier le code ; la vraie solution est que l'application lise `*_FILE` elle-même.

**Migration à la demande (profil `ops`) :**

```bash
$ MIGRATION=002-add-sku.sql docker compose -f compose.yml run --rm migrate
BEGIN
ALTER TABLE
UPDATE 3
ALTER TABLE
ALTER TABLE
CREATE INDEX
COMMIT

$ docker compose -f compose.yml run --rm migrate
MIGRATION non définie (ex: MIGRATION=002-add-sku.sql)        # exit 2

$ docker compose exec -T db psql -U shop -d shop -c 'SELECT id, sku, name FROM products'
 id |    sku    |       name
----+-----------+-------------------
  1 | SKU-00001 | Clavier mécanique
  2 | SKU-00002 | Écran 27"
  3 | SKU-00003 | Souris sans fil

$ docker compose -f compose.yml ps -a --format '{{.Service}} {{.State}}'
api running / db running / proxy running / redis running / worker running      # migrate n'a laissé aucun conteneur
```

> **Leçon apprise pendant le TP05 :** la première version de la migration ajoutait `sku NOT NULL` **sans valeur par défaut**. Le script de seed du TP05, qui insère des produits sans connaître la colonne, a alors échoué (`null value in column "sku" violates not-null constraint`). C'est exactement ce qui arriverait avec l'ancienne version de l'API pendant un déploiement progressif. La migration ajoute maintenant une valeur par défaut, ce qui la rend compatible avec les clients existants (principe *expand / contract*).

**Logs et redémarrage :**

```bash
$ docker inspect shop-api-1 --format 'logging={{.HostConfig.LogConfig.Type}} {{json .HostConfig.LogConfig.Config}} restart={{.HostConfig.RestartPolicy.Name}}'
logging=json-file {"max-file":"3","max-size":"10m"} restart=unless-stopped
```

---

## 3. Surcharge dev `compose.override.yml`

`compose.override.yml` est fusionné automatiquement par `docker compose up` (sans `-f`). Il ajoute :

- **API** : `node --watch src/server.js`, bind mount `./apps/shopapi/src:/app/src:ro`, `LOG_LEVEL=debug`, port `${API_DEBUG_PORT:-3000}` ;
- **Traefik** : dashboard (`TRAEFIK_API_INSECURE=true`) sur `${TRAEFIK_DASHBOARD_PORT:-8080}`, logs DEBUG. La configuration statique de Traefik est faite par **variables d'environnement** dans la base, justement pour que la surcharge puisse en ajouter (une liste `command:` serait remplacée en entier) ;
- **db** : port `${DB_DEBUG_PORT:-5432}`.

**Piège rencontré :** `back` est `internal: true`. Docker ne publie pas de port pour un conteneur qui n'est que sur un réseau sans passerelle : le `ports:` de la base serait ignoré. La surcharge dev ajoute donc la base à un réseau dédié `dbdebug` (non interne), **uniquement en dev**.

```bash
$ docker compose up -d --wait
real 14.748 s

$ docker compose ps --format 'table {{.Service}}\t{{.Status}}\t{{.Ports}}'
SERVICE   STATUS                    PORTS
api       Up 5 seconds (healthy)    0.0.0.0:3005->3000/tcp
db        Up 11 seconds (healthy)   0.0.0.0:5434->5432/tcp
proxy     Up 11 seconds (healthy)   0.0.0.0:80->80/tcp, 0.0.0.0:8081->8080/tcp
redis     Up 48 seconds (healthy)
worker    Up 5 seconds (healthy)

$ curl -s localhost:3005/
{"service":"shopapi","version":"dev"}
$ curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8081/dashboard/
200
$ nc -z localhost 5434
Connection to localhost port 5434 [tcp/sgi-arrayd] succeeded!

$ docker inspect shop-api-1 --format '{{json .Config.Cmd}} {{range .Mounts}}{{.Type}}:{{.Source}}->{{.Destination}} {{end}}'
["node","--watch","src/server.js"] bind:/Users/theosauval/Desktop/exercices-docker/exo-12/apps/shopapi/src->/app/src bind:.../secrets/db_password.txt->/run/secrets/db_password
```

**Rechargement :** ajout d'une ligne de commentaire dans `apps/shopapi/src/server.js` sur l'hôte :

```bash
$ docker compose logs --no-log-prefix --since 10s api
{"level":30,"pid":13,"port":"3000","msg":"shopapi démarré"}
Restarting 'src/server.js'
{"level":30,"pid":13,"signal":"SIGTERM","msg":"arrêt demandé"}
{"level":30,"pid":36,"port":"3000","msg":"shopapi démarré"}
```

`node --watch` voit la modification à travers le bind mount, envoie `SIGTERM` à l'ancien processus (arrêt propre via le handler du code) et relance le serveur (nouveau pid 36), sans reconstruire l'image ni recréer le conteneur.

---

## 4. Surcharge prod `compose.prod.yml`

Pour le test, les images sont poussées dans un registre local `registry:2` sur `localhost:5050` (le registre du TP03 n'a pas été fait ; le port 5000 est pris par AirPlay sur macOS). `REGISTRY` et `VERSION` viennent de `.env`.

```bash
$ docker run -d --name tp-registry -p 5050:5000 registry:2
$ docker tag shopapi:local localhost:5050/shopapi:1.4.2 && docker push -q localhost:5050/shopapi:1.4.2
$ docker tag shop-worker:local localhost:5050/shop-worker:1.4.2 && docker push -q localhost:5050/shop-worker:1.4.2
$ curl -s localhost:5050/v2/_catalog
{"repositories":["shop-worker","shopapi"]}
```

### Contenu

| Exigence | Mise en oeuvre |
|---|---|
| Pas de `build` | `build: !reset null` supprime la clé héritée de la base ; `image: ${REGISTRY:?...}/shopapi:${VERSION:?...}` |
| Réplicas | `deploy.replicas: 2` pour l'API (pas de `container_name` ni de port publié, sinon conflit) |
| Limites | `deploy.resources.limits` (cpus, memory) sur chaque service, réservation mémoire pour l'API |
| Durcissement | ancre `x-hardening` : `read_only: true`, `tmpfs: /tmp`, `cap_drop: [ALL]`, `no-new-privileges` (api, worker) |
| Base | `no-new-privileges` et limites, mais **pas** `cap_drop: ALL` : l'entrypoint postgres a besoin de `CHOWN`, `SETUID`, `SETGID`, `DAC_OVERRIDE`, `FOWNER` |
| Pas de debug | le fichier override n'est pas chargé quand on passe `-f` explicitement : ni ports 3005/5434, ni dashboard |

```bash
$ docker compose -f compose.yml -f compose.prod.yml config | grep -nE '^  [a-z]+:|image:|build:|replicas|read_only|published'
3:  api:
17:      replicas: 2
44:    image: localhost:5050/shopapi:1.4.2
60:    read_only: true
69:  db:
87:    image: postgres:16.4-alpine
113:  proxy:
138:    image: traefik:v3.1
149:        published: "80"
159:  redis:
178:    image: redis:7.4-alpine
194:  worker:
233:    image: localhost:5050/shop-worker:1.4.2
241:    read_only: true
```

Aucune ligne `build:` : `!reset` a bien supprimé la clé. Le seul port publié est le 80.

```bash
$ docker compose -f compose.yml -f compose.prod.yml pull api worker
$ time docker compose -f compose.yml -f compose.prod.yml up -d --wait
real 11.956 s

$ docker compose -f compose.yml -f compose.prod.yml ps
NAME            IMAGE                              STATUS                    PORTS
shop-api-1      localhost:5050/shopapi:1.4.2       Up 5 seconds (healthy)    3000/tcp
shop-api-2      localhost:5050/shopapi:1.4.2       Up 5 seconds (healthy)    3000/tcp
shop-db-1       postgres:16.4-alpine               Up 11 seconds (healthy)
shop-proxy-1    traefik:v3.1                       Up 11 seconds (healthy)   0.0.0.0:80->80/tcp
shop-redis-1    redis:7.4-alpine                   Up 11 seconds (healthy)
shop-worker-1   localhost:5050/shop-worker:1.4.2   Up 6 seconds (healthy)
```

### Répartition de charge

Traefik répartit en round-robin pondéré entre les réplicas sains. Vérification par les **logs d'accès** JSON de Traefik (`TRAEFIK_ACCESSLOG_FORMAT=json`), champ `ServiceURL` = adresse du réplica qui a servi la requête :

```bash
$ docker inspect $(docker compose -f compose.yml -f compose.prod.yml ps -q api) --format '{{.Name}} {{range $k,$v := .NetworkSettings.Networks}}{{$k}}={{$v.IPAddress}} {{end}}'
/shop-api-1 shop_back=172.26.0.6 shop_front=172.27.0.4
/shop-api-2 shop_back=172.26.0.4 shop_front=172.27.0.3

$ for i in $(seq 1 20); do curl -s -o /dev/null http://api.localhost/health; done
$ docker compose logs --no-log-prefix --since <début du test> proxy | grep '"RouterName":"api@docker"' | jq -r .ServiceURL | sort | uniq -c
  10 http://172.27.0.3:3000
  10 http://172.27.0.4:3000

$ ... | head -2 | jq -c '{RequestPath, ServiceURL, DownstreamStatus, Duration}'
{"RequestPath":"/health","ServiceURL":"http://172.27.0.4:3000","DownstreamStatus":200,"Duration":1218042}
{"RequestPath":"/health","ServiceURL":"http://172.27.0.3:3000","DownstreamStatus":200,"Duration":1241750}
```

20 requêtes, exactement 10 par réplica, en alternance. Traefik joint les réplicas par leur adresse sur `front` (`172.27.x`), jamais sur `back`.

> Un premier essai, lancé une seconde après `up --wait`, avait envoyé les 12 requêtes au même réplica : Traefik ajoute un conteneur à la répartition à réception de l'événement Docker où il devient `healthy`, et le second n'était pas encore pris en compte. Après une dizaine de secondes, la répartition est égale. En production, c'est le healthcheck de backend (`loadbalancer.healthcheck.path=/health`) qui retire ou réintègre un réplica.

### Durcissement

```bash
$ docker inspect shop-api-1 --format 'ReadonlyRootfs=... CapDrop=... SecurityOpt=... Memory=... NanoCpus=... Tmpfs=...'
ReadonlyRootfs=true CapDrop=[ALL] SecurityOpt=[no-new-privileges:true] Memory=268435456 NanoCpus=500000000 Tmpfs={"/tmp":""}

$ docker compose -f compose.yml -f compose.prod.yml exec -T api touch /app/x
touch: /app/x: Read-only file system
$ docker compose -f compose.yml -f compose.prod.yml exec -T api sh -c 'touch /tmp/x && echo /tmp inscriptible'
/tmp inscriptible

$ docker stats --no-stream
NAME            CPU %     MEM USAGE / LIMIT
shop-api-2      5.00%     19.12MiB / 256MiB
shop-worker-1   0.01%     23.16MiB / 128MiB
shop-api-1      0.23%     22.21MiB / 256MiB
shop-db-1       0.81%     22.51MiB / 512MiB
shop-proxy-1    0.06%     40.6MiB / 128MiB
shop-redis-1    0.57%     9.625MiB / 128MiB

$ curl -s -o /dev/null -w '%{http_code}\n' --max-time 3 http://localhost:8081/dashboard/
000                      # pas de dashboard
$ nc -z localhost 3005 || echo 'port 3005 fermé'; nc -z localhost 5434 || echo 'port 5434 fermé'
port 3005 fermé
port 5434 fermé

$ COMPOSE='docker compose -f compose.yml -f compose.prod.yml' ./smoke-test.sh
== Smoke test sur http://api.localhost
  OK   /ready -> {"status":"ready","checks":{"db":"ok","redis":"ok"}}
  OK   /products -> 3 produits, X-Cache: HIT
  OK   POST /orders -> 201 {"id":1793281234385,"productId":1,"quantity":2,"status":"pending",...}
  OK   commande traitée par le worker -> confirmed
== 4 OK, 0 FAIL
```

L'API tourne avec un système de fichiers en lecture seule (seul `/tmp` est inscriptible, en mémoire), sans aucune capability Linux, et ne peut pas gagner de privilèges. Elle fonctionne quand même : le code n'écrit rien sur disque.

### `--scale api=3` puis `up -d`

```bash
$ docker compose -f compose.yml -f compose.prod.yml up -d --scale api=3 --wait
$ docker compose -f compose.yml -f compose.prod.yml ps api
shop-api-1 Up 16 seconds (healthy)
shop-api-2 Up 16 seconds (healthy)
shop-api-3 Up 5 seconds (healthy)

$ docker compose -f compose.yml -f compose.prod.yml up -d --wait
$ docker compose -f compose.yml -f compose.prod.yml ps api
shop-api-1 Up 18 seconds (healthy)
shop-api-2 Up 18 seconds (healthy)
```

`--scale` est une modification **impérative et temporaire** : il ajoute un 3e réplica (que Traefik découvre automatiquement grâce aux labels). Mais le prochain `docker compose up -d` réapplique l'état **déclaré** dans les fichiers (`deploy.replicas: 2`) et supprime le réplica en trop. Pour changer durablement le nombre de réplicas, il faut modifier `compose.prod.yml` (ou passer `--scale` à chaque fois). C'est le même principe de réconciliation que sous Kubernetes.

---

## 5. Outillage d'équipe

### `Makefile`

```bash
$ make help
  help         Affiche cette aide
  init         Prépare .env et le secret (une seule fois)
  secrets      Génère le mot de passe PostgreSQL s'il n'existe pas
  up           Démarre la stack de dev et attend qu'elle soit saine
  down         Arrête la stack (les volumes sont conservés)
  logs         Suit les logs
  ps           État des services
  tools        Démarre adminer (adminer.localhost)
  prod-config  Affiche le compose prod résolu
  prod-up      Démarre la stack de prod (images du registre)
  prod-down    Arrête la stack de prod
  migrate      Applique une migration : make migrate M=002-add-sku.sql
  test         Smoke test de la stack démarrée
```

`make up` / `make prod-up` dépendent de `init`, qui crée `.env` depuis `.env.example` et génère le secret **s'ils n'existent pas** : un nouvel arrivant n'a qu'une commande à taper.

```bash
$ make secrets
secret généré : secrets/db_password.txt (non versionné)

$ make migrate M=002-add-sku.sql            # rejouée : la migration est idempotente
# (sortie obtenue avec la première version de la migration, avant l'ajout de la valeur par défaut)
MIGRATION=002-add-sku.sql docker compose run --rm migrate
BEGIN
NOTICE:  column "sku" of relation "products" already exists, skipping
ALTER TABLE
UPDATE 0
ALTER TABLE
NOTICE:  relation "products_sku_key" already exists, skipping
CREATE INDEX
COMMIT
```

### `smoke-test.sh`

Quatre vérifications à travers Traefik : `/ready` (base et Redis OK), `/products` avec `X-Cache: HIT` au 2e appel, `POST /orders`, puis lecture en base jusqu'à ce que le worker ait passé la commande en `confirmed`. Il fonctionne en dev et en prod (variable `COMPOSE`), et attend jusqu'à 30 s que Traefik ait ajouté la route après un redémarrage.

```bash
$ make test
./smoke-test.sh
== Smoke test sur http://api.localhost
  OK   /ready -> {"status":"ready","checks":{"db":"ok","redis":"ok"}}
  OK   /products -> 3 produits, X-Cache: HIT
  OK   POST /orders -> 201 {"id":1793281148143,"productId":1,"quantity":2,"status":"pending",...}
  OK   commande traitée par le worker -> confirmed
== 4 OK, 0 FAIL
```

Ce test valide toute la chaîne : Traefik → API → PostgreSQL et Redis (cache) → file Redis → worker → PostgreSQL.

### Dockerfile du worker

Le TP02 n'ayant pas été fait, `apps/shop-worker/Dockerfile` a été écrit pour ce TP sur le modèle du TP01 : multi-stage `builder` (virtualenv) → `test` (`ruff check` + `pytest`, bloquant) → `runtime` (`python:3.12.7-slim-bookworm`), utilisateur non-root 10001, `HEALTHCHECK` sur le port de métriques 9100, dépendances depuis pypi.org sans aucun identifiant dans l'image. hadolint : aucune sortie. L'ancien Dockerfile est gardé dans `Dockerfile.legacy`.

---

## Bonus

### B1 : `docker compose watch`

Fichier `compose.watch.yml` : au lieu de monter le code en bind mount, Compose **surveille** les fichiers de l'hôte et agit :

```yaml
develop:
  watch:
    - action: sync            # copie le fichier modifié dans le conteneur, node --watch recharge
      path: ./apps/shopapi/src
      target: /app/src
    - action: rebuild         # nouvelles dépendances : il faut reconstruire l'image
      path: ./apps/shopapi/package.json
```

**Premier essai : échec.**

```
Syncing service "api" after 1 changes were detected
level=warning msg="Error handling changed files for service api: copying files to 824c43ce...: Error response from daemon: getent unable to find entry \"1000:1000\" in passwd database"
```

Compose attribue les fichiers copiés à l'utilisateur du conteneur, qu'il résout avec `getent` en prenant la valeur de `USER` comme un **nom** : `1000:1000` (forme numérique choisie au TP01 pour Kubernetes) n'est pas un nom d'utilisateur. Correction dans la surcharge watch uniquement : `user: node` (même uid 1000).

**Après correction :**

```bash
$ docker compose -f compose.yml -f compose.watch.yml up -d --wait api
$ docker compose -f compose.yml -f compose.watch.yml watch --no-up &
Watch enabled
$ echo "// watch test 1793282340" >> apps/shopapi/src/server.js
Syncing service "api" after 1 changes were detected

$ docker compose -f compose.yml -f compose.watch.yml exec -T api tail -1 src/server.js
// watch test 1793282340
$ docker compose -f compose.yml -f compose.watch.yml logs --no-log-prefix api
{"pid":13,"port":"3000","msg":"shopapi démarré"}
Restarting 'src/server.js'
{"pid":13,"signal":"SIGTERM","msg":"arrêt demandé"}
{"pid":48,"port":"3000","msg":"shopapi démarré"}
```

| | `sync` | `rebuild` |
|---|---|---|
| Effet | copie les fichiers modifiés dans le conteneur en cours | reconstruit l'image et recrée le conteneur |
| Durée | instantané | durée d'un build (cache compris) |
| Pour | code source interprété (JS, Python) avec rechargement par l'application | dépendances (`package.json`, lockfile), Dockerfile, code compilé |

Avantages par rapport au bind mount : pas de partage de fichiers macOS ↔ VM pendant l'exécution (le conteneur lit ses fichiers sur le disque de la VM, voir le benchmark du TP05), et les fichiers ignorés par `.dockerignore` (`node_modules` local de l'hôte) ne viennent pas écraser ceux de l'image. Inconvénient : synchronisation dans un seul sens (hôte → conteneur), et une commande `watch` à laisser tourner.

### B2 : TLS local avec mkcert

Non réalisé : il nécessite d'installer `mkcert` et sa CA racine dans le trousseau macOS. Principe : `mkcert -install && mkcert "*.localhost"`, monter les certificats dans Traefik (`tls.certificates` dans une configuration dynamique de type fichier), ajouter un entrypoint `websecure` sur `:443` et une redirection `web → websecure` (`TRAEFIK_ENTRYPOINTS_WEB_HTTP_REDIRECTIONS_ENTRYPOINT_TO=websecure`).

### B3 : adminer sur un réseau interne

```bash
$ docker compose -f compose.yml --profile tools up -d --wait adminer
$ curl -s -o /dev/null -w 'adminer.localhost -> %{http_code}\n' http://adminer.localhost/
adminer.localhost -> 200
$ docker inspect shop-adminer-1 --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{$v.IPAddress}}  {{end}}'
shop_back 172.26.0.6  shop_front 172.27.0.4
```

Oui, adminer est joignable via Traefik. `internal: true` empêche seulement le réseau `back` d'avoir une passerelle vers l'extérieur (pas d'accès Internet, pas de ports publiés). Mais adminer est **aussi** sur `front`, comme l'API : Traefik le joint par son adresse sur `front` (`TRAEFIK_PROVIDERS_DOCKER_NETWORK=shop_front`), et adminer joint la base par son adresse sur `back`. Le conteneur relie les deux réseaux. C'est voulu ici, mais c'est aussi la raison pour laquelle un outil d'admin ne doit tourner qu'à la demande (profil) : tant qu'il tourne, il est un pont entre la partie exposée et la base.

### B4 : variables obligatoires

```bash
$ REGISTRY= docker compose -f compose.yml -f compose.prod.yml config -q
error while interpolating services.api.image: required variable REGISTRY is missing a value: REGISTRY doit être défini
$ VERSION= docker compose -f compose.yml -f compose.prod.yml config -q
error while interpolating services.api.image: required variable VERSION is missing a value: VERSION doit être défini
```

Avec `${VAR:?message}`, Compose refuse de démarrer (code de sortie 15) au lieu de tirer une image `/shopapi:` invalide ou, pire, une image `latest` d'un autre registre.

### B5 : découper le compose

`include:` (Compose 2.20+) permet d'importer un autre fichier Compose **avec son propre dossier de référence** : par exemple une équipe data maintient `observability/compose.yml` et l'équipe applicative fait `include: [observability/compose.yml]`. Contrairement à `-f a.yml -f b.yml` (fusion clé par clé), un fichier inclus reste autonome et un conflit de nom de service est une erreur. `docker compose alpha publish` pousse un fichier Compose comme artefact OCI dans un registre, pour le partager et le versionner comme une image. Non testés ici.
