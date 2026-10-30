# Exercice Docker #15 (TP09) - CI/CD : de la pull request au déploiement sans interruption

**Objectif :** remplacer le déploiement manuel (SSH + `git pull` + `compose up --build`, 30 à 60 s de coupure) par un pipeline qui construit, teste, scanne, signe et publie les images, puis un déploiement sans interruption sur un hôte distant via `docker context`, avec la preuve mesurée.

Fichiers : dossier `exo-15/` (le dépôt `shop`)

```
exo-15/
├── .github/workflows/ci.yml       # pipeline GitHub Actions (PR / main / tag v*)
├── ci-local.sh                    # rejoue le pipeline en local contre un registre local
├── release-gate.sh                # porte de release : trivy bloquant + signature cosign
├── deploy/
│   ├── rolling-update.sh          # déploiement sans interruption (un réplica à la fois)
│   ├── measure-downtime.sh        # 100 req/s sur /health, compte les échecs
│   └── preprod-host/              # hôte "distant" de TP : moteur Docker + SSH (utilisateur deploy)
├── compose.yml, compose.override.yml, compose.watch.yml   # stack du TP04
├── compose.prod.yml               # surcharge prod (retry Traefik, stop_grace_period, chemins serveur)
├── compose.swarm.yml              # bonus B1 : même stack en Docker Swarm
├── apps/shopapi, apps/shop-worker # TP01 / TP04 (le worker utilise maintenant un secret de build)
├── ci/pip.conf.example            # modèle du secret de build du worker
└── smoke-test.sh, Makefile, db/, .env.example
```

Ce dossier est un sous-dossier du dépôt d'exercices : le SHA utilisé pour les tags est celui de ce dépôt.

> **État d'avancement : TP non exécuté de bout en bout.** Tous les fichiers sont écrits. Le workflow passe `actionlint` sans erreur, les scripts passent `shellcheck`, les Dockerfiles passent hadolint, et `docker compose config` / `docker stack config` valident les fichiers Compose. Le premier passage sur la machine s'est arrêté sur deux erreurs, corrigées depuis (détail en fin de document), mais il **n'a pas été relancé**. Il n'y a donc ni capture de pipeline vert, ni mesure d'interruption, ni durée de rollback dans ce rendu. Les commandes pour les obtenir sont à la fin.

---

## 1. Le dépôt

Assemblé à partir de la stack du TP04 (`exo-12`) : applications, `compose.yml` et surcharges, `db/`, `smoke-test.sh`, `Makefile`. Le TP03 n'ayant pas été fait, `release-gate.sh` est écrit pour ce TP.

`.gitignore` : `.env`, `secrets/*`, `ci/pip.conf` (identifiants du registre Python), `ci/keys/*` sauf `cosign.pub` (la clé publique se versionne, pas la privée), `.ci/` (rapports de scan).

## 2. Le pipeline

### `.github/workflows/ci.yml`

| Déclencheur | Jobs |
|---|---|
| **pull request** | `lint` (hadolint x2, `docker compose config` base et prod) → `integration` (`compose up --wait` + `smoke-test.sh` + `down -v`) et `build` (étape `test` puis build multi-arch **sans push**) |
| **push sur main** | les mêmes, puis dans `build` : push `sha-<sha7>` sur GHCR, scan trivy **bloquant**, signature cosign **keyless** ; puis `deploy-preprod` |
| **tag `v*`** | `build` avec tags `X.Y.Z` et `X.Y`, puis `deploy-prod` dans l'environnement protégé `production` |

Points imposés :

| Exigence | Mise en oeuvre |
|---|---|
| tags et labels OCI | `docker/metadata-action@v5` : `type=sha,prefix=sha-,format=short`, `type=semver` `{{version}}` et `{{major}}.{{minor}}`, `latest=false` (tags immuables uniquement) |
| cache | `cache-from/to: type=gha,scope=<service>,mode=max` |
| multi-arch | `docker/setup-qemu-action` + `platforms: linux/amd64,linux/arm64` |
| matrice | `matrix.include` api / worker (contexte et nom d'image) |
| secret de build | `secrets: pipconf=${{ secrets.PIP_CONF }}`, monté par `RUN --mount=type=secret,id=pipconf,target=/etc/pip.conf` dans le Dockerfile du worker : jamais dans une couche |
| provenance et SBOM | `provenance: mode=max`, `sbom: true` (attestations attachées à l'index de l'image) |
| scan bloquant | `aquasecurity/trivy-action` sur le **digest** poussé, `severity: CRITICAL`, `ignore-unfixed: true`, `exit-code: 1` |
| signature keyless | `permissions: id-token: write` + `cosign sign --yes <image>@<digest>` : certificat éphémère émis par Fulcio pour l'identité OIDC du workflow, inscrit dans Rekor ; aucune clé à gérer |
| approbation prod | `environment: production` avec « required reviewers » dans les réglages du dépôt : le job attend une validation humaine |
| vérification côté déploiement | `rolling-update.sh` exécute `cosign verify --certificate-identity-regexp '^https://github.com/<dépôt>/.github/workflows/ci.yml@refs/tags/v'` avant toute modification du serveur |

Détails :
- le nom du registre est passé en minuscules (`${GITHUB_REPOSITORY_OWNER,,}`) : `TheoSauval` n'est pas une référence d'image valide ;
- les secrets SSH passent par des variables d'environnement, jamais interpolés directement dans le script (injection) ;
- le serveur tire les images avec les identifiants du **client** (le runner, connecté à GHCR) : avec `docker context`, `compose pull` transmet l'authentification du client au moteur distant.

### `ci-local.sh` (sans compte GitHub)

Mêmes étapes en local, contre un registre `registry:2` sur `localhost:5050` et un builder BuildKit `docker-container` (`--driver-opt network=host` pour joindre le registre) :

```bash
./ci-local.sh pr                                      # lint, test, build multi-arch sans push, test d'intégration
./ci-local.sh main                                    # + push sha-<sha>, release gate, déploiement préprod
./ci-local.sh tag v1.5.0                              # + tags 1.5.0 et 1.5, release gate, attente d'approbation
PROD_APPROVED_BY=theo ./ci-local.sh deploy-prod v1.5.0
```

Sans `PROD_APPROVED_BY`, `deploy-prod` refuse : c'est l'équivalent local de l'environnement protégé.

### `release-gate.sh`

Appelée avec une référence **par digest** (on signe exactement ce qui a été scanné) :
1. trivy sur chaque plateforme (amd64 et arm64) : affiche les CRITICAL et HIGH, **bloque** s'il existe une CRITICAL corrigible ;
2. signature cosign. En local : paire de clés générée dans `ci/keys/`, registre HTTP et pas de journal de transparence (`--allow-http-registry`, `--tlog-upload=false`). En CI GitHub : keyless (`COSIGN_KEYLESS=1`).

## 3. Déploiement distant

### L'hôte de préprod du TP

`deploy/preprod-host/` construit un hôte jetable : moteur Docker (image `docker:dind`) + serveur SSH, utilisateur `deploy` membre du groupe `docker`, connexion **par clé uniquement** (`PasswordAuthentication no`, `PermitRootLogin no`, `AllowUsers deploy`). Il est publié sur `localhost:2222` (SSH) et `localhost:8088` (Traefik de la préprod). Le moteur déclare le registre de la CI comme « insecure » (HTTP, TP uniquement).

```bash
docker context create preprod --docker "host=ssh://deploy@localhost:2222"
docker --context preprod ps
DOCKER_CONTEXT=preprod docker compose -f compose.yml -f compose.prod.yml up -d --wait
```

Le client Docker ouvre une connexion SSH et lance `docker system dial-stdio` sur le serveur : toutes les commandes (dont Compose) passent par ce tunnel.

### Prérequis côté serveur

- Docker installé, utilisateur `deploy` dans le groupe `docker` (ce qui équivaut à root sur ce serveur : la clé SSH de la CI doit être traitée comme un secret critique, idéalement restreinte et tournée) ;
- clé publique de la CI dans `~deploy/.ssh/authorized_keys`, empreinte du serveur dans le `known_hosts` de la CI (pas de `StrictHostKeyChecking no`) ;
- accès au registre (`docker login` en lecture seule, ou identifiants transmis par le client) ;
- **les fichiers de configuration et les secrets présents sur le serveur, hors git** : `/srv/shop/secrets/db_password.txt` et `/srv/shop/db/init.sql`.

### Comment les secrets arrivent en prod

Point important avec `docker context` : Compose s'exécute sur la machine de CI, mais **un bind mount désigne un chemin du serveur**, pas du client. Le `./secrets/db_password.txt` du compose de base serait résolu en `/home/runner/.../secrets/db_password.txt`, qui n'existe pas sur le serveur. Vérifié en local avec un fichier secret absent :

```
level=warning msg="secret file sectest_pw does not exist"
Error response from daemon: invalid mount config for type "bind": bind source path does not exist: /srv/absent/pw.txt
```

Compose n'émet qu'un avertissement côté client, c'est le moteur qui vérifie le chemin : sur son propre système de fichiers. D'où, dans `compose.prod.yml` :

```yaml
secrets:
  db_password:
    file: ${SHOP_CONF_DIR:-.}/secrets/db_password.txt   # SHOP_CONF_DIR=/srv/shop pour un serveur distant
```

Le secret est **provisionné une fois sur le serveur** par l'équipe d'exploitation (ici généré directement sur le serveur via SSH, droits 644 dans un dossier 700), et ne transite jamais par la CI ni par git. Seul son chemin est versionné. Le `.env`, lui, est lu par Compose **sur le client** : avec `docker context`, les variables non secrètes (`REGISTRY`, `VERSION`) sont fournies par le pipeline. Alternatives : secrets Compose de type `environment:` (copiés dans le conteneur depuis une variable de la CI, stockée dans les secrets GitHub de l'environnement), ou un gestionnaire de secrets (Vault, SOPS). En Swarm (bonus B1), le secret est envoyé depuis le client et stocké chiffré dans le Raft du cluster.

## 4. Zéro interruption

### `deploy/measure-downtime.sh`

100 requêtes par seconde sur `/health` (avec l'en-tête `Host: api.localhost` pour le routage Traefik), jusqu'à une durée maximale ou la création d'un fichier d'arrêt. Une requête est un échec si elle ne répond pas `200` en moins de 2 s. En fin de mesure : nombre de requêtes, d'échecs, types d'erreur, secondes touchées. Testé contre un serveur local coupé au milieu de la mesure :

```
mesure : 100 req/s sur http://127.0.0.1:8099/health (Host: api.localhost)
durée 4.0 s | requêtes 401 | succès 192 | ÉCHECS 209 (52.12 %)
types : ConnectionRefusedError x208, RemoteDisconnected x1
premier échec à t=1.92 s, dernier à t=4.00 s, 4 seconde(s) touchée(s) : 1 2 3 4
```

### Déploiement naïf

`docker compose up -d --no-deps --force-recreate api` recrée les deux réplicas en même temps : entre l'arrêt des anciens et le passage `healthy` des nouveaux, Traefik n'a plus aucun backend pour `api.localhost` et répond en erreur. **Mesure non réalisée.**

### `deploy/rolling-update.sh`

1. vérifie la signature cosign des deux images (`VERSION` donnée) : **refus sans rien modifier** si l'une n'est pas signée ;
2. tire les images sur le serveur ;
3. premier déploiement : `up -d --wait` ; sinon, **pour chaque ancien réplica de l'API** :
   - `up -d --no-deps --no-recreate --scale api=N+1 --wait api` : démarre **un** réplica avec la nouvelle image et attend qu'il soit `healthy` ;
   - `docker stop -t 15` de **un** ancien réplica (SIGTERM), puis `rm` ;
   la capacité ne descend jamais sous N ;
4. recrée le worker (hors du chemin des requêtes : la file Redis absorbe la coupure).

Compatible avec le bash 3.2 de macOS (pas de `mapfile`).

### Rôle de chaque brique (et ce qui se passe sans)

| Brique | Rôle | Si on la retire |
|---|---|---|
| `HEALTHCHECK` / healthcheck Compose (`/ready`) | dit quand un conteneur est réellement prêt (base et Redis joignables) | Traefik route vers un conteneur qui démarre encore : erreurs à chaque démarrage |
| `start_period` | laisse le temps de démarrer sans compter d'échecs | un démarrage lent est déclaré `unhealthy` et redémarré en boucle |
| Traefik ne route que vers les conteneurs `healthy` (+ healthcheck de backend `/health`) | un nouveau réplica ne reçoit du trafic qu'une fois prêt | le trafic arrive dès le `start` du conteneur |
| `--wait` | le script attend `healthy` avant d'arrêter un ancien réplica | l'ancien est arrêté alors que le nouveau n'est pas prêt : moins de capacité, voire aucune |
| SIGTERM géré par l'API (TP01, `server.close()`) | arrête d'accepter, termine les requêtes en cours, sort proprement | sans gestion (ou sans forme exec), 10 s puis SIGKILL : requêtes coupées net |
| `stop_grace_period: 15s` / `stop -t 15` | délai laissé avant SIGKILL | une requête longue est tuée en cours |
| middleware `retry` de Traefik (`compose.prod.yml`) | rejoue sur un autre réplica une requête tombée sur un réplica en cours d'arrêt (connexion refusée) | quelques erreurs dans la fenêtre entre SIGTERM et la prise en compte de l'arrêt par Traefik |
| réplicas ≥ 2 | il reste toujours un réplica pour servir pendant le remplacement de l'autre | avec 1 seul réplica, coupure pendant le démarrage du nouveau |
| reverse proxy | point d'entrée stable qui suit dynamiquement les conteneurs (labels, événements Docker) | les clients visent un conteneur précis : impossible de basculer sans coupure |

**Mesure non réalisée** (objectif : 0 échec).

## 5. Rollback

`VERSION=<ancien sha> ./deploy/rolling-update.sh` : même procédure que pour monter de version. **Durée non mesurée** ; elle devrait être celle d'un rolling update sans téléchargement (deux remplacements successifs, chacun limité par le passage `healthy` du nouveau réplica, quelques secondes).

**Ce qui rend le rollback possible :**
- des **tags immuables** (`sha-<sha>`, `X.Y.Z`, jamais `latest`) : l'ancienne version est toujours désignée par le même tag ;
- les **images encore présentes sur le serveur** : pas de téléchargement, et pas de dépendance au registre pendant un incident ;
- une **base compatible** avec l'ancienne version du code ;
- des signatures liées au digest : l'ancienne version reste vérifiable.

**Migration de schéma non rétro-compatible** (renommer ou supprimer une colonne) : le rollback du code ne suffit plus, l'ancienne version plante sur le nouveau schéma, et pendant le rolling update les deux versions tournent **en même temps** sur la même base. Il faut découper en migrations compatibles (*expand / contract*) : (1) ajouter la nouvelle colonne en gardant l'ancienne, (2) déployer le code qui écrit les deux, (3) migrer les données, (4) déployer le code qui ne lit plus que la nouvelle, (5) supprimer l'ancienne colonne dans une release ultérieure. Chaque étape reste réversible. C'est la leçon du TP04 sur `sku` (colonne `NOT NULL` ajoutée avec une valeur par défaut pour ne pas casser les clients existants).

---

## Bonus

- **B1, Swarm** : `compose.swarm.yml` (validé par `docker stack config`), avec `update_config: { parallelism: 1, order: start-first, monitor: 15s, failure_action: rollback }` et `rollback_config`. Swarm fait nativement ce que fait le script : démarrer le nouveau, attendre `healthy`, arrêter l'ancien, et revenir en arrière tout seul si le nouveau échoue. Avec `traefik.swarm.lbswarm=true`, Traefik passe par l'IP virtuelle du service, et Swarm retire un réplica de la répartition avant de l'arrêter. Moins de code à maintenir et plus robuste (réconciliation continue, rollback automatique), au prix d'un orchestrateur à exploiter (Raft, réseau overlay) et d'un format de fichier plus limité (pas de `build`, pas de `depends_on` conditionnel). **Non exécuté.**
- **B2, GitOps pull** : un cron `docker compose pull && docker compose up -d` (ou watchtower) sur le serveur. Plus aucun accès SSH entrant depuis la CI, mais pas de porte de release (aucune vérification de signature si on ne l'ajoute pas), et avec `latest` on ne sait plus quelle version tourne ni comment revenir en arrière.
- **B3** : `docker compose publish` pousse le fichier Compose comme artefact OCI : la stack elle-même est versionnée et signable dans le registre.
- **B4, tests d'intégration en CI** : fait, job `integration` du workflow et étape `pr` de `ci-local.sh` (`compose up --wait` + `smoke-test.sh` + `compose down -v`).

---

## Premier passage sur la machine et corrections

| Étape | Résultat | Correction |
|---|---|---|
| `actionlint` sur le workflow | aucune erreur | - |
| `./ci-local.sh pr`, hadolint | `DL3006 warning: Always tag the version of an image explicitly` sur `FROM ${NODE_IMAGE}` / `FROM ${PY_IMAGE}` : hadolint 2.12 ne résout pas la valeur par défaut (épinglée) de l'`ARG` | `ci-local.sh` utilise une version récente de hadolint épinglée par digest ; le workflow ignore DL3006 avec un commentaire |
| construction de l'hôte de préprod | `unable to select packages: openssh-client-common-9.7_p1-r4 breaks: openssh-client-default-9.7_p1-r5` : le client SSH de l'image de base est plus ancien que le serveur à installer | `apk add --upgrade openssh-server openssh-client-common openssh-client-default` |
| étapes suivantes | non exécutées (dépendaient des deux précédentes) | - |

## Pour terminer le TP (non exécuté)

Avec le registre local (`docker run -d --name tp-registry -p 5050:5000 registry:2`), le builder (`docker buildx create --name shop-ci --driver docker-container --driver-opt network=host`) et l'hôte de préprod démarré :

```bash
./ci-local.sh pr
./ci-local.sh main                                    # pipeline + déploiement préprod
URL=http://127.0.0.1:8088/health ./deploy/measure-downtime.sh &      # mesure pendant chaque déploiement
docker --context preprod compose -f compose.yml -f compose.prod.yml up -d --no-deps --force-recreate api   # naïf
./ci-local.sh tag v1.5.0 && PROD_APPROVED_BY=theo ./ci-local.sh deploy-prod v1.5.0                         # rolling
time VERSION=sha-<sha> DEPLOY_CONTEXT=preprod REGISTRY=host.docker.internal:5050 VERIFY_REGISTRY=localhost:5050 ./deploy/rolling-update.sh   # rollback
```

Le script complet qui enchaîne ces étapes (création de l'hôte, clé SSH, contexte, mesures, Swarm, nettoyage) est prêt.
