# Exercice Docker #1 - Image Ubuntu + NGINX

**Objectif :** réaliser une image de conteneur compatible avec NGINX à partir d'un conteneur Ubuntu.

---

## 1. Créer un conteneur Ubuntu et entrer dedans

```bash
docker run -it --name ubuntu-exo ubuntu bash
```

- `run` : crée et démarre un conteneur à partir de l'image `ubuntu` (téléchargée automatiquement si absente)
- `-it` : mode interactif avec un terminal
- `--name ubuntu-exo` : nom du conteneur
- `bash` : shell lancé dans le conteneur

Sortie :

```
Unable to find image 'ubuntu:latest' locally
latest: Pulling from library/ubuntu
...
Status: Downloaded newer image for ubuntu:latest
root@c0f6ddb447cf:/#
```

## 2. Mettre à jour les paquets

```bash
apt update
```

## 3. Installer NGINX

```bash
apt install -y nginx
```

Vérification :

```bash
nginx -v
```

```
nginx version: nginx/1.28.3 (Ubuntu)
```

> Le message `invoke-rc.d: policy-rc.d denied execution of start` est normal : un conteneur n'a pas de système d'init pour démarrer le service automatiquement. NGINX est bien installé.

## 4. Sortir du conteneur

```bash
exit
```

## 5. Sauvegarder le conteneur en tant que nouvelle image

```bash
docker commit ubuntu-exo ubuntu-nginx
```

```
sha256:2a74243b8c25939a85cec89d9ab15fad3f9c06572324e6ed6375dc234c46ec58
```

## 6. Vérifier que l'image existe

```bash
docker images ubuntu-nginx
```

```
REPOSITORY     TAG       IMAGE ID       CREATED                  SIZE
ubuntu-nginx   latest    2a74243b8c25   Less than a second ago   167MB
```

---

## 7. Tester l'image

```bash
docker run -d --name test-nginx -p 8080:80 ubuntu-nginx nginx -g "daemon off;"
docker ps --filter name=test-nginx
```

```
NAMES        IMAGE          PORTS                  STATUS
test-nginx   ubuntu-nginx   0.0.0.0:8080->80/tcp   Up 2 seconds
```

```bash
curl -s http://localhost:8080 | grep -o '<title>.*</title>'
```

```
<title>Welcome to nginx!</title>
```

`nginx -g "daemon off;"` garde NGINX au premier plan. Sans cette option, NGINX passe en arrière-plan, le processus principal se termine et le conteneur s'arrête aussitôt (l'image commitée n'a pas de commande par défaut qui lance NGINX).

Nettoyage :

```bash
docker rm -f test-nginx
```
