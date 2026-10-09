# Exercice Docker #10 - Docker Compose : variables d'environnement et volumes

**Objectif :** conteneuriser l'application Spring Boot de gestion de notes fournie (dossier `exercice10` du dépôt) avec Docker Compose :
- **variables d'environnement** : toute la configuration vient d'un fichier `.env`, sans modifier le code ;
- **volumes** : les données PostgreSQL et les fichiers uploadés survivent aux redémarrages.

Fichiers : dossier `exo-10/` (code de l'application fourni + `Dockerfile`, `.env`, `docker-compose.yml`).

```
app (Spring Boot :8080) ──▶ db (PostgreSQL :5432)
        │                          │
   volume uploads            volume pg_data
        └──── configuration : fichier .env ────┘
```

---

## Partie 1 : fichier `.env`

```bash
# Application
APP_NAME=Notes Manager
APP_VERSION=1.0.0
APP_ENV=production
APP_PORT=8080

# Base de données
DB_NAME=notesdb
DB_USER=admin
DB_PASSWORD=secret123

# Fichiers
MAX_FILE_SIZE=10MB

# Logs
LOG_LEVEL=INFO
SHOW_SQL=false
```

Docker Compose lit automatiquement le fichier `.env` placé à côté du `docker-compose.yml` et remplace les `${VARIABLE}`.

Le code n'est pas modifié : l'`application.yml` fourni lit déjà ces variables, avec une valeur par défaut pour chacune.

```yaml
spring:
  application:
    name: ${APP_NAME:Notes App}
  datasource:
    url: jdbc:postgresql://${DB_HOST:localhost}:${DB_PORT:5432}/${DB_NAME:notesdb}
    username: ${DB_USER:admin}
    password: ${DB_PASSWORD:secret}
app:
  upload-path: ${UPLOAD_PATH:/app/uploads}
```

## Dockerfile de l'application

Le dépôt ne fournit pas de Dockerfile, il faut donc l'écrire. Il est multi-stage : la compilation se fait dans Docker avec Maven et le JDK 17 (le `pom.xml` cible Java 17), puis l'image finale ne garde que le JRE et le `.jar`.

```dockerfile
# Étape 1 : compilation avec Maven + JDK 17 (rien à installer sur l'hôte)
FROM maven:3.9-eclipse-temurin-17 AS build
WORKDIR /app
COPY pom.xml .
RUN mvn -q dependency:go-offline
COPY src ./src
RUN mvn -q package -DskipTests

# Étape 2 : image d'exécution (JRE seul)
FROM eclipse-temurin:17-jre
WORKDIR /app
COPY --from=build /app/target/notes-app-1.0.0.jar app.jar
EXPOSE 8080
ENTRYPOINT ["java", "-jar", "app.jar"]
```

`.dockerignore` :

```
target/
.env
```

Le `.env` est exclu du contexte de build : les secrets ne doivent pas finir dans l'image. Ils sont injectés au lancement par Compose.

## Partie 2 : `docker-compose.yml`

```yaml
services:
  db:
    image: postgres:16
    environment:
      # Méthode 1 : valeurs lues dans le fichier .env
      POSTGRES_DB: ${DB_NAME}
      POSTGRES_USER: ${DB_USER}
      POSTGRES_PASSWORD: ${DB_PASSWORD}
    volumes:
      - pg_data:/var/lib/postgresql/data          # volume nommé : données PostgreSQL
      - ./init-db:/docker-entrypoint-initdb.d:ro   # script d'init (1er démarrage seulement)
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${DB_USER} -d ${DB_NAME}"]
      interval: 3s
      retries: 20

  app:
    build: .
    image: notes-app
    ports:
      - "${APP_PORT:-8080}:8080"
    environment:
      # Méthode 1 : depuis le fichier .env
      APP_NAME: ${APP_NAME}
      APP_VERSION: ${APP_VERSION}
      APP_ENV: ${APP_ENV}
      DB_NAME: ${DB_NAME}
      DB_USER: ${DB_USER}
      DB_PASSWORD: ${DB_PASSWORD}
      # Méthode 2 : valeur en dur
      DB_HOST: db
      DB_PORT: "5432"
      UPLOAD_PATH: /app/uploads
      # Méthode 3 : avec valeur par défaut si absente du .env
      MAX_FILE_SIZE: ${MAX_FILE_SIZE:-5MB}
      LOG_LEVEL: ${LOG_LEVEL:-INFO}
      SHOW_SQL: ${SHOW_SQL:-false}
    volumes:
      - uploads:/app/uploads                       # volume nommé : fichiers uploadés
    depends_on:
      db:
        condition: service_healthy

volumes:
  pg_data:
  uploads:
```

### Les 3 méthodes d'injection utilisées

| Méthode | Exemple | Effet |
|---|---|---|
| 1. Depuis le `.env` | `APP_NAME: ${APP_NAME}` | valeur lue dans `.env` |
| 2. Valeur en dur | `DB_HOST: db` | toujours la même (`db` = nom du service) |
| 3. Avec valeur par défaut | `LOG_LEVEL: ${LOG_LEVEL:-INFO}` | `INFO` si la variable est absente du `.env` |

### Les volumes

| Volume | Monté sur | Contenu |
|---|---|---|
| `pg_data` (nommé) | `/var/lib/postgresql/data` | données PostgreSQL |
| `uploads` (nommé) | `/app/uploads` | fichiers uploadés par l'API |
| `./init-db` (bind mount, lecture seule) | `/docker-entrypoint-initdb.d` | script `01-data.sql`, exécuté seulement si `pg_data` est vide |

`depends_on: condition: service_healthy` fait attendre l'application jusqu'à ce que PostgreSQL réponde au `healthcheck` (`pg_isready`).

---

## Validation

### Test 1 : Démarrage

```bash
cd exo-10
docker compose up -d --build
docker compose ps
```

```
 Network exo-10_default  Created
 Volume "exo-10_pg_data"  Created
 Volume "exo-10_uploads"  Created
 Container exo-10-db-1  Started
 Container exo-10-db-1  Healthy
 Container exo-10-app-1  Started
```

```
SERVICE   IMAGE         PORTS                    STATUS
app       notes-app     0.0.0.0:8080->8080/tcp   Up Less than a second
db        postgres:16   5432/tcp                 Up 3 seconds (healthy)
```

```bash
curl http://localhost:8080/api/info/health
```

```json
{"application":"UP","database":"UP","dbProduct":"PostgreSQL"}
```

### Test 2 : Variables d'environnement

```bash
curl http://localhost:8080/api/info/env
```

```json
{"APP_NAME":"Notes Manager","APP_VERSION":"1.0.0","APP_ENV":"production","DB_HOST":"db","DB_PORT":"5432","DB_NAME":"notesdb","DB_USER":"admin","UPLOAD_PATH":"/app/uploads","MAX_FILE_SIZE":"10MB","LOG_LEVEL":"INFO","SHOW_SQL":"false"}
```

On retrouve les valeurs du `.env` (`Notes Manager`, `production`, `10MB`) et les valeurs en dur (`db`, `5432`, `/app/uploads`). `DB_PASSWORD` n'est pas exposé par cet endpoint.

```bash
curl http://localhost:8080/api/info/app
```

```json
{"name":"Notes Manager","version":"1.0.0","environment":"production","uploadPath":"/app/uploads"}
```

### Test 3 : Créer des données

Notes présentes au départ (insérées par `init-db/01-data.sql`) :

```bash
curl http://localhost:8080/api/notes
```

```json
[{"id":1,"title":"Bienvenue","content":"Ceci est votre première note.","category":"PERSONAL","priority":"MEDIUM","attachmentPath":null,...},
 {"id":2,"title":"Liste de courses","content":"Pain, lait, oeufs","category":"PERSONAL","priority":"LOW","attachmentPath":null,...},
 {"id":3,"title":"Réunion projet","content":"Préparer la présentation Docker","category":"WORK","priority":"HIGH","attachmentPath":null,...}]
```

Créer une note :

```bash
curl -X POST http://localhost:8080/api/notes \
  -H 'Content-Type: application/json' \
  -d '{"title":"Test persistance","content":"Cette note doit survivre au redémarrage","category":"WORK","priority":"HIGH"}'
```

```json
{"id":4,"title":"Test persistance","content":"Cette note doit survivre au redémarrage","category":"WORK","priority":"HIGH","attachmentPath":null,"createdAt":"2026-10-09T12:45:57.380580671","updatedAt":"2026-10-09T12:45:57.380595838"}
```

Ajouter une pièce jointe à cette note, pour tester aussi le volume `uploads` :

```bash
echo 'Pièce jointe de test - exercice 10' > /tmp/piece-jointe.txt
curl -F file=@/tmp/piece-jointe.txt -F noteId=4 http://localhost:8080/api/files/upload
```

```json
{"originalName":"piece-jointe.txt","filename":"17f61a80-e5e6-4c92-ad81-1cac3b5db6f4.txt","size":36}
```

Vérifier :

```bash
curl http://localhost:8080/api/notes/4
curl http://localhost:8080/api/files
docker volume ls --filter name=exo-10
```

```json
{"id":4,"title":"Test persistance","content":"Cette note doit survivre au redémarrage","category":"WORK","priority":"HIGH","attachmentPath":"17f61a80-e5e6-4c92-ad81-1cac3b5db6f4.txt","createdAt":"2026-10-09T12:45:57.380581","updatedAt":"2026-10-09T12:45:57.432911"}
["17f61a80-e5e6-4c92-ad81-1cac3b5db6f4.txt"]
```

```
DRIVER    VOLUME NAME
local     exo-10_pg_data
local     exo-10_uploads
```

### Test 4 : Persistance des données

Arrêter **sans** supprimer les volumes (les conteneurs et le réseau sont supprimés, pas les volumes) :

```bash
docker compose down
```

```
 Container exo-10-app-1  Removed
 Container exo-10-db-1  Removed
 Network exo-10_default  Removed
```

Redémarrer, attendre 20 secondes, puis vérifier :

```bash
docker compose up -d
sleep 20
curl "http://localhost:8080/api/notes/search?q=persistance"
curl http://localhost:8080/api/files
```

```json
[{"id":4,"title":"Test persistance","content":"Cette note doit survivre au redémarrage","category":"WORK","priority":"HIGH","attachmentPath":"17f61a80-e5e6-4c92-ad81-1cac3b5db6f4.txt","createdAt":"2026-10-09T12:45:57.380581","updatedAt":"2026-10-09T12:45:57.432911"}]
["17f61a80-e5e6-4c92-ad81-1cac3b5db6f4.txt"]
```

La note « Test persistance » et sa pièce jointe sont toujours là : les volumes `pg_data` et `uploads` ont été conservés.

### Test 5 : Perte des données

Arrêter **et** supprimer les volumes :

```bash
docker compose down -v
```

```
 Container exo-10-app-1  Removed
 Container exo-10-db-1  Removed
 Volume exo-10_uploads  Removed
 Volume exo-10_pg_data  Removed
 Network exo-10_default  Removed
```

Redémarrer puis vérifier :

```bash
docker compose up -d
curl http://localhost:8080/api/notes
curl http://localhost:8080/api/files
```

```json
[{"id":1,"title":"Bienvenue","content":"Ceci est votre première note.","category":"PERSONAL","priority":"MEDIUM","attachmentPath":null,...},
 {"id":2,"title":"Liste de courses","content":"Pain, lait, oeufs","category":"PERSONAL","priority":"LOW","attachmentPath":null,...},
 {"id":3,"title":"Réunion projet","content":"Préparer la présentation Docker","category":"WORK","priority":"HIGH","attachmentPath":null,...}]
[]
```

La note « Test persistance » et la pièce jointe ont disparu. Il ne reste que les 3 notes du script d'initialisation, ré-exécuté parce que le volume `pg_data` est de nouveau vide.

### Test 6 : Modifier une variable

Dans `.env` :

```bash
APP_NAME=Mon Application Modifiée
```

Recréer le conteneur `app` (Compose détecte que sa configuration a changé) :

```bash
docker compose up -d app
```

```
 Container exo-10-db-1  Running
 Container exo-10-app-1  Recreate
 Container exo-10-app-1  Recreated
 Container exo-10-app-1  Started
```

Vérifier le changement :

```bash
curl http://localhost:8080/api/info/app
```

```json
{"name":"Mon Application Modifiée","version":"1.0.0","environment":"production","uploadPath":"/app/uploads"}
```

Le nom a changé sans modifier le code ni reconstruire l'image : seul le conteneur `app` a été recréé, et `db` a continué de tourner.

> Un simple `docker compose restart app` ne suffirait pas : `restart` redémarre le conteneur avec son ancienne configuration. Il faut `up -d`, qui recrée le conteneur avec les nouvelles variables.

---

## Nettoyage

```bash
docker compose down        # garde les volumes
docker compose down -v     # supprime aussi les volumes
```
