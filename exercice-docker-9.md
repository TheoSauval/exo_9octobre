# Exercice Docker #9 - API CRUD + API de logs conteneurisées

**Objectif :** deux APIs Spring Boot conteneurisées :
- une **API CRUD** de chiens (Hibernate + PostgreSQL), qui envoie un log à chaque appel ;
- une **API de logs** qui reçoit les logs (`POST`), les stocke dans un fichier et les restitue (`GET`).

Les deux APIs et la base tournent dans Docker et sont orchestrées par Docker Compose.

Fichiers : dossier `exo-09/` (`crud-api/`, `log-api/`, `compose.yaml`).

```
            HTTP :8080                       RestTemplate
 client ───────────────▶  crud-api  ───────────────────────▶  log-api  ──▶ /data/logs.jsonl (volume)
                              │       POST /api/v1/logs         ▲
                              │ JDBC                            │ HTTP :8082
                              ▼                                 │
                          db (PostgreSQL)              client (GET /api/v1/logs)
```

---

## 1. API de logs (`log-api`)

| Endpoint | Rôle |
|---|---|
| `GET /api/v1/logs` | tous les logs |
| `POST /api/v1/logs` | ajout d'un log |

Format d'un log : `message`, `source`, `timestamp`, `level` (énum `INFO | WARN | ERR`).

Stockage : fichier **JSON Lines** (un log JSON par ligne) dans `/data/logs.jsonl`, sur un volume Docker. Pas de base de données nécessaire.

### `LogLevel.java`

```java
package fr.ynov.logapi;

public enum LogLevel {
    INFO, WARN, ERR
}
```

### `LogEntry.java`

```java
package fr.ynov.logapi;

import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;

public record LogEntry(
        @NotBlank String message,
        @NotBlank String source,
        @NotBlank String timestamp,
        @NotNull LogLevel level
) {
}
```

### `LogStorage.java`

```java
package fr.ynov.logapi;

import com.fasterxml.jackson.databind.ObjectMapper;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;

import java.io.IOException;
import java.io.UncheckedIOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;
import java.util.ArrayList;
import java.util.List;

/**
 * Stocke les logs dans un fichier JSON Lines (un log JSON par ligne).
 */
@Component
public class LogStorage {

    private final Path file;
    private final ObjectMapper mapper;

    public LogStorage(@Value("${logs.file:/data/logs.jsonl}") String file, ObjectMapper mapper) throws IOException {
        this.file = Path.of(file);
        this.mapper = mapper;
        if (this.file.getParent() != null) {
            Files.createDirectories(this.file.getParent());
        }
    }

    public synchronized void append(LogEntry entry) {
        try {
            String line = mapper.writeValueAsString(entry) + System.lineSeparator();
            Files.writeString(file, line, StandardCharsets.UTF_8,
                    StandardOpenOption.CREATE, StandardOpenOption.APPEND);
        } catch (IOException e) {
            throw new UncheckedIOException(e);
        }
    }

    public synchronized List<LogEntry> findAll() {
        List<LogEntry> logs = new ArrayList<>();
        if (!Files.exists(file)) {
            return logs;
        }
        try {
            for (String line : Files.readAllLines(file, StandardCharsets.UTF_8)) {
                if (!line.isBlank()) {
                    logs.add(mapper.readValue(line, LogEntry.class));
                }
            }
        } catch (IOException e) {
            throw new UncheckedIOException(e);
        }
        return logs;
    }
}
```

### `LogController.java`

```java
package fr.ynov.logapi;

import jakarta.validation.Valid;
import org.springframework.http.HttpStatus;
import org.springframework.web.bind.annotation.*;

import java.util.List;

@RestController
@RequestMapping("/api/v1/logs")
public class LogController {

    private final LogStorage storage;

    public LogController(LogStorage storage) {
        this.storage = storage;
    }

    @GetMapping
    public List<LogEntry> findAll() {
        return storage.findAll();
    }

    @PostMapping
    @ResponseStatus(HttpStatus.CREATED)
    public LogEntry create(@Valid @RequestBody LogEntry entry) {
        storage.append(entry);
        return entry;
    }
}
```

### `application.properties`

```properties
spring.application.name=log-api
server.port=8080
logs.file=${LOGS_FILE:./data/logs.jsonl}
server.error.include-message=always
```

Le `pom.xml` contient `spring-boot-starter-web` et `spring-boot-starter-validation` (pas de JPA). `LogApiApplication.java` est la classe `@SpringBootApplication` standard.

---

## 2. API CRUD (`crud-api`)

Même base que l'exercice 8 : entité `Dog`, `DogRepository`, `DogController` avec les 5 endpoints `/api/v1/dogs`, driver PostgreSQL. On y ajoute l'envoi des logs.

### Règles de log

| Réponse HTTP | `level` | `message` |
|---|---|---|
| 2xx / 3xx | `INFO` | `HTTP <code>` |
| 4xx | `WARN` | message d'erreur de l'API |
| 5xx | `ERR` | message d'erreur de l'API |

- `source` = `[CrudAPI] <MÉTHODE> <chemin appelé>`
- `timestamp` = instant où l'erreur a été levée (ou fin de la requête si pas d'erreur)

### `LogClient.java` - client HTTP `RestTemplate`

```java
package fr.ynov.dogapi;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.client.SimpleClientHttpRequestFactory;
import org.springframework.stereotype.Component;
import org.springframework.web.client.RestTemplate;

import java.util.Map;

/**
 * Client HTTP (RestTemplate) qui envoie les logs à l'API de logs.
 */
@Component
public class LogClient {

    private static final Logger LOG = LoggerFactory.getLogger(LogClient.class);

    private final RestTemplate restTemplate;
    private final String url;

    public LogClient(@Value("${logs.api.url}") String url) {
        SimpleClientHttpRequestFactory factory = new SimpleClientHttpRequestFactory();
        factory.setConnectTimeout(2000);
        factory.setReadTimeout(2000);
        this.restTemplate = new RestTemplate(factory);
        this.url = url;
    }

    public void send(String message, String source, String timestamp, String level) {
        Map<String, String> body = Map.of(
                "message", message,
                "source", source,
                "timestamp", timestamp,
                "level", level);
        try {
            restTemplate.postForEntity(url, body, Void.class);
        } catch (Exception e) {
            // L'API CRUD doit continuer à fonctionner même si l'API de logs est indisponible
            LOG.warn("Impossible d'envoyer le log à {} : {}", url, e.getMessage());
        }
    }
}
```

### `ApiExceptionHandler.java` - capture des erreurs

```java
package fr.ynov.dogapi;

import jakarta.servlet.http.HttpServletRequest;
import org.springframework.http.HttpStatus;
import org.springframework.http.HttpStatusCode;
import org.springframework.http.ResponseEntity;
import org.springframework.http.converter.HttpMessageNotReadableException;
import org.springframework.web.ErrorResponse;
import org.springframework.web.bind.MethodArgumentNotValidException;
import org.springframework.web.bind.annotation.ExceptionHandler;
import org.springframework.web.bind.annotation.RestControllerAdvice;
import org.springframework.web.server.ResponseStatusException;

import java.time.Instant;
import java.util.Map;
import java.util.stream.Collectors;

/**
 * Transforme les exceptions en réponses JSON et mémorise le message d'erreur
 * et l'instant où il a été levé, pour que LoggingInterceptor l'envoie à l'API de logs.
 */
@RestControllerAdvice
public class ApiExceptionHandler {

    static final String ERROR_MESSAGE = "log.errorMessage";
    static final String ERROR_TIMESTAMP = "log.errorTimestamp";

    @ExceptionHandler(ResponseStatusException.class)
    public ResponseEntity<Map<String, Object>> handleStatus(ResponseStatusException ex, HttpServletRequest request) {
        return build(ex.getStatusCode(), ex.getReason(), request);
    }

    @ExceptionHandler(MethodArgumentNotValidException.class)
    public ResponseEntity<Map<String, Object>> handleValidation(MethodArgumentNotValidException ex, HttpServletRequest request) {
        String message = ex.getBindingResult().getFieldErrors().stream()
                .map(e -> e.getField() + " : " + e.getDefaultMessage())
                .collect(Collectors.joining(", "));
        return build(HttpStatus.BAD_REQUEST, "Requête invalide (" + message + ")", request);
    }

    @ExceptionHandler(HttpMessageNotReadableException.class)
    public ResponseEntity<Map<String, Object>> handleUnreadable(HttpMessageNotReadableException ex, HttpServletRequest request) {
        return build(HttpStatus.BAD_REQUEST, "Corps JSON illisible", request);
    }

    @ExceptionHandler(Exception.class)
    public ResponseEntity<Map<String, Object>> handleOther(Exception ex, HttpServletRequest request) {
        if (ex instanceof ErrorResponse errorResponse) {
            return build(errorResponse.getStatusCode(), ex.getMessage(), request);
        }
        return build(HttpStatus.INTERNAL_SERVER_ERROR, ex.getClass().getSimpleName() + " : " + ex.getMessage(), request);
    }

    private ResponseEntity<Map<String, Object>> build(HttpStatusCode status, String message, HttpServletRequest request) {
        String msg = message == null ? "Erreur" : message;
        request.setAttribute(ERROR_MESSAGE, msg);
        request.setAttribute(ERROR_TIMESTAMP, Instant.now().toString());
        return ResponseEntity.status(status).body(Map.<String, Object>of("status", status.value(), "error", msg));
    }
}
```

### `LoggingInterceptor.java` - un log par appel

```java
package fr.ynov.dogapi;

import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import org.springframework.stereotype.Component;
import org.springframework.web.servlet.HandlerInterceptor;

import java.time.Instant;

/**
 * Après chaque appel à /api/**, envoie un log à l'API de logs :
 * INFO pour 2xx/3xx, WARN pour 4xx, ERR pour 5xx.
 */
@Component
public class LoggingInterceptor implements HandlerInterceptor {

    private final LogClient logClient;

    public LoggingInterceptor(LogClient logClient) {
        this.logClient = logClient;
    }

    @Override
    public void afterCompletion(HttpServletRequest request, HttpServletResponse response, Object handler, Exception ex) {
        int status = response.getStatus();
        String level = status >= 500 ? "ERR" : status >= 400 ? "WARN" : "INFO";

        Object error = request.getAttribute(ApiExceptionHandler.ERROR_MESSAGE);
        Object errorTime = request.getAttribute(ApiExceptionHandler.ERROR_TIMESTAMP);

        String message = error != null ? error.toString() : "HTTP " + status;
        String timestamp = errorTime != null ? errorTime.toString() : Instant.now().toString();
        String source = "[CrudAPI] " + request.getMethod() + " " + request.getRequestURI();

        logClient.send(message, source, timestamp, level);
    }
}
```

### `WebConfig.java`

```java
package fr.ynov.dogapi;

import org.springframework.context.annotation.Configuration;
import org.springframework.web.servlet.config.annotation.InterceptorRegistry;
import org.springframework.web.servlet.config.annotation.WebMvcConfigurer;

@Configuration
public class WebConfig implements WebMvcConfigurer {

    private final LoggingInterceptor loggingInterceptor;

    public WebConfig(LoggingInterceptor loggingInterceptor) {
        this.loggingInterceptor = loggingInterceptor;
    }

    @Override
    public void addInterceptors(InterceptorRegistry registry) {
        registry.addInterceptor(loggingInterceptor).addPathPatterns("/api/**");
    }
}
```

### `application.properties`

```properties
spring.application.name=crud-api
server.port=8080

# Valeurs par défaut = développement local (BdD Docker exposée sur le port 5433 de l'hôte)
# Dans Docker, elles sont remplacées par les variables d'environnement.
spring.datasource.url=${DB_URL:jdbc:postgresql://localhost:5433/dogsdb}
spring.datasource.username=${DB_USER:dogs}
spring.datasource.password=${DB_PASSWORD:dogspass}

spring.jpa.hibernate.ddl-auto=update
spring.jpa.open-in-view=false
server.error.include-message=always

# API de logs (nom du service Docker)
logs.api.url=${LOGS_API_URL:http://localhost:8082/api/v1/logs}
# Échoue vite si la BdD est indisponible (pour générer un log ERR rapidement)
spring.datasource.hikari.connection-timeout=3000
```

---

## 3. Dockerfile (identique pour les deux APIs)

```dockerfile
# Étape 1 : compilation avec Maven (aucun JDK à installer sur l'hôte)
FROM maven:3.9-eclipse-temurin-21 AS build
WORKDIR /app
COPY pom.xml .
RUN mvn -q dependency:go-offline
COPY src ./src
RUN mvn -q package -DskipTests

# Étape 2 : image d'exécution légère (JRE seul)
FROM eclipse-temurin:21-jre
WORKDIR /app
COPY --from=build /app/target/app.jar app.jar
EXPOSE 8080
ENTRYPOINT ["java", "-jar", "app.jar"]
```

## 4. `compose.yaml`

```yaml
services:
  db:
    image: postgres:16
    environment:
      POSTGRES_DB: dogsdb
      POSTGRES_USER: dogs
      POSTGRES_PASSWORD: dogspass
    ports:
      - "5433:5432"          # accès depuis l'hôte (développement local)
    volumes:
      - db-data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U dogs -d dogsdb"]
      interval: 2s
      retries: 30

  log-api:
    build: ./log-api
    image: log-api
    environment:
      LOGS_FILE: /data/logs.jsonl
    ports:
      - "8082:8080"
    volumes:
      - logs-data:/data

  crud-api:
    build: ./crud-api
    image: crud-api
    environment:
      DB_URL: jdbc:postgresql://db:5432/dogsdb
      DB_USER: dogs
      DB_PASSWORD: dogspass
      LOGS_API_URL: http://log-api:8080/api/v1/logs
    ports:
      - "8080:8080"
    depends_on:
      db:
        condition: service_healthy
      log-api:
        condition: service_started

volumes:
  db-data:
  logs-data:
```

- Les APIs se joignent par **nom de service** : `db`, `log-api`.
- `depends_on: condition: service_healthy` : l'API CRUD attend que PostgreSQL réponde au `healthcheck` avant de démarrer.
- `db` reste publiée sur `5433` pour le développement local. Les APIs en local utilisent alors `localhost:5433` et `localhost:8082` (valeurs par défaut des `application.properties`).

---

## 5. Construire et lancer

```bash
cd exo-09
docker compose build
docker images --filter reference=log-api --filter reference=crud-api
```

```
REPOSITORY   TAG       IMAGE ID       CREATED                  SIZE
crud-api     latest    e14ecf39aed2   Less than a second ago   396MB
log-api      latest    2a9550d04c5b   53 seconds ago           370MB
```

```bash
docker compose up -d
```

```
 Network exo-09_default  Created
 Volume "exo-09_db-data"  Created
 Volume "exo-09_logs-data"  Created
 Container exo-09-db-1  Started
 Container exo-09-log-api-1  Started
 Container exo-09-db-1  Healthy
 Container exo-09-crud-api-1  Started
```

```bash
docker compose ps --format 'table {{.Service}}\t{{.Image}}\t{{.Ports}}\t{{.Status}}'
```

```
SERVICE    IMAGE         PORTS                    STATUS
crud-api   crud-api      0.0.0.0:8080->8080/tcp   Up 4 seconds
db         postgres:16   0.0.0.0:5433->5432/tcp   Up 7 seconds (healthy)
log-api    log-api       0.0.0.0:8082->8080/tcp   Up 7 seconds
```

---

## 6. Tests

### Appels réussis → `INFO`

```bash
curl -s -X POST http://localhost:8080/api/v1/dogs -H 'Content-Type: application/json' \
  -d '{"name":"Rex","breed":"Berger allemand","birthDate":"2019-05-10","sterilized":true}'
```

```json
{"id":1,"name":"Rex","breed":"Berger allemand","birthDate":"2019-05-10","sterilized":true}
```

```bash
curl -s -X POST http://localhost:8080/api/v1/dogs -H 'Content-Type: application/json' \
  -d '{"name":"Filou","breed":"Jack Russell","birthDate":"2021-09-02","sterilized":false}'
```

```json
{"id":2,"name":"Filou","breed":"Jack Russell","birthDate":"2021-09-02","sterilized":false}
```

```bash
curl -s http://localhost:8080/api/v1/dogs
```

```json
[{"id":1,"name":"Rex","breed":"Berger allemand","birthDate":"2019-05-10","sterilized":true},{"id":2,"name":"Filou","breed":"Jack Russell","birthDate":"2021-09-02","sterilized":false}]
```

```bash
curl -s -X PUT http://localhost:8080/api/v1/dogs/2 -H 'Content-Type: application/json' \
  -d '{"name":"Filou","breed":"Jack Russell","birthDate":"2021-09-02","sterilized":true}'
```

```json
{"id":2,"name":"Filou","breed":"Jack Russell","birthDate":"2021-09-02","sterilized":true}
```

```bash
curl -s -o /dev/null -w 'HTTP %{http_code}\n' -X DELETE http://localhost:8080/api/v1/dogs/1
```

```
HTTP 204
```

### Erreurs client → `WARN`

```bash
curl -s -w '\nHTTP %{http_code}\n' http://localhost:8080/api/v1/dogs/999
```

```
{"status":404,"error":"Chien 999 introuvable"}
HTTP 404
```

```bash
curl -s -w '\nHTTP %{http_code}\n' -X POST http://localhost:8080/api/v1/dogs \
  -H 'Content-Type: application/json' -d '{"breed":"Caniche"}'
```

```
{"status":400,"error":"Requête invalide (name : must not be blank)"}
HTTP 400
```

```bash
curl -s -w '\nHTTP %{http_code}\n' -X DELETE http://localhost:8080/api/v1/dogs/999
```

```
{"status":404,"error":"Chien 999 introuvable"}
HTTP 404
```

### Erreur serveur → `ERR` (base de données arrêtée)

```bash
docker compose stop db
curl -s -w '\nHTTP %{http_code}\n' http://localhost:8080/api/v1/dogs
docker compose start db
```

```
{"status":500,"error":"JpaSystemException : Unable to rollback against JDBC Connection"}
HTTP 500
```

---

## 7. Logs collectés par l'API de logs

```bash
curl -s http://localhost:8082/api/v1/logs
```

Sortie réelle, mise en forme sur plusieurs lignes pour la lisibilité :

```json
[
  {"message":"HTTP 201","source":"[CrudAPI] POST /api/v1/dogs","timestamp":"2026-10-09T08:45:32.205157802Z","level":"INFO"},
  {"message":"HTTP 201","source":"[CrudAPI] POST /api/v1/dogs","timestamp":"2026-10-09T08:45:32.228204052Z","level":"INFO"},
  {"message":"HTTP 200","source":"[CrudAPI] GET /api/v1/dogs","timestamp":"2026-10-09T08:45:32.252024385Z","level":"INFO"},
  {"message":"HTTP 200","source":"[CrudAPI] PUT /api/v1/dogs/2","timestamp":"2026-10-09T08:45:32.447661677Z","level":"INFO"},
  {"message":"HTTP 204","source":"[CrudAPI] DELETE /api/v1/dogs/1","timestamp":"2026-10-09T08:45:32.488729719Z","level":"INFO"},
  {"message":"Chien 999 introuvable","source":"[CrudAPI] GET /api/v1/dogs/999","timestamp":"2026-10-09T08:45:32.524771302Z","level":"WARN"},
  {"message":"Requête invalide (name : must not be blank)","source":"[CrudAPI] POST /api/v1/dogs","timestamp":"2026-10-09T08:45:32.563058094Z","level":"WARN"},
  {"message":"Chien 999 introuvable","source":"[CrudAPI] DELETE /api/v1/dogs/999","timestamp":"2026-10-09T08:45:32.587407969Z","level":"WARN"},
  {"message":"JpaSystemException : Unable to rollback against JDBC Connection","source":"[CrudAPI] GET /api/v1/dogs","timestamp":"2026-10-09T08:45:32.851778177Z","level":"ERR"}
]
```

Contenu du fichier de stockage dans le conteneur `log-api` :

```bash
docker compose exec -T log-api cat /data/logs.jsonl
```

```
{"message":"HTTP 201","source":"[CrudAPI] POST /api/v1/dogs","timestamp":"2026-10-09T08:45:32.205157802Z","level":"INFO"}
{"message":"HTTP 201","source":"[CrudAPI] POST /api/v1/dogs","timestamp":"2026-10-09T08:45:32.228204052Z","level":"INFO"}
{"message":"HTTP 200","source":"[CrudAPI] GET /api/v1/dogs","timestamp":"2026-10-09T08:45:32.252024385Z","level":"INFO"}
{"message":"HTTP 200","source":"[CrudAPI] PUT /api/v1/dogs/2","timestamp":"2026-10-09T08:45:32.447661677Z","level":"INFO"}
{"message":"HTTP 204","source":"[CrudAPI] DELETE /api/v1/dogs/1","timestamp":"2026-10-09T08:45:32.488729719Z","level":"INFO"}
{"message":"Chien 999 introuvable","source":"[CrudAPI] GET /api/v1/dogs/999","timestamp":"2026-10-09T08:45:32.524771302Z","level":"WARN"}
{"message":"Requête invalide (name : must not be blank)","source":"[CrudAPI] POST /api/v1/dogs","timestamp":"2026-10-09T08:45:32.563058094Z","level":"WARN"}
{"message":"Chien 999 introuvable","source":"[CrudAPI] DELETE /api/v1/dogs/999","timestamp":"2026-10-09T08:45:32.587407969Z","level":"WARN"}
{"message":"JpaSystemException : Unable to rollback against JDBC Connection","source":"[CrudAPI] GET /api/v1/dogs","timestamp":"2026-10-09T08:45:32.851778177Z","level":"ERR"}
```

> Avant ces tests, le fichier de logs a été vidé (`docker compose exec log-api sh -c ': > /data/logs.jsonl'`) pour ne garder que les appels de test.

Chaque appel à l'API CRUD a produit un log avec le bon niveau (5 `INFO`, 3 `WARN`, 1 `ERR`). La communication API CRUD → API de logs passe par le réseau Compose, avec le nom de service `log-api`.

> Si l'API de logs est indisponible, l'API CRUD continue de répondre : `LogClient` intercepte l'erreur et se contente d'écrire un avertissement dans ses propres logs.

---

## Nettoyage

```bash
docker compose down        # garde les volumes (base + fichier de logs)
docker compose down -v     # supprime aussi les volumes
```
