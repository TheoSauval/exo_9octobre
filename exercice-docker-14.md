# Exercice Docker #14 (TP08) - Durcir les conteneurs pour la production

**Objectif :** mesurer les écarts de durcissement de la stack *Shop SAS* (TP04), comprendre chaque mesure par une expérience, livrer une surcharge `compose.hardened.yml` qui fonctionne, un outil d'audit rejouable et une configuration de démon.

Fichiers : dossier `exo-14/`

```
exo-14/
├── audit.sh               # audit rejouable, code retour ≠ 0 si écart
├── compose.hardened.yml   # surcharge de durcissement de la stack exo-12 (commentée par menace)
└── daemon.json            # configuration de démon proposée
```

Utilisation (depuis `exo-12/`) :

```bash
../exo-14/audit.sh shop
docker compose -f compose.yml -f ../exo-14/compose.hardened.yml up -d --wait
```

Environnement : Docker Desktop 27.3.1, macOS Apple Silicon (`linux/arm64`).

> **État d'avancement.** Les étapes 1, 2 et 4 ont été exécutées et les sorties ci-dessous sont réelles. À l'étape 3, la stack durcie passe l'audit sans écart, mais le premier essai a échoué sur le proxy de socket. La cause a été diagnostiquée et corrigée dans `compose.hardened.yml`, mais la stack complète **n'a pas été relancée** avec la correction : le smoke test vert reste à faire (commande en fin de section 3).

---

## 1. Mesurer

### `audit.sh`

Pour chaque conteneur en cours d'exécution (ou ceux d'un projet Compose donné en argument), le script affiche : utilisateur, `Privileged`, capabilities retirées et ajoutées, rootfs en lecture seule, limite mémoire, `PidsLimit`, `no-new-privileges`, montage de la socket Docker. Chaque contrôle en échec est un écart (références CIS Docker Benchmark dans l'en-tête du script).

Un conteneur peut déclarer des **exceptions justifiées** avec un label visible dans le compose (`audit.exceptions: "user,socket"`). Elles sont affichées comme acceptées et ne comptent pas dans le code retour. Une exception est donc documentée à l'endroit où elle est faite, pas dans une liste cachée dans le script.

### Stack du TP04 (base)

```bash
$ ../exo-14/audit.sh shop
CONTENEUR      USER         PRIVIL.  CAP_DROP  CAP_ADD  RO   MEMOIRE  PIDS    NNP  SOCKET  NB  ECARTS
shop-api-1     1000:1000    non      -         -        non  aucune   aucune  non  non     5   capdrop,readonly,memory,pids,nnp
shop-db-1      root(vide)   non      -         -        non  aucune   aucune  non  non     6   user,capdrop,readonly,memory,pids,nnp
shop-proxy-1   root(vide)   non      -         -        non  aucune   aucune  non  OUI     7   user,capdrop,readonly,memory,pids,nnp,socket
shop-redis-1   root(vide)   non      -         -        non  aucune   aucune  non  non     6   user,capdrop,readonly,memory,pids,nnp
shop-worker-1  10001:10001  non      -         -        non  aucune   aucune  non  non     5   capdrop,readonly,memory,pids,nnp

Total : 29 écart(s) sur 5 conteneur(s), 0 exception(s) acceptée(s)
[exit 1]
```

### Stack du TP04 avec `compose.prod.yml`

```bash
$ ../exo-14/audit.sh shop
CONTENEUR      USER         PRIVIL.  CAP_DROP  CAP_ADD  RO   MEMOIRE  PIDS    NNP  SOCKET  NB  ECARTS
shop-api-1     1000:1000    non      ALL       -        oui  256M     aucune  oui  non     1   pids
shop-api-2     1000:1000    non      ALL       -        oui  256M     aucune  oui  non     1   pids
shop-db-1      root(vide)   non      -         -        non  512M     aucune  oui  non     4   user,capdrop,readonly,pids
shop-proxy-1   root(vide)   non      -         -        non  128M     aucune  non  OUI     6   user,capdrop,readonly,pids,nnp,socket
shop-redis-1   root(vide)   non      -         -        non  128M     aucune  oui  non     4   user,capdrop,readonly,pids
shop-worker-1  10001:10001  non      ALL       -        oui  128M     aucune  oui  non     1   pids

Total : 17 écart(s) sur 6 conteneur(s), 0 exception(s) acceptée(s)
[exit 1]
```

La surcharge prod du TP04 corrige l'API et le worker, mais laisse la base, Redis et surtout Traefik (root + socket Docker) quasiment intacts, et aucune limite de processus nulle part.

### docker-bench-security

La commande de l'énoncé échoue sur ce moteur :

```
docker: Error response from daemon: ... error mounting ".../hostname" to rootfs at "/etc/hostname":
open .../merged/etc/hostname: read-only file system: unknown.
```

Monter tout `/etc` en lecture seule empêche Docker d'y monter `/etc/hostname` (incompatibilité connue avec les moteurs récents). Elle fonctionne avec des montages ciblés (et l'image, publiée seulement en amd64, tourne en émulation) :

```bash
$ docker run --rm --net host --pid host --userns host --cap-add audit_control \
    -v /var/lib:/var/lib:ro -v /var/run/docker.sock:/var/run/docker.sock:ro -v /etc/docker:/etc/docker:ro \
    docker/docker-bench-security
[INFO] Checks: 105
[INFO] Score: 5
```

Ce passage a été fait sans la stack `shop` démarrée : la section 5 (conteneurs) porte sur les autres conteneurs de la machine et n'est pas détaillée ici. Les sections 1 et 2 ne s'appliquent qu'à moitié : sous Docker Desktop, « l'hôte » est la VM Linux de Docker, pas le Mac.

**Les 5 `WARN` prioritaires retenus :**

| Contrôle | Pourquoi prioritaire |
|---|---|
| **5.31** socket Docker montée dans un conteneur | équivalent root sur l'hôte : c'est le cas de Traefik dans la stack |
| **5.25 / 2.18** pas de `no-new-privileges` | escalade par binaire setuid possible dans tous les conteneurs |
| **5.12** rootfs inscriptible | un attaquant peut déposer et exécuter ses outils |
| **5.10 / 5.28** pas de limite mémoire ni de PIDs | un conteneur peut affamer la machine (fuite, fork bomb) |
| **2.1** trafic non restreint sur le bridge par défaut (`icc`) | tous les conteneurs du bridge par défaut peuvent se joindre |

Autres avertissements notables : 2.8 (pas de user namespaces), 2.14 (pas de `live-restore`), 2.15 (userland proxy actif), 4.1 / 4.6 (images sans utilisateur ou sans `HEALTHCHECK`).

---

## 2. Comprendre chaque mesure

| Mesure | Expérience | Résultat |
|---|---|---|
| `--read-only` | `touch /x` | `touch: /x: Read-only file system` |
| `--read-only --tmpfs /tmp` | `touch /tmp/x; touch /x` | `/tmp/x OK`, puis `/x` refusé : seuls les tmpfs déclarés sont inscriptibles |
| capabilities par défaut | `grep Cap /proc/self/status` | `CapEff: 00000000a80425fb` (14 capabilities) |
| `--cap-drop ALL` | idem | `CapEff: 0000000000000000` |
| `--cap-drop ALL` | `chown 1000:1000 /f` | `chown: /f: Operation not permitted` ; avec `--cap-add CHOWN` : OK |
| `--cap-drop ALL` | `ping -c1 1.1.1.1` | **fonctionne** (voir ci-dessous) |
| `--cap-drop ALL` | `apk add curl` | **fonctionne** même sans aucune capability (voir ci-dessous) |
| `no-new-privileges` | `passwd -S` (binaire setuid root) en utilisateur `worker` | sans : `worker L 2026-10-29 ...` (lu dans `/etc/shadow` grâce au setuid) ; avec : `worker P` et `NoNewPrivs: 1` (le setuid est ignoré, `/etc/shadow` illisible) |
| `--pids-limit 50` | 100 `sleep &` | sans limite : `processus: 105` ; avec : `sh: can't fork: Resource temporarily unavailable` |
| `--memory 32m` | allocation de 100 Mo en Python | code retour `137`, `OOMKilled=true` ; 10 Mo passent |
| `--user 1000` | `id` | `uid=1000 gid=0(root)` (pas d'entrée passwd, groupe 0 par défaut) |
| `--user 1000` + volume | `touch /data/par-1000` dans un volume créé par root | `Permission denied` : le volume appartient à root |
| seccomp | `unshare --user id` | **fonctionne** même sans `seccomp=unconfined` (voir ci-dessous) |

**Ce que les expériences ont appris :**

- **ping sans NET_RAW** : Docker règle `net.ipv4.ping_group_range = 0 2147483647` dans chaque conteneur, ce qui autorise les sockets ICMP « datagramme » sans capability. Retirer NET_RAW bloque donc les sockets brutes (forge de paquets, ARP spoofing), pas le ping.
- **`apk add` sans capability** : tous les fichiers appartiennent déjà à root et le processus est root (propriétaire) : il n'a besoin ni de CHOWN ni de DAC_OVERRIDE. Une installation qui change de propriétaire (un paquet qui crée un utilisateur système, par exemple) aurait besoin de CHOWN et FOWNER. En production on n'installe de toute façon rien à l'exécution : avec `read_only`, `apk add` échouerait de toute manière.
- **`--user 1000` et volumes** : un volume nommé hérite des droits du dossier de l'image au premier montage. Pour un utilisateur non-root, il faut que l'image crée le dossier avec le bon propriétaire (`chown` dans le Dockerfile), sinon l'écriture est refusée.
- **seccomp désactivé sur ce moteur** : `docker info` affiche `name=seccomp,profile=unconfined` et un conteneur standard a `Seccomp: 0`. Le moteur de Docker Desktop de cette machine tourne **sans profil seccomp**, d'où le `unshare --user` qui réussit. C'est un écart de configuration du démon (corrigé dans le `daemon.json` proposé, voir étape 4). Dans les moteurs dind lancés à l'étape 4, le profil par défaut est bien actif (`name=seccomp,profile=builtin`).

**Profil seccomp par défaut de Docker** (`moby/profiles/seccomp/default.json`, v27.3.1) :

```
defaultAction: SCMP_ACT_ERRNO
appels autorisés sans condition : 352
  si CAP_SYS_ADMIN : bpf clone clone3 fanotify_init fsconfig fsmount fsopen fspick lookup_dcookie mount
                     mount_setattr move_mount open_tree perf_event_open quotactl quotactl_fd setdomainname
                     sethostname setns syslog umount umount2 unshare
  si CAP_SYS_BOOT : reboot
  si CAP_SYS_MODULE : delete_module init_module finit_module
  si CAP_SYS_PTRACE : kcmp pidfd_getfd process_madvise process_vm_readv process_vm_writev ptrace
  si CAP_SYS_TIME : settimeofday stime clock_settime clock_settime64
  ...
```

C'est une liste blanche : tout appel non listé renvoie une erreur. Environ 350 appels sont autorisés ; une quarantaine d'appels sensibles (montage, chargement de modules, `reboot`, `kexec`, `ptrace`, `unshare`/`setns` pour créer des namespaces, `bpf`, réglage de l'heure...) ne sont autorisés que si le conteneur a la capability correspondante. C'est ce qui bloque normalement `unshare --user`.

---

## 3. Durcir la stack

### Capabilities nécessaires : essais

**PostgreSQL en root (comportement par défaut de l'image) :**

```bash
$ docker run -d --cap-drop ALL -e POSTGRES_PASSWORD=x -v pgcap:/var/lib/postgresql/data postgres:16.4-alpine
état : exited (code 1)
chmod: /var/lib/postgresql/data: Operation not permitted
chmod: /var/run/postgresql: Operation not permitted
error: failed switching to "postgres": operation not permitted

$ docker run -d --cap-drop ALL --cap-add SETUID --cap-add SETGID ... postgres:16.4-alpine
état : running
LOG:  database system is ready to accept connections
```

L'entrypoint démarre en root, tente de corriger les droits (`chmod`, erreurs tolérées sur un volume neuf déjà au bon propriétaire), puis passe en utilisateur `postgres` avec `su-exec`, ce qui exige **SETUID et SETGID**. Sur un volume existant mal attribué, il faudrait aussi CHOWN, DAC_OVERRIDE et FOWNER.

**PostgreSQL démarré directement en `postgres` :**

```bash
$ docker run -d --user postgres --cap-drop ALL --read-only --tmpfs /var/run/postgresql --tmpfs /tmp \
    --security-opt no-new-privileges -e POSTGRES_PASSWORD=x -v pgcap:/var/lib/postgresql/data postgres:16.4-alpine
état : running
LOG:  database system is ready to accept connections
postgres|PostgreSQL 16.4 on aarch64-unknown-linux-musl, ...
```

En démarrant directement avec l'utilisateur propriétaire du volume, **aucune capability** n'est nécessaire, même avec un rootfs en lecture seule. C'est le choix retenu.

**Traefik et le port 80 :**

```bash
$ docker run -d --cap-drop ALL --sysctl net.ipv4.ip_unprivileged_port_start=1024 traefik:v3.1 --entrypoints.web.address=:80 ...
état : exited
ERR ... listen tcp :80: bind: permission denied
$ docker run -d --cap-drop ALL --cap-add NET_BIND_SERVICE --sysctl net.ipv4.ip_unprivileged_port_start=1024 traefik:v3.1 ...
état : running        OK <- /ping répond
$ docker run -d --user 65534:65534 --cap-drop ALL --sysctl net.ipv4.ip_unprivileged_port_start=1024 traefik:v3.1 ...
état : exited         ... bind: permission denied
$ docker run -d --user 65534:65534 --cap-drop ALL traefik:v3.1 ...
état : running        OK <- /ping répond
```

Classiquement, Traefik a besoin de **NET_BIND_SERVICE** pour écouter sur un port < 1024. Mais Docker règle `net.ipv4.ip_unprivileged_port_start = 0` dans l'espace réseau de chaque conteneur (vérifié à l'étape 2) : sans ce réglage, même root sans la capability échoue ; avec, Traefik tourne en `nobody` sans aucune capability. Le réglage est « namespacé » : il n'a aucun effet sur l'hôte. `compose.hardened.yml` l'écrit explicitement pour ne pas dépendre d'une valeur par défaut. (Ajouter NET_BIND_SERVICE à un utilisateur non-root ne suffirait pas : Docker ne place pas les capabilities ajoutées dans l'ensemble effectif d'un processus non-root.)

### `compose.hardened.yml`

Ancre commune appliquée à tous les services : `no-new-privileges`, `cap_drop: [ALL]`, `read_only: true` (chaque directive commentée par la menace réduite). Puis par service :

| Service | Utilisateur | tmpfs | Capabilities ajoutées | Limites (CPU / mémoire / PIDs) |
|---|---|---|---|---|
| socket-proxy | root (exception déclarée) | `/run`, `/tmp` | aucune | 0,25 / 64M / 50 |
| proxy (Traefik) | `65534:65534` | `/tmp` | aucune (sysctl du port) | 0,5 / 128M / 100 |
| api | `1000:1000` (image) | `/tmp` | aucune | 0,5 / 256M / 100 |
| worker | `10001:10001` (image) | `/tmp` | aucune | 0,25 / 128M / 50 |
| db | `postgres` | `/var/run/postgresql`, `/tmp` | aucune | 1 / 512M / 200 |
| redis | `redis` | `/tmp` | aucune | 0,25 / 128M / 50 |

**Socket Docker retirée de Traefik :** `volumes: !reset []` supprime le montage hérité, et Traefik interroge `tecnativa/docker-socket-proxy` en HTTP (`TRAEFIK_PROVIDERS_DOCKER_ENDPOINT=tcp://socket-proxy:2375`). Le proxy est le seul à monter la socket, en lecture seule. Il ne laisse passer que `GET /containers/*`, `/events`, `/version`, `/_ping` (`CONTAINERS=1`, `EVENTS=1`, `POST=0`), et il est sur un réseau `socket` en `internal: true`, joignable uniquement par Traefik. Si Traefik est compromis, l'attaquant ne peut plus créer un conteneur `--privileged` qui monte `/` de l'hôte : il peut seulement lire la liste des conteneurs.

Les limites de PIDs sont dans `deploy.resources.limits.pids` : Compose refuse `pids_limit` et `deploy.resources.limits` ensemble (« can't set distinct values on 'pids_limit' and 'deploy.resources.limits.pids' »).

### Validation

```bash
$ docker compose -f compose.yml -f ../exo-14/compose.hardened.yml up -d --wait
dependency failed to start: container shop-socket-proxy-1 is unhealthy

$ ../exo-14/audit.sh shop
CONTENEUR            USER         PRIVIL.  CAP_DROP  CAP_ADD  RO   MEMOIRE  PIDS  NNP  SOCKET  NB  ECARTS  ACCEPTES
shop-api-1           1000:1000    non      ALL       -        oui  256M     100   oui  non     0   -       -
shop-db-1            postgres     non      ALL       -        oui  512M     200   oui  non     0   -       -
shop-redis-1         redis        non      ALL       -        oui  128M     50    oui  non     0   -       -
shop-socket-proxy-1  root         non      ALL       -        oui  64M      50    oui  OUI     0   -       user,socket
shop-worker-1        10001:10001  non      ALL       -        oui  128M     50    oui  non     0   -       -

Total : 0 écart(s) sur 5 conteneur(s), 2 exception(s) acceptée(s)
[exit 0]

$ docker compose ... exec -T db id     ->  uid=70(postgres) gid=70(postgres)
$ docker compose ... exec -T redis id  ->  uid=999(redis) gid=1000(redis)
$ docker compose ... exec -T api id    ->  uid=1000(node) gid=1000(node)
$ docker compose ... exec -T worker id ->  uid=10001(worker) gid=10001(worker)
$ docker run --rm --network shop_socket alpine:3.20 wget -T 3 -qO- http://example.com
wget: bad address 'example.com'                       # réseau socket : pas d'accès Internet
```

L'audit passe de **29 écarts à 0** (les deux seules exceptions sont celles déclarées sur le proxy de socket). Base, Redis, API et worker démarrent et sont `healthy` en non-root, sans capability, rootfs en lecture seule. **Mais le proxy de socket redémarrait en boucle** : Traefik, qui en dépend, n'a pas démarré et le smoke test a échoué (`Failed to connect to api.localhost port 80`).

**Diagnostic** (même conteneur lancé avec différentes options) :

```
== variante 1 : --read-only --tmpfs /run --tmpfs /tmp --cap-drop ALL --security-opt no-new-privileges
état : exited code=1
/usr/local/bin/docker-entrypoint.sh: line 18: can't create /usr/local/etc/haproxy/haproxy.cfg: Read-only file system

== variante 2 : --cap-drop ALL --security-opt no-new-privileges
état : running        [NOTICE] Loading success.       _ping OK

== variante 3 : --read-only --tmpfs /run --tmpfs /tmp
état : exited code=1  (même erreur que la variante 1)
```

L'entrypoint de l'image génère sa configuration haproxy par `sed` **dans** `/usr/local/etc/haproxy/`, ce que `read_only` interdit. Les capabilities et `no-new-privileges` ne posent aucun problème (variante 2). Correction dans `compose.hardened.yml` : l'entrypoint est remplacé par la même commande, qui écrit la configuration dans `/tmp` (tmpfs), puis lance haproxy avec les options de l'image :

```yaml
entrypoint:
  - /bin/sh
  - -c
  - 'sed "s/[$$][{]BIND_CONFIG[}]/:2375/" /usr/local/etc/haproxy/haproxy.cfg.template > /tmp/haproxy.cfg && exec haproxy -W -db -f /tmp/haproxy.cfg'
```

**Reste à faire** pour valider l'étape 3 (non exécuté) :

```bash
cd exo-12
docker compose -f compose.yml -f ../exo-14/compose.hardened.yml up -d --wait
../exo-14/audit.sh shop
COMPOSE="docker compose -f compose.yml -f ../exo-14/compose.hardened.yml" ./smoke-test.sh
```

C'est exactement la situation décrite par l'énoncé : une mesure de durcissement qui casse le démarrage serait désactivée par l'astreinte. Le diagnostic par variantes permet de garder `read_only` et de corriger seulement ce qui bloque.

---

## 4. Côté démon

### `daemon.json` proposé

```json
{
  "no-new-privileges": true,
  "icc": false,
  "live-restore": true,
  "userland-proxy": false,
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" },
  "userns-remap": "default",
  "default-ulimits": {
    "nofile": { "Name": "nofile", "Soft": 65536, "Hard": 65536 },
    "nproc": { "Name": "nproc", "Soft": 4096, "Hard": 4096 }
  }
}
```

| Option | Effet | CIS |
|---|---|---|
| `no-new-privileges` | appliqué à tous les conteneurs, même ceux qui l'oublient | 2.18 |
| `icc: false` | pas de trafic entre conteneurs du bridge par défaut | 2.1 |
| `live-restore` | les conteneurs continuent de tourner pendant un redémarrage ou une mise à jour du démon | 2.14 |
| `userland-proxy: false` | ports publiés par iptables plutôt que par un processus `docker-proxy` par port | 2.15 |
| logs rotatifs | le disque ne se remplit pas (même réglage que `x-logging` au TP04, mais par défaut) | |
| `userns-remap` | root dans un conteneur = un uid non privilégié sur l'hôte (165536+) | 2.8 |
| `default-ulimits` | plafonds de fichiers ouverts et de processus par défaut | |

Sur cette machine, il faudrait aussi **retirer le `seccomp-profile` `unconfined`** de la configuration du moteur Docker Desktop (Settings > Docker Engine) : le profil par défaut doit être actif.

Validation de la syntaxe avec le binaire du démon :

```bash
$ docker run --rm --entrypoint dockerd -v .../daemon.json:/etc/docker/daemon.json:ro docker:27.3.1-dind \
    --validate --config-file /etc/docker/daemon.json
level=info msg="User namespaces: ID ranges will be mapped to subuid/subgid ranges of: dockremap"
configuration OK
```

### Effet de bord de `icc: false`

`icc` ne s'applique qu'au **bridge par défaut** (`docker0`). Les réseaux créés par Compose (`shop_front`, `shop_back`...) ont leur propre réglage (`com.docker.network.bridge.enable_icc`, vrai par défaut) : la stack n'est pas touchée. Seuls les conteneurs lancés avec `docker run` sans `--network` ne peuvent plus se parler, ce qui pousse à utiliser des réseaux dédiés (le bon usage de toute façon). Le test prévu dans un moteur dind (`--icc=false`) n'a pas abouti : Docker 27 refuse les noms de conteneur d'une seule lettre (`Invalid container name (a)`). Le script corrigé (`ctn-a`, `ctn-b`) n'a pas été relancé.

### Effet de bord de `userns-remap` (testé dans un moteur dind)

```bash
$ docker info --format '{{json .SecurityOptions}}'
["name=seccomp,profile=builtin","name=userns","name=cgroupns"]
$ grep dockremap /etc/subuid
dockremap:165536:65536

# dossier de l'hôte appartenant à root, monté dans un conteneur dont le processus est "root"
$ docker run --rm -v /srv/v:/data alpine:3.20 sh -c "id; touch /data/cree-par-root-du-conteneur"
touch: /data/cree-par-root-du-conteneur: Permission denied
uid=0(root) gid=0(root) ...

# fichiers existants appartenant à l'uid 999 (comme le volume Redis)
$ ls -ln /srv/old
-rw-r--r--    1 999      999              0 Oct 30 15:12 existant
$ docker run --rm -v /srv/old:/data alpine:3.20 sh -c "ls -ln /data; echo x >> /data/existant"
sh: can't create /data/existant: Permission denied
-rw-r--r--    1 65534    65534            0 Oct 30 15:12 existant
```

Avec `userns-remap`, le root du conteneur est en réalité l'uid 165536 sur l'hôte. Conséquences :

- un dossier de l'hôte appartenant au vrai root n'est **plus inscriptible**, même par « root » dans le conteneur : c'est le but (un conteneur compromis ne peut plus écrire dans les fichiers de l'hôte) ;
- les **volumes existants** créés avant l'activation appartiennent à des uid « réels » (999 pour Redis, 70 pour PostgreSQL) qui ne correspondent à rien dans l'espace remappé : ils apparaissent comme `65534` (nobody) et deviennent illisibles ou non inscriptibles. Il faut les ré-attribuer (`chown -R 165536+uid`) ou les restaurer depuis une sauvegarde logique (TP05). Docker stocke d'ailleurs les données dans un dossier séparé (`/var/lib/docker/165536.165536/`) : images et volumes « disparaissent » à l'activation ;
- incompatible avec `--privileged`, `--pid=host`, `--net=host` sans `--userns=host`.

Alternative : **Docker rootless**, où le démon entier tourne sans privilèges.

---

## Bonus

Non réalisés.

- **B1, seccomp personnalisé** : lancer l'API sous `strace -f -c` (ou `docker-slim`) pendant le smoke test pour lister les appels réellement utilisés, partir du profil par défaut et retirer le reste ; à charger avec `security_opt: [seccomp=./seccomp-api.json]`.
- **B2, rootless** : les ports < 1024 ne sont plus publiables sans `net.ipv4.ip_unprivileged_port_start=0` côté hôte (ou `setcap` sur `rootlesskit`), les outils qui lisent les cgroups de l'hôte (cAdvisor) ne fonctionnent plus, et le réseau passe par `slirp4netns`/`pasta` (débit inférieur).
- **B3, distroless** : variante déjà réalisée pour l'API au TP01 (`exo-11/bonus/Dockerfile.distroless`, sans shell, healthcheck en `node -e fetch(...)`).
- **B4, AppArmor** : la VM de Docker Desktop n'a pas AppArmor (avertissement 5.1 de docker-bench) ; sur un hôte Ubuntu, un profil dédié interdirait toute écriture hors `/tmp`.
