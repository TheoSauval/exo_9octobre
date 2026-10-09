# Exercice Docker #8 - API Spring Boot conteneurisée (CRUD chiens)

**Objectif :** une API Java Spring Boot (Hibernate/JPA) qui fait un CRUD sur des chiens, connectée à une base PostgreSQL. L'API et la base tournent toutes les deux dans Docker.

Fichiers : dossier `exo-08/` (projet Maven dans `exo-08/dog-api/`).

| Endpoint | Rôle |
|---|---|
| `GET /api/v1/dogs` | liste des chiens |
| `GET /api/v1/dogs/{dogId}` | détail d'un chien |
| `POST /api/v1/dogs` | ajout |
| `PUT /api/v1/dogs/{dogId}` | modification |
| `DELETE /api/v1/dogs/{dogId}` | suppression |

---

## 1. Base de données PostgreSQL dans Docker (port forwarding)

```bash
docker network create reseau-exo8

docker run -d --name dogs-db --network reseau-exo8 \
  -p 5433:5432 \
  -e POSTGRES_DB=dogsdb -e POSTGRES_USER=dogs -e POSTGRES_PASSWORD=dogspass \
  postgres:16

docker exec dogs-db pg_isready -U dogs -d dogsdb
```

```
/var/run/postgresql:5432 - accepting connections
```

```
NAMES     IMAGE         PORTS                    STATUS
dogs-db   postgres:16   0.0.0.0:5433->5432/tcp   Up 1 second
```

`-p 5433:5432` rend la base accessible depuis l'hôte sur `localhost:5433` pour le développement local. Le port 5433 évite un conflit avec un éventuel PostgreSQL déjà en écoute sur le 5432.

## 2. Projet Spring Boot

Dépendances : Spring Web, Spring Data JPA (Hibernate), Validation, et le **driver `org.postgresql:postgresql`**. C'est le driver JDBC qu'Hibernate utilise pour parler à PostgreSQL ; pour MySQL, ce serait `com.mysql:mysql-connector-j`.

### `pom.xml`

```xml
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 https://maven.apache.org/xsd/maven-4.0.0.xsd">
  <modelVersion>4.0.0</modelVersion>

  <parent>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-parent</artifactId>
    <version>3.3.5</version>
    <relativePath/>
  </parent>

  <groupId>fr.ynov</groupId>
  <artifactId>dog-api</artifactId>
  <version>1.0.0</version>
  <name>dog-api</name>

  <properties>
    <java.version>21</java.version>
  </properties>

  <dependencies>
    <dependency>
      <groupId>org.springframework.boot</groupId>
      <artifactId>spring-boot-starter-web</artifactId>
    </dependency>
    <dependency>
      <groupId>org.springframework.boot</groupId>
      <artifactId>spring-boot-starter-data-jpa</artifactId>
    </dependency>
    <dependency>
      <groupId>org.springframework.boot</groupId>
      <artifactId>spring-boot-starter-validation</artifactId>
    </dependency>
    <!-- Driver JDBC PostgreSQL utilisé par Hibernate -->
    <dependency>
      <groupId>org.postgresql</groupId>
      <artifactId>postgresql</artifactId>
      <scope>runtime</scope>
    </dependency>
  </dependencies>

  <build>
    <finalName>app</finalName>
    <plugins>
      <plugin>
        <groupId>org.springframework.boot</groupId>
        <artifactId>spring-boot-maven-plugin</artifactId>
      </plugin>
    </plugins>
  </build>
</project>
```

### `Dog.java` - entité JPA

```java
package fr.ynov.dogapi;

import jakarta.persistence.*;
import jakarta.validation.constraints.NotBlank;
import java.time.LocalDate;

@Entity
@Table(name = "dogs")
public class Dog {

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    @NotBlank
    private String name;

    @NotBlank
    private String breed;

    private LocalDate birthDate;

    private boolean sterilized;

    public Long getId() { return id; }
    public void setId(Long id) { this.id = id; }
    public String getName() { return name; }
    public void setName(String name) { this.name = name; }
    public String getBreed() { return breed; }
    public void setBreed(String breed) { this.breed = breed; }
    public LocalDate getBirthDate() { return birthDate; }
    public void setBirthDate(LocalDate birthDate) { this.birthDate = birthDate; }
    public boolean isSterilized() { return sterilized; }
    public void setSterilized(boolean sterilized) { this.sterilized = sterilized; }
}
```

### `DogRepository.java`

```java
package fr.ynov.dogapi;

import org.springframework.data.jpa.repository.JpaRepository;

public interface DogRepository extends JpaRepository<Dog, Long> {
}
```

### `DogController.java`

```java
package fr.ynov.dogapi;

import jakarta.validation.Valid;
import org.springframework.http.HttpStatus;
import org.springframework.web.bind.annotation.*;
import org.springframework.web.server.ResponseStatusException;

import java.util.List;

@RestController
@RequestMapping("/api/v1/dogs")
public class DogController {

    private final DogRepository repository;

    public DogController(DogRepository repository) {
        this.repository = repository;
    }

    @GetMapping
    public List<Dog> findAll() {
        return repository.findAll();
    }

    @GetMapping("/{dogId}")
    public Dog findById(@PathVariable Long dogId) {
        return repository.findById(dogId).orElseThrow(() -> notFound(dogId));
    }

    @PostMapping
    @ResponseStatus(HttpStatus.CREATED)
    public Dog create(@Valid @RequestBody Dog dog) {
        dog.setId(null);
        return repository.save(dog);
    }

    @PutMapping("/{dogId}")
    public Dog update(@PathVariable Long dogId, @Valid @RequestBody Dog dog) {
        if (!repository.existsById(dogId)) {
            throw notFound(dogId);
        }
        dog.setId(dogId);
        return repository.save(dog);
    }

    @DeleteMapping("/{dogId}")
    @ResponseStatus(HttpStatus.NO_CONTENT)
    public void delete(@PathVariable Long dogId) {
        if (!repository.existsById(dogId)) {
            throw notFound(dogId);
        }
        repository.deleteById(dogId);
    }

    private ResponseStatusException notFound(Long dogId) {
        return new ResponseStatusException(HttpStatus.NOT_FOUND, "Chien " + dogId + " introuvable");
    }
}
```

### `DogApiApplication.java`

```java
package fr.ynov.dogapi;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;

@SpringBootApplication
public class DogApiApplication {
    public static void main(String[] args) {
        SpringApplication.run(DogApiApplication.class, args);
    }
}
```

### `application.properties`

```properties
spring.application.name=dog-api
server.port=8080

# Valeurs par défaut = développement local (BdD Docker exposée sur le port 5433 de l'hôte)
# Dans Docker, elles sont remplacées par les variables d'environnement.
spring.datasource.url=${DB_URL:jdbc:postgresql://localhost:5433/dogsdb}
spring.datasource.username=${DB_USER:dogs}
spring.datasource.password=${DB_PASSWORD:dogspass}

spring.jpa.hibernate.ddl-auto=update
spring.jpa.open-in-view=false
server.error.include-message=always
```

La syntaxe `${DB_URL:valeur}` prend la variable d'environnement si elle existe, sinon la valeur par défaut :
- **en local** (`mvn spring-boot:run` dans `dog-api/`) : l'API se connecte à `localhost:5433`, la base Docker exposée à l'étape 1 ;
- **dans Docker** : on passe `DB_URL=jdbc:postgresql://dogs-db:5432/dogsdb`, c'est-à-dire le nom du conteneur et le port interne.

`ddl-auto=update` laisse Hibernate créer la table `dogs` au démarrage.

## 3. Dockerfile de l'API (multi-stage)

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

Fichier `.dockerignore` : `target/`.

La compilation se fait **dans** Docker (image Maven + JDK 21) : il n'y a besoin ni de Java ni de Maven sur l'hôte. L'image finale ne contient que le JRE et le `.jar`.

## 4. Construire l'image

```bash
docker build -t dog-api ./dog-api
```

```
#11 [build 4/6] RUN mvn -q dependency:go-offline
#11 DONE 37.5s
#13 [build 6/6] RUN mvn -q package -DskipTests
#13 DONE 4.9s
#14 [stage-1 3/3] COPY --from=build /app/target/app.jar app.jar
```

```bash
docker images dog-api
```

```
REPOSITORY   TAG       IMAGE ID       CREATED                  SIZE
dog-api      latest    c9ff59af7769   Less than a second ago   396MB
```

## 5. Lancer l'API dans Docker, sur le même réseau que la base

```bash
docker run -d --name dog-api --network reseau-exo8 -p 8080:8080 \
  -e DB_URL=jdbc:postgresql://dogs-db:5432/dogsdb \
  -e DB_USER=dogs -e DB_PASSWORD=dogspass \
  dog-api

docker logs dog-api
```

```
INFO 1 --- [dog-api] [main] com.zaxxer.hikari.HikariDataSource : HikariPool-1 - Start completed.
INFO 1 --- [dog-api] [main] fr.ynov.dogapi.DogApiApplication   : Started DogApiApplication in 2.933 seconds
```

`HikariPool-1 - Start completed` confirme que l'API est connectée à la base.

## 6. Tester le CRUD

**POST** - ajout de deux chiens :

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

**GET** - liste :

```bash
curl -s http://localhost:8080/api/v1/dogs
```

```json
[{"id":1,"name":"Rex","breed":"Berger allemand","birthDate":"2019-05-10","sterilized":true},{"id":2,"name":"Filou","breed":"Jack Russell","birthDate":"2021-09-02","sterilized":false}]
```

**GET** - détail :

```bash
curl -s http://localhost:8080/api/v1/dogs/1
```

```json
{"id":1,"name":"Rex","breed":"Berger allemand","birthDate":"2019-05-10","sterilized":true}
```

**PUT** - Filou est maintenant stérilisé :

```bash
curl -s -X PUT http://localhost:8080/api/v1/dogs/2 -H 'Content-Type: application/json' \
  -d '{"name":"Filou","breed":"Jack Russell","birthDate":"2021-09-02","sterilized":true}'
```

```json
{"id":2,"name":"Filou","breed":"Jack Russell","birthDate":"2021-09-02","sterilized":true}
```

**DELETE** :

```bash
curl -s -o /dev/null -w 'HTTP %{http_code}\n' -X DELETE http://localhost:8080/api/v1/dogs/1
```

```
HTTP 204
```

```bash
curl -s http://localhost:8080/api/v1/dogs
```

```json
[{"id":2,"name":"Filou","breed":"Jack Russell","birthDate":"2021-09-02","sterilized":true}]
```

Chien supprimé → **404** :

```bash
curl -s -w '\nHTTP %{http_code}\n' http://localhost:8080/api/v1/dogs/1
```

```
{"timestamp":"2026-10-09T08:43:18.309+00:00","status":404,"error":"Not Found","message":"Chien 1 introuvable","path":"/api/v1/dogs/1"}
HTTP 404
```

## 7. Vérifier les données directement dans PostgreSQL

```bash
docker exec dogs-db psql -U dogs -d dogsdb -c 'SELECT * FROM dogs;'
```

```
 id | birth_date |    breed     | name  | sterilized
----+------------+--------------+-------+------------
  2 | 2021-09-02 | Jack Russell | Filou | t
(1 row)
```

La table `dogs` a été créée par Hibernate et contient bien les données écrites par l'API.

---

## Nettoyage

```bash
docker rm -f dog-api dogs-db
docker network rm reseau-exo8
```
