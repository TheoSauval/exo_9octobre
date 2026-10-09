# Exercice Docker #4 - Deux conteneurs qui communiquent

**Objectif :** créer un réseau Docker, y connecter deux conteneurs équipés de `ping` et vérifier qu'ils se joignent par leur nom (DNS interne de Docker).

---

## 1. Créer un réseau dédié

```bash
docker network create reseau-exo4
docker network ls --filter name=reseau-exo4
```

```
NETWORK ID     NAME          DRIVER    SCOPE
e23d1d6bdd24   reseau-exo4   bridge    local
```

> Il faut un réseau créé par l'utilisateur : la résolution DNS par nom de conteneur ne fonctionne pas sur le réseau `bridge` par défaut.

## 2. Créer un premier conteneur et y installer `ping`

```bash
docker run -dit --name conteneur1 --network reseau-exo4 ubuntu
```

L'image `ubuntu` ne contient pas `ping` :

```bash
docker exec conteneur1 ping -c 1 localhost
```

```
OCI runtime exec failed: exec failed: unable to start container process: exec: "ping": executable file not found in $PATH: unknown
```

Installation du paquet `iputils-ping` :

```bash
docker exec conteneur1 bash -c "apt-get update && apt-get install -y iputils-ping"
docker exec conteneur1 ping -V
```

```
ping from iputils 20250605
```

> On peut aussi travailler en interactif : `docker exec -it conteneur1 bash`, puis `apt update && apt install -y iputils-ping`, puis `exit`.

## 3. Sauvegarder l'image avec `ping`

```bash
docker commit conteneur1 ubuntu-ping
docker images ubuntu-ping
```

```
sha256:372fa75381a610535698b74b4809bd7e3e00eb7412d2b36282352ff906ea8f81
REPOSITORY    TAG       IMAGE ID       CREATED                  SIZE
ubuntu-ping   latest    372fa75381a6   Less than a second ago   168MB
```

## 4. Créer le second conteneur à partir de cette image

Il est volontairement créé **sans** réseau, pour le connecter ensuite :

```bash
docker run -dit --name conteneur2 ubuntu-ping
docker exec conteneur2 ping -V
```

```
ping from iputils 20250605
```

`ping` est disponible directement, sans installation.

## 5. Vérifier et connecter les deux conteneurs au même réseau

Avant la connexion, seul `conteneur1` est sur le réseau :

```bash
docker network inspect reseau-exo4 --format '{{range .Containers}}{{.Name}} {{.IPv4Address}}{{println}}{{end}}'
```

```
conteneur1 172.24.0.2/16
```

Connexion de `conteneur2` :

```bash
docker network connect reseau-exo4 conteneur2
docker network inspect reseau-exo4 --format '{{range .Containers}}{{.Name}} {{.IPv4Address}}{{println}}{{end}}'
```

```
conteneur1 172.24.0.2/16
conteneur2 172.24.0.3/16
```

## 6. Tester la communication par le nom (DNS interne)

```bash
docker exec conteneur1 ping -c 3 conteneur2
```

```
PING conteneur2 (172.24.0.3) 56(84) bytes of data.
64 bytes from conteneur2.reseau-exo4 (172.24.0.3): icmp_seq=1 ttl=64 time=0.065 ms
64 bytes from conteneur2.reseau-exo4 (172.24.0.3): icmp_seq=2 ttl=64 time=0.022 ms
64 bytes from conteneur2.reseau-exo4 (172.24.0.3): icmp_seq=3 ttl=64 time=0.022 ms

--- conteneur2 ping statistics ---
3 packets transmitted, 3 received, 0% packet loss, time 2027ms
```

```bash
docker exec conteneur2 ping -c 3 conteneur1
```

```
PING conteneur1 (172.24.0.2) 56(84) bytes of data.
64 bytes from conteneur1.reseau-exo4 (172.24.0.2): icmp_seq=1 ttl=64 time=0.047 ms
64 bytes from conteneur1.reseau-exo4 (172.24.0.2): icmp_seq=2 ttl=64 time=0.035 ms
64 bytes from conteneur1.reseau-exo4 (172.24.0.2): icmp_seq=3 ttl=64 time=0.038 ms

--- conteneur1 ping statistics ---
3 packets transmitted, 3 received, 0% packet loss, time 2068ms
```

Les noms `conteneur1` et `conteneur2` sont résolus en IP par le serveur DNS intégré de Docker (réponse au format `conteneur2.reseau-exo4`). On obtient 0 % de perte dans les deux sens.

---

## Nettoyage

```bash
docker rm -f conteneur1 conteneur2
docker network rm reseau-exo4
```
