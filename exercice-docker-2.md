# Exercice Docker #2 - Déployer le jeu 2048

**Objectif :** déployer une image du jeu 2048 depuis Docker Hub et y accéder depuis le navigateur de l'ordinateur hôte.

---

## 1. Trouver une image 2048 sur Docker Hub

```bash
docker search 2048 --limit 5
```

```
NAME                 DESCRIPTION                                     STARS     OFFICIAL
blackicebird/2048    2048 with logging                               8
runseb/2048          The 2048 game                                   0
kubespheredev/2048   A docker image for popular game 2048(https:/…   0
sagi123/2048         2048 game   docker run -p 8080:80 --name 204…   0
oats87/2048          2048 Game                                       1
```

Image retenue : **`sagi123/2048`**.

> Les images plus anciennes comme `alexwhen/docker-2048` ou `runseb/2048` ne se téléchargent plus. Elles utilisent le format « Image manifest v2, schema 1 », que les versions récentes de Docker refusent :
> ```
> [DEPRECATION NOTICE] Docker Image Format v1 and Docker Image manifest version 2, schema 1 support is disabled by default…
> ```

## 2. Récupérer l'image localement

```bash
docker pull sagi123/2048
```

```
Using default tag: latest
latest: Pulling from sagi123/2048
Digest: sha256:56ec2a7d3c170a482f8696c99fbf252fa68c4dafc6f041243b7fac42d47a7388
Status: Image is up to date for sagi123/2048:latest
docker.io/sagi123/2048:latest
```

Port exposé et architecture de l'image :

```bash
docker image inspect sagi123/2048 --format '{{.Config.ExposedPorts}} {{.Architecture}}'
```

```
map[80/tcp:{}] arm64
```

Le jeu écoute sur le port **80** du conteneur. L'image est en arm64, donc compatible avec un Mac Apple Silicon.

## 3. Vérifier que le port 8080 est libre sur l'hôte

```bash
lsof -nP -iTCP:8080 -sTCP:LISTEN
```

Aucune sortie : le port 8080 est libre. Sinon, on utiliserait le port 8090.

## 4. Lancer le conteneur

```bash
docker run -d --name jeu-2048 -p 8080:80 sagi123/2048
```

```
917c960516a760ef22fa5f8b56205631d52d88e18c5eaa69d272d0130b9943b7
```

- `-d` : lance le conteneur en arrière-plan
- `--name jeu-2048` : nom du conteneur
- `-p 8080:80` : relie le port **8080 de l'hôte** au port **80 du conteneur**

```bash
docker ps --filter name=jeu-2048
```

```
NAMES      IMAGE          PORTS                  STATUS
jeu-2048   sagi123/2048   0.0.0.0:8080->80/tcp   Up 2 seconds
```

```bash
curl -s -o /dev/null -w 'HTTP %{http_code}\n' http://localhost:8080
```

```
HTTP 200
```

## 5. Accéder à l'application depuis le navigateur

Ouvrir http://localhost:8080 dans le navigateur de l'ordinateur (pas celui du conteneur) :

![Jeu 2048 dans le navigateur](captures/exo-02-navigateur.jpg)

---

## Nettoyage

```bash
docker rm -f jeu-2048
```
