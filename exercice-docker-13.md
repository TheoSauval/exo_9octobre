# Exercice Docker #13 (TP05) - Données : persistance, sauvegarde, restauration, montée de version

**Objectif :** après l'incident `docker compose down -v` en préprod chez *Shop SAS* : comprendre où vivent les données, livrer une procédure de sauvegarde/restauration **testée**, et monter PostgreSQL de 14 à 16 sans perte avec retour arrière possible.

Fichiers : dossier `exo-13/`

```
exo-13/
├── backup.sh                  # dump logique horodaté (+ sauvegarde brute avec --raw), rétention
├── restore.sh                 # restauration logique ou brute, avec checksum
├── upgrade-pg.sh              # montée de version 14 -> 16 avec vérification
├── compose.backup.yml         # sidecar de sauvegarde planifiée pour la stack du TP04
├── compose.yml                # base legacy PostgreSQL 14 (fournie)
├── compose.pg16.yml           # PG16 sur un nouveau volume (utilisé par upgrade-pg.sh)
├── compose.pg16-tag-only.yml  # contre-exemple : tag changé sur l'ancien volume
└── seed.sh                    # ≈ 100 000 commandes (fourni)
```

Les étapes 1, 2 et 4 utilisent la stack du TP04 (`exo-12/`, projet `shop`). L'étape 3 utilise la base legacy fournie (projet `shopdata`). Aucun client `psql` n'est installé sur l'hôte : tout passe par des conteneurs.

Environnement : Docker Desktop 27.3.1, macOS Apple Silicon (`linux/arm64`), driver de stockage `overlay2`.

---

## 1. Anatomie du stockage

```bash
$ docker inspect $(docker compose ps -q db) --format '{{json .Mounts}}' | jq
[
  { "Type": "bind",   "Source": "/Users/theosauval/Desktop/exercices-docker/exo-12/db/init.sql",
    "Destination": "/docker-entrypoint-initdb.d/001-init.sql", "RW": false },
  { "Type": "volume", "Name": "shop_pgdata", "Source": "/var/lib/docker/volumes/shop_pgdata/_data",
    "Destination": "/var/lib/postgresql/data", "Driver": "local", "RW": true },
  { "Type": "bind",   "Source": "/host_mnt/Users/theosauval/Desktop/exercices-docker/exo-12/secrets/db_password.txt",
    "Destination": "/run/secrets/db_password", "RW": false }
]

$ docker volume inspect shop_pgdata
[{ "CreatedAt": "2026-10-29T13:38:10Z", "Driver": "local",
   "Labels": { "com.docker.compose.project": "shop", "com.docker.compose.version": "2.30.3", "com.docker.compose.volume": "pgdata" },
   "Mountpoint": "/var/lib/docker/volumes/shop_pgdata/_data", "Name": "shop_pgdata", "Scope": "local" }]
```

Trois montages : `init.sql` et le secret sont des **bind mounts** (fichiers de l'hôte, en lecture seule), les données sont dans le **volume nommé** `shop_pgdata`. Sur Docker Desktop, `/var/lib/docker/...` est dans la VM Linux de Docker, pas sur le disque macOS directement. Le préfixe `/host_mnt/` du secret montre le partage de fichiers entre macOS et la VM.

`docker system df -v` (extrait) liste les images, conteneurs, volumes et le cache de build, avec la taille partagée entre images (`SHARED SIZE`) : par exemple `shopapi:local` fait 143 Mo dont seulement 8,56 Mo uniques, le reste étant partagé avec les autres images `node:20-alpine`.

### Couche inscriptible vs volume

```bash
$ docker inspect shop-db-1 --format 'GraphDriver={{.GraphDriver.Name}} UpperDir={{.GraphDriver.Data.UpperDir}}'
GraphDriver=overlay2 UpperDir=/var/lib/docker/overlay2/e78f48474b5a.../diff

$ docker compose exec -T db touch /tmp/x && docker diff shop-db-1
C /docker-entrypoint-initdb.d
A /docker-entrypoint-initdb.d/001-init.sql
C /run
C /run/postgresql
A /run/postgresql/.s.PGSQL.5432
A /run/postgresql/.s.PGSQL.5432.lock
A /run/secrets
A /run/secrets/db_password
C /tmp
A /tmp/x

$ docker compose exec -T db psql -U shop -d shop -c 'CREATE TABLE marker(v text); INSERT INTO marker VALUES (now()::text)'
$ docker diff shop-db-1 | grep -c lib/postgresql
0
```

- `/tmp/x` apparaît dans `docker diff` : il est écrit dans la **couche inscriptible** du conteneur (`UpperDir` d'overlay2). Elle disparaît avec le conteneur (`docker rm`, `docker compose down`, recréation après un changement d'image).
- Une écriture en base (table créée, ligne insérée) ne donne **aucune** ligne sous `/var/lib/postgresql` dans `docker diff` : ces fichiers sont dans le **volume**, en dehors du système de fichiers en couches, donc indépendants du cycle de vie du conteneur.
- Les points de montage (`/docker-entrypoint-initdb.d/001-init.sql`, `/run/secrets/db_password`) apparaissent comme ajoutés parce que Docker crée le fichier cible dans la couche avant d'y monter la source.

### Cycle de vie de `pgdata`

Testé sur une **copie** de la stack : `docker compose -p shopcopy -f compose.yml` (projet différent, donc volume `shopcopy_pgdata`, service `db` seul).

```bash
$ docker compose -p shopcopy -f compose.yml up -d --wait db
$ docker compose -p shopcopy -f compose.yml exec -T db psql -U shop -d shop -qc "CREATE TABLE t(v text); INSERT INTO t VALUES ('donnee-test')"
$ docker volume ls --filter name=shopcopy
local     shopcopy_pgdata

# down : conteneurs et réseau supprimés, volume conservé
$ docker compose -p shopcopy -f compose.yml down && docker volume ls --filter name=shopcopy
local     shopcopy_pgdata
$ docker compose -p shopcopy -f compose.yml up -d --wait db && ... psql -tAc 'SELECT v FROM t'
donnee-test

# rm : conteneur supprimé, volume conservé
$ docker compose -p shopcopy -f compose.yml rm -sf db && docker volume ls --filter name=shopcopy
local     shopcopy_pgdata

# volume prune (sans -a) : ne supprime que les volumes ANONYMES non utilisés
$ docker volume prune -f --filter label=com.docker.compose.project=shopcopy
Total reclaimed space: 0B
local     shopcopy_pgdata

# volume prune -a : supprime aussi les volumes NOMMÉS non utilisés
$ docker volume prune -af --filter label=com.docker.compose.project=shopcopy
Deleted Volumes:
shopcopy_pgdata
Total reclaimed space: 47.95MB
$ docker compose -p shopcopy -f compose.yml up -d --wait db && ... psql -tAc 'SELECT count(*) FROM t'
ERROR:  relation "t" does not exist                     # nouvelle base vide : données perdues

# down -v : supprime aussi les volumes du projet
$ docker compose -p shopcopy -f compose.yml down -v && docker volume ls --filter name=shopcopy
 Volume shopcopy_redisdata  Removing
 Volume shopcopy_pgdata  Removing
DRIVER    VOLUME NAME                                   # plus rien
```

| Commande | Conteneur | Volume `pgdata` |
|---|---|---|
| `docker compose down` | supprimé | **conservé** |
| `docker compose rm` | supprimé | **conservé** |
| `docker volume prune` | - | **conservé** (nommé ; depuis Docker 23 seuls les anonymes sont supprimés) |
| `docker volume prune -a` | - | **supprimé** s'il n'est utilisé par aucun conteneur |
| `docker compose down -v` | supprimé | **supprimé** (c'est l'incident de préprod) |

Le filtre `--filter label=com.docker.compose.project=shopcopy` limite le `prune` à la copie de test : sans lui, `docker volume prune -a` aurait supprimé **tous** les volumes inutilisés de la machine, y compris ceux d'autres projets arrêtés à ce moment-là.

### Volume anonyme

```bash
$ docker run -d --name anon -e POSTGRES_PASSWORD=x postgres:16.4-alpine
$ docker inspect anon --format '{{range .Mounts}}{{.Type}} {{.Name}} -> {{.Destination}}{{end}}'
volume 9ce45bec617cb2e8103d653bfcc2351821f808846bae6f1f1b1cb4c637fba5af -> /var/lib/postgresql/data

$ docker rm -f anon && docker volume ls --filter name=9ce45bec617c...
local     9ce45bec617cb2e8103d653bfcc2351821f808846bae6f1f1b1cb4c637fba5af      # toujours là

$ docker run -d --name anon -e POSTGRES_PASSWORD=x postgres:16.4-alpine
$ docker rm -fv anon && docker volume ls --filter name=4d905b8706b8... | tail -n +2 | wc -l
0                                                                           # supprimé avec -v
```

Sans `-v`, les données vont quand même dans un volume : l'image déclare `VOLUME /var/lib/postgresql/data`, Docker crée donc un **volume anonyme** au nom aléatoire. Au `docker rm`, il reste (orphelin) ; avec `docker rm -v`, il est supprimé.

**Pourquoi c'est un piège :**
- on croit que les données sont dans le conteneur, alors qu'elles sont dans un volume que personne ne sait identifier : un nouveau `docker run` crée un **autre** volume vide, la base semble « perdue » alors qu'elle traîne, orpheline ;
- les volumes orphelins s'accumulent et remplissent le disque ;
- le premier `docker volume prune` (qui supprime justement les volumes anonymes inutilisés) les efface définitivement ;
- `docker rm -v` ou `docker compose down -v`, souvent tapés « pour nettoyer », suppriment les données sans prévenir.

Règle : toujours monter un **volume nommé** explicite pour les données d'une base.

### Bind mount, volume nommé, tmpfs

Mesure sur Docker Desktop (macOS, VirtioFS) : écriture de 5 000 petits fichiers puis de 200 Mo avec `fsync`, dans un conteneur `alpine`, selon le type de montage de `/t`.

```bash
$ docker run --rm -v ~/Desktop/tp0405-run/bindtest:/t alpine:3.20 sh -c '...'     # bind mount
5000 petits fichiers  real 0m 5.41s
200 Mo fsync          real 0m 0.56s
$ docker run --rm -v perftest:/t alpine:3.20 sh -c '...'                          # volume nommé
5000 petits fichiers  real 0m 0.10s
200 Mo fsync          real 0m 0.23s
$ docker run --rm --tmpfs /t:size=512m alpine:3.20 sh -c '...'                    # tmpfs
5000 petits fichiers  real 0m 0.02s
200 Mo fsync          real 0m 0.09s
```

| | 5 000 petits fichiers | 200 Mo + fsync |
|---|---|---|
| Bind mount | 5,41 s | 0,56 s |
| Volume nommé | 0,10 s (**54 fois plus rapide**) | 0,23 s |
| tmpfs | 0,02 s | 0,09 s |

| Type | Où sont les données | Quand l'utiliser |
|---|---|---|
| **Volume nommé** | géré par Docker (`/var/lib/docker/volumes`), dans la VM sur Docker Desktop | Données des services : bases, files, uploads. Portable, sauvegardable par conteneur, permissions gérées par l'image, performances natives |
| **Bind mount** | un dossier précis de l'hôte | Code source en dev (rechargement à chaud), fichiers de configuration, scripts d'init, secrets ; quand l'hôte doit lire ou écrire les fichiers directement |
| **tmpfs** | en mémoire, perdu à l'arrêt | Fichiers temporaires d'un conteneur `read_only` (comme `/tmp` de l'API en prod au TP04), données sensibles à ne jamais écrire sur disque, caches jetables |

**Sur Docker Desktop (macOS, Windows)**, les conteneurs tournent dans une VM Linux. Un bind mount traverse le partage de fichiers entre l'hôte et la VM (VirtioFS sur macOS) : chaque opération sur un fichier est traduite, ce qui est nettement plus lent pour beaucoup de petits fichiers (`node_modules`, base de données). Un volume nommé est sur le disque de la VM : vitesse native. Conséquence : ne jamais mettre `PGDATA` ou `node_modules` en bind mount sur Mac ; garder le bind mount pour le code source seulement.

### Pourquoi `init.sql` n'est pas rejoué

```bash
$ docker compose restart db && docker compose logs --no-log-prefix db | grep -i 'skipping initialization'
PostgreSQL Database directory appears to contain a database; Skipping initialization
```

L'entrypoint de l'image `postgres` n'exécute `initdb` puis les scripts de `/docker-entrypoint-initdb.d/` **que si le dossier de données est vide**. Au redémarrage, le volume contient déjà une base : l'initialisation est sautée. C'est voulu (sinon chaque redémarrage écraserait les données), mais ça veut dire qu'une modification de `init.sql` n'est jamais appliquée à une base existante : il faut une **migration** (service `migrate` du TP04).

Pour forcer une réinitialisation : supprimer le volume (`docker compose down -v` ou `docker volume rm shop_pgdata`) puis `docker compose up`. Toutes les données sont perdues, donc à faire uniquement en dev ou après une sauvegarde.

---

## 2. Sauvegarde et restauration

### `backup.sh`

- **dump logique** : `pg_dump -Fc` exécuté dans le conteneur `db` (`docker compose exec -T`), sortie redirigée vers un fichier horodaté sur l'hôte. Écrit d'abord dans `.part` puis renommé : un dump interrompu ne peut pas être pris pour un dump valide ;
- **sauvegarde brute** (`--raw`) : conteneur `alpine` qui monte le volume en **lecture seule** (`-v shop_pgdata:/data:ro`) et fait un `tar czf` ;
- **rétention** : garde les `KEEP` (7 par défaut) plus récents de chaque type.

**Quand la sauvegarde brute est-elle incohérente ?** Si la base tourne pendant la copie. PostgreSQL écrit en continu dans ses fichiers de données et dans le WAL : `tar` copie les fichiers les uns après les autres, à des instants différents. On obtient des pages à moitié écrites et des fichiers qui ne correspondent pas au même instant ; au redémarrage, la récupération peut échouer ou donner une base corrompue.

**Comment la rendre cohérente :**
1. **arrêter la base** pendant la copie (c'est ce que fait `backup.sh --raw` : `stop db` → `tar` → `start db`). Simple et sûr, mais coupure de service ;
2. **sauvegarde à chaud** : `SELECT pg_backup_start('label')`, copie des fichiers, `SELECT pg_backup_stop()`, en archivant aussi les WAL générés pendant la copie. À la restauration, PostgreSQL rejoue ces WAL pour revenir à un état cohérent. C'est ce que fait `pg_basebackup` ;
3. un **snapshot** atomique du système de fichiers (LVM, ZFS, snapshot de disque cloud), équivalent à une coupure de courant que PostgreSQL sait récupérer.

Le dump logique, lui, est toujours cohérent (un seul snapshot MVCC) et fonctionne base en ligne : c'est la sauvegarde principale ; la brute sert à restaurer vite un gros volume.

### `restore.sh`

- **logique** : démarre la base, **arrête l'API et le worker** (plus aucune écriture), `pg_restore --clean --if-exists --no-owner --exit-on-error` (remplace les tables créées par `init.sql` sur une base neuve), `ANALYZE`, redémarre l'API et le worker, affiche nombre de commandes + checksum ;
- **brute** (`--raw`) : arrête api, worker et db, vide le volume, extrait l'archive, redémarre.

### Preuve de la restauration

Seed de la stack du TP04 (après la migration `002-add-sku`, corrigée pour être compatible avec le seed : voir le rendu du TP04), puis sauvegarde, destruction complète, recréation et restauration :

```bash
$ make migrate M=002-add-sku.sql      # (dans exo-12)
$ bash ../exo-13/seed.sh
INSERT 0 500
INSERT 0 100000
 orders |             checksum
--------+----------------------------------
 100000 | 2597e44e8c6ced975a50c1db6fa48bc5        # <- checksum de référence

$ ../exo-13/backup.sh
dump logique : .../exo-13/backups/logical/shop-20261029-145649.dump (1,5M)
$ ../exo-13/backup.sh --raw
dump logique : .../exo-13/backups/logical/shop-20261029-145650.dump (1,5M)
 Container shop-db-1  Stopping / Stopped / Starting / Started
sauvegarde brute : .../exo-13/backups/raw/pgdata-20261029-145650.tar.gz (15M)

# Destruction : l'incident de préprod
$ time docker compose down -v
real 2.334 s
$ docker volume ls --filter name=shop_
DRIVER    VOLUME NAME                                  # plus aucun volume

# Recréation : base neuve, init.sql rejoué, aucune commande
$ time docker compose up -d --wait
real 12.030 s
$ docker compose exec -T db psql -U shop -d shop -tAc "SELECT count(*) || ' ' || coalesce(md5(...),'-') FROM orders"
0 -

# Restauration logique
$ time ../exo-13/restore.sh
restauration de .../exo-13/backups/logical/shop-20261029-145650.dump
 Container shop-worker-1  Stopping
 Container shop-api-1  Stopping
 ...
 Container shop-api-1  Healthy
restauré : 100000 2597e44e8c6ced975a50c1db6fa48bc5   (orders count + checksum)
real 8.343 s

$ docker compose exec -T db psql -U shop -d shop -tAc 'SELECT count(*) FROM products'
503
$ ./smoke-test.sh                      # (dans exo-12) l'application fonctionne sur la base restaurée
  OK   /ready -> {"status":"ready","checks":{"db":"ok","redis":"ok"}}
  OK   /products -> 503 produits, X-Cache: HIT
  OK   POST /orders -> 201 {...}
  OK   commande traitée par le worker -> confirmed
== 4 OK, 0 FAIL
```

| | Commandes | Checksum |
|---|---|---|
| Après le seed | 100 000 | `2597e44e8c6ced975a50c1db6fa48bc5` |
| Après `down -v` + `up` | 0 | - |
| Après `restore.sh` | 100 000 | `2597e44e8c6ced975a50c1db6fa48bc5` |

**Checksums identiques : la restauration est prouvée.** Le smoke test a ensuite ajouté une commande (100 001). La restauration **brute** remet exactement l'état sauvegardé :

```bash
$ docker compose exec -T db psql ... FROM orders
100001 14e22da420cada06310a5fe79987e3ff
$ time ../exo-13/restore.sh --raw ../exo-13/backups/raw/pgdata-20261029-145650.tar.gz
restauré : 100000 2597e44e8c6ced975a50c1db6fa48bc5   (orders count + checksum)
real 15.519 s
```

**Rétention** (testée avec `KEEP=3`, 4 sauvegardes de plus) :

```bash
$ for i in 1 2 3 4; do KEEP=3 ../exo-13/backup.sh; sleep 1; done
dump logique : .../shop-20261029-144219.dump (8,0K)
dump logique : .../shop-20261029-144220.dump (8,0K)
rétention : supprimé logical/shop-20261029-144139.dump
dump logique : .../shop-20261029-144221.dump (8,0K)
rétention : supprimé logical/shop-20261029-144140.dump
dump logique : .../shop-20261029-144222.dump (8,0K)
rétention : supprimé logical/shop-20261029-144219.dump
$ ls -1 ../exo-13/backups/logical
shop-20261029-144220.dump
shop-20261029-144221.dump
shop-20261029-144222.dump
```

(Ce test de rétention date du premier passage, sur une petite base, d'où les 8 Ko.)

### Sidecar de sauvegarde planifiée

`compose.backup.yml` ajoute un service `backup` (`prodrigestivill/postgres-backup-local:16`) à la stack du TP04 : même réseau `back`, même secret (`POSTGRES_PASSWORD_FILE`), dumps dans le volume `pgbackups`, rétention 7 jours / 4 semaines / 6 mois.

```bash
$ BACKUP_SCHEDULE='@every 1m' docker compose -f ../exo-12/compose.yml -f ../exo-12/compose.override.yml -f compose.backup.yml up -d --wait backup
$ docker compose ... ps backup
shop-backup-1   prodrigestivill/postgres-backup-local:16   "/init.sh"   backup   Up 5 minutes (healthy)

$ docker compose ... exec -T backup ls -lR /backups
/backups/daily:
-rw-r--r-- 4 root root 1393 Oct 29 13:48 shop-20261029.sql.gz
lrwxrwxrwx 1 root root   20 Oct 29 13:48 shop-latest.sql.gz -> shop-20261029.sql.gz
/backups/last:
-rw-r--r-- 1 root root 1393 Oct 29 13:43 shop-20261029-134333.sql.gz
-rw-r--r-- 1 root root 1391 Oct 29 13:44 shop-20261029-134433.sql.gz
-rw-r--r-- 1 root root 1391 Oct 29 13:45 shop-20261029-134533.sql.gz
-rw-r--r-- 1 root root 1393 Oct 29 13:46 shop-20261029-134633.sql.gz
-rw-r--r-- 1 root root 1391 Oct 29 13:47 shop-20261029-134733.sql.gz
-rw-r--r-- 4 root root 1393 Oct 29 13:48 shop-20261029-134833.sql.gz
/backups/monthly:
-rw-r--r-- 4 root root 1393 Oct 29 13:48 shop-202610.sql.gz
/backups/weekly:
-rw-r--r-- 4 root root 1393 Oct 29 13:48 shop-202644.sql.gz

$ docker compose ... logs backup | tail -3
2026/10/29 13:48:33 213: Cleaning older files for shop database from db...
2026/10/29 13:48:33 213: SQL backup created successfully
```

Un dump par minute (13:43, 13:44, ... 13:48). Les fichiers `daily`, `weekly`, `monthly` sont des **liens physiques** (compteur de liens à 4) vers le dernier dump : la rétention sur trois horizons ne coûte pas trois fois la place.

Remarque : `up --wait` a mis environ 5 minutes à rendre la main, le temps que le healthcheck intégré de l'image passe à `healthy`. En production on garde `SCHEDULE: "@daily"` (valeur par défaut dans le fichier).

---

## 3. Montée de version majeure PostgreSQL 14 → 16

Base legacy fournie (`compose.yml`, PostgreSQL 14.13, projet `shopdata`), remplie avec `seed.sh` :

```bash
$ docker compose up -d --wait && bash seed.sh
CREATE TABLE
CREATE TABLE
INSERT 0 500
INSERT 0 100000
 orders |             checksum
--------+----------------------------------
 100000 | ef01359ee54cac24054a58fa3a5b4b5d
```

### Changer seulement le tag ne marche pas

```bash
$ docker compose -f compose.yml -f compose.pg16-tag-only.yml up -d db
$ docker compose ps -a db --format '{{.Image}} {{.State}} {{.Status}}'
postgres:16.4-alpine exited Exited (1) 8 seconds ago

$ docker compose logs --no-log-prefix db | tail -4
PostgreSQL Database directory appears to contain a database; Skipping initialization
2026-10-29 13:49:05.980 UTC [1] FATAL:  database files are incompatible with server
2026-10-29 13:49:05.980 UTC [1] DETAIL:  The data directory was initialized by PostgreSQL version 14, which is not compatible with this version 16.4.
```

**Pourquoi :** le format des fichiers de données (catalogue système, structure des pages) change entre versions **majeures**. PostgreSQL 16 refuse un dossier initialisé par la 14 (fichier `PG_VERSION`). Les versions **mineures** (14.12 → 14.13) gardent le même format et se mettent à jour par simple changement d'image. Pour une majeure il faut soit un dump/restore, soit `pg_upgrade`.

Retour sur PG14 : rien n'a été modifié, la base redémarre intacte.

```bash
$ docker compose -f compose.yml up -d --wait db && docker compose exec -T db psql -U shop -d shop -tAc 'SHOW server_version'
14.13
```

### `upgrade-pg.sh`

1. checksum avant (PG14) ;
2. `pg_dumpall --globals-only` (rôles), `pg_dumpall` complet et `pg_dump -Fc` de la base `shop`. Les dumps sont faits avec le **client PostgreSQL 16** (conteneur `postgres:16.4-alpine` sur le réseau du projet) : la règle est d'utiliser le `pg_dump` de la version **cible**, qui sait produire un dump compatible avec elle ;
3. arrêt et suppression du conteneur PG14, **volume `shopdata_pgdata` conservé** ;
4. PG16 sur un **nouveau** volume `shopdata_pgdata16` (`compose.pg16.yml`, avec `volumes: !override`) ;
5. `pg_restore --exit-on-error` puis `vacuumdb --analyze-in-stages` (les statistiques du planificateur ne sont pas dans le dump) ;
6. checksum après, verdict (code de sortie 1 si différent).

```bash
$ time ./upgrade-pg.sh
== 1. État avant
version  : 14.13
checksum : 100000 ef01359ee54cac24054a58fa3a5b4b5d
== 2. Sauvegardes (pg_dump/pg_dumpall en version 16 : le client doit être >= au serveur cible)
-rw-r--r--  4,9M  dumpall.sql
-rw-r--r--  509B  globals.sql
-rw-r--r--  1,5M  shop.dump
== 3. Arrêt de PG14 (volume shopdata_pgdata conservé)
== 4. PG16 sur un NOUVEAU volume (shopdata_pgdata16)
version  : 16.4
== 5. Restauration
== 6. Vérification
checksum avant : 100000 ef01359ee54cac24054a58fa3a5b4b5d
checksum après : 100000 ef01359ee54cac24054a58fa3a5b4b5d
indisponibilité (arrêt PG14 -> PG16 restauré) : 7 s
VERDICT : OK, aucune perte de données
real 10.548 s

$ docker volume ls --filter name=shopdata
local     shopdata_pgdata          # PG14, intact
local     shopdata_pgdata16        # PG16
```

### Retour arrière

Le volume PG14 n'a jamais été modifié. Il suffit d'arrêter PG16 et de relancer PG14 sur l'ancien volume :

```bash
$ docker compose -f compose.yml -f compose.pg16.yml down
$ docker compose -f compose.yml up -d --wait db
$ docker compose exec -T db psql -U shop -d shop -tAc "SELECT version()"
PostgreSQL 14.13 on aarch64-unknown-linux-musl, compiled by gcc (Alpine 13.2.1_git20240309) 13.2.1 20240309, 64-bit
$ docker compose exec -T db psql -U shop -d shop -tAc "SELECT count(*) || ' ' || md5(...) FROM orders"
100000 ef01359ee54cac24054a58fa3a5b4b5d
```

Attention : les écritures faites sur PG16 **après** la bascule ne sont pas dans PG14. Le retour arrière n'est sans perte que s'il est décidé avant la réouverture du trafic (ou en réappliquant ces écritures, par exemple par un dump PG16 → PG14, ce qui n'est pas garanti pour une version plus ancienne). On garde donc le volume PG14 et les dumps tant que la nouvelle version n'est pas validée en production.

### Questions

**`pg_dumpall` vs `pg_dump` :**

| | `pg_dump` | `pg_dumpall` |
|---|---|---|
| Portée | **une** base | **toute** l'instance : toutes les bases + objets globaux |
| Objets globaux (rôles, mots de passe, tablespaces) | non | oui (`--globals-only` pour n'avoir qu'eux) |
| Formats | plain, custom (`-Fc`), directory, tar | SQL texte uniquement |
| Restauration | `pg_restore` : sélective, parallèle (`-j`), réordonnable | `psql -f` : tout ou rien, séquentielle |

Le script fait les deux : `pg_dump -Fc` pour restaurer la base de manière fiable et sélective, `pg_dumpall` (et `--globals-only`) pour ne pas perdre les rôles et pouvoir reconstruire toute l'instance.

**Pourquoi un nouveau volume plutôt qu'écraser :** l'ancien volume **est** le plan de retour arrière. Si la restauration échoue, si le checksum diffère ou si l'application se comporte mal sur PG16, on relance PG14 en quelques secondes sur des données intactes, sans dépendre d'une restauration de sauvegarde. Écraser le volume rendrait l'opération irréversible. Coût : l'espace disque double pendant la migration.

**Réduire l'indisponibilité :** ici 7 s pour 100 000 lignes, mais le dump/restore est proportionnel à la taille de la base (des heures pour des centaines de Go). Options :
- `pg_upgrade --link` : convertit le catalogue et crée des **liens physiques** vers les fichiers de données au lieu de les copier, en quelques secondes quelle que soit la taille. Il faut les binaires des deux versions dans le même conteneur (`tianon/postgres-upgrade:14-to-16`) et les deux dossiers sur le même système de fichiers. Inconvénient : après démarrage de la nouvelle version, l'ancien dossier ne doit plus être utilisé (il partage les fichiers) ; le retour arrière passe par une sauvegarde (voir B1) ;
- **réplication logique** : PG16 abonné à une publication de PG14, synchronisation pendant que PG14 sert le trafic, puis bascule de l'application en quelques secondes. Indisponibilité minimale, retour arrière possible par réplication inverse, mais plus complexe (séquences, DDL non répliqués, clés primaires obligatoires) ;
- `pg_restore -j N` (format directory) pour paralléliser la restauration.

### B1 : `pg_upgrade --link`

L'image `tianon/postgres-upgrade:14-to-16` contient les binaires 14 et 16. Elle n'est publiée que pour `amd64` (`no matching manifest for linux/arm64/v8`) : elle tourne ici en émulation (`--platform linux/amd64`). Les deux dossiers doivent être sur le **même système de fichiers** pour les liens physiques : on copie donc les données PG14 dans un volume `pgup` organisé en `14/data` et `16/data`.

```bash
$ docker compose stop db             # arrêt propre de PG14 : obligatoire pour pg_upgrade
$ docker run --rm -v shopdata_pgdata:/from:ro -v pgup:/to alpine:3.20 sh -c 'mkdir -p /to/14/data /to/16/data && cp -a /from/. /to/14/data/ && chown -R 999:999 /to ...'
82.1M   /to/14/data

$ time docker run --rm --platform linux/amd64 -v pgup:/var/lib/postgresql \
    -e PGUSER=shop -e POSTGRES_INITDB_ARGS='--username=shop' \
    -e PGDATAOLD=/var/lib/postgresql/14/data -e PGDATANEW=/var/lib/postgresql/16/data \
    tianon/postgres-upgrade:14-to-16 --link
...
Restoring global objects in the new cluster                   ok
Restoring database schemas in the new cluster                 ok
Adding ".old" suffix to old global/pg_control                 ok
If you want to start the old cluster, you will need to remove
the ".old" suffix from /var/lib/postgresql/14/data/global/pg_control.old.
Because "link" mode was used, the old cluster cannot be safely
started once the new cluster has been started.
Linking user relation files                                   ok
...
Upgrade Complete
real 10.351 s

$ docker run -d --name pgup16 -v pgup:/var/lib/postgresql -e PGDATA=/var/lib/postgresql/16/data postgres:16.4-alpine
$ docker exec pgup16 psql -U shop -d shop -tAc 'SHOW server_version'
WARNING:  database "shop" has no actual collation version, but a version was recorded
16.4
$ docker exec pgup16 psql -U shop -d shop -tAc "SELECT count(*) || ' ' || md5(...) FROM orders"
200000 781b09fd6aec10b930330fa129c65a9b             # identique au checksum avant (base seedée deux fois : 200 000 lignes)

$ du -sh /v/14/data /v/16/data /v                  # une seule commande du : chaque inode n'est compté qu'une fois
82.4M   /v/14/data
45.8M   /v/16/data
```

`Linking user relation files` : les fichiers des tables ne sont pas copiés, ce sont des liens physiques vers ceux du dossier 14. C'est pour ça que `du`, qui ne compte chaque fichier physique qu'une fois, n'attribue au dossier 16 que ce qui lui est propre (nouveau catalogue système, WAL).

**Comparaison :**

| | dump / restore (`upgrade-pg.sh`) | `pg_upgrade --link` |
|---|---|---|
| Durée mesurée (≈ 80 Mo) | 7 s d'indisponibilité | 10,4 s |
| Dépend de la taille des données | oui, linéairement (lecture + écriture + index) | presque pas : catalogue converti, données liées |
| Espace disque | données en double | quasi nul en plus |
| Retour arrière | immédiat (ancien volume intact) | **non** une fois PG16 démarré : les fichiers sont partagés et modifiés. Il faut une sauvegarde préalable |
| Contraintes | aucune | binaires des deux versions, même système de fichiers, même libc |

Sur une base aussi petite, `pg_upgrade` n'est pas plus rapide : son temps est dominé par l'`initdb` du nouveau cluster, la conversion du catalogue, et ici l'émulation amd64. Son intérêt apparaît sur les grosses bases : 500 Go se migrent en quelques minutes avec `--link`, contre des heures en dump/restore.

**Piège révélé par l'avertissement de collation :** le volume PG14 vient d'une image **Alpine** (musl), `pg_upgrade` tourne sur une image **Debian** (glibc), et PG16 redémarre sur Alpine. Les règles de tri des chaînes ne sont pas les mêmes selon la libc : un index sur une colonne texte construit avec l'une peut être faux pour l'autre (résultats manquants, doublons dans un index unique). PostgreSQL le signale par `has no actual collation version`. En production : rester sur la même famille d'images de bout en bout (images Debian `postgres:16` et `tianon/postgres-upgrade`), ou faire un `REINDEX` des index sur du texte après la migration. Le dump/restore n'a pas ce problème : les index sont reconstruits par la nouvelle instance.

---

## 4. Redis

```bash
$ docker compose exec -T redis redis-cli CONFIG GET appendonly
appendonly
yes
$ docker compose exec -T redis redis-cli CONFIG GET appendfsync
appendfsync
everysec
$ docker compose exec -T redis redis-cli CONFIG GET save
save
3600 1 300 100 60 10000
$ docker compose exec -T redis redis-cli INFO persistence | grep -E 'aof_enabled|...'
rdb_changes_since_last_save:0
rdb_last_bgsave_status:ok
aof_enabled:1
aof_last_write_status:ok
```

**Perte maximale de données :**

| Mode | Fonctionnement | Perte maximale en cas de crash |
|---|---|---|
| `--save 60 1` (RDB) | instantané complet du dataset toutes les 60 s **s'il y a eu au moins 1 écriture** | tout ce qui a été écrit depuis le dernier instantané : **jusqu'à 60 s** d'écritures (plus si un `BGSAVE` échoue, par exemple disque plein) |
| `--appendonly yes` (AOF, `appendfsync everysec` par défaut) | chaque commande d'écriture est ajoutée au fichier AOF, `fsync` une fois par seconde | **environ 1 s** d'écritures. Avec `appendfsync always` : aucune perte en théorie, mais une écriture disque par commande |

**Dans notre stack**, Redis contient :
- le **cache** `products` (TTL 30 s) : se reconstruit tout seul depuis PostgreSQL. Aucune persistance nécessaire ;
- la **file** `orders:queue` : commandes poussées par l'API, en attente du worker. Les commandes sont **aussi** insérées dans PostgreSQL en `pending` avant d'être poussées, donc une perte de la file ne perd pas la commande, mais elle reste `pending` tant que personne ne la retraite.

Niveau justifié : **AOF avec `everysec`** (configuré dans le `compose.yml` du TP04) : au plus une seconde de file perdue, coût en performance négligeable, et un volume nommé `redisdata` pour survivre aux recréations de conteneur. Le RDB seul pourrait perdre une minute de commandes en attente. Pour une garantie complète, il faudrait de toute façon un mécanisme de reprise côté application (retraiter les commandes `pending` anciennes) ou un vrai broker (RabbitMQ, Redis Streams avec acquittement), puisque `BRPOP` retire le message de la file avant que le worker l'ait traité.

---

## Bonus non réalisés

- **B2** (chiffrement `age`/`gpg` + MinIO) : `pg_dump -Fc | age -r <clé publique> > shop.dump.age`, puis `mc cp` vers un bucket MinIO lancé en conteneur. Le fichier n'est lisible qu'avec la clé privée, conservée hors du serveur.
- **B3** (volume NFS / plugin) : avec `driver_opts: { type: nfs, o: "addr=...,rw", device: ":/export/pgdata" }`, les données ne sont plus sur le disque local : un conteneur peut être relancé sur un autre nœud et retrouver ses données (haute disponibilité de l'hôte). Mais la sauvegarde doit alors se faire côté stockage (snapshots NFS), la latence réseau pénalise PostgreSQL, et deux instances ne doivent jamais écrire dans le même dossier.
- **B4** (PITR) : `archive_mode = on` + `archive_command` vers un volume, une sauvegarde de base (`pg_basebackup`), puis restauration avec `recovery_target_time = 'T-5min'` : PostgreSQL rejoue les WAL jusqu'à l'instant voulu.
