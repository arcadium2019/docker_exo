# Exercice Docker #8 — API Spring Boot « Dogs » conteneurisée

Projet : [`dogs-api/`](dogs-api/) · Compose : [`compose.yaml`](compose.yaml)

Stack : **Java 21**, **Spring Boot 4.1.1** (Spring Web MVC, Spring Data JPA / Hibernate, Validation) et **MySQL 8.4**.

## 1. Créer la base de données avec Docker (port forwarding)

```bash
docker run -d --name ex08-mysql \
  -p 3308:3306 \
  -e MYSQL_ROOT_PASSWORD=rootpass \
  -e MYSQL_DATABASE=dogsdb \
  -e MYSQL_USER=dogs_user \
  -e MYSQL_PASSWORD=dogs_pass \
  -v ex08-mysql-data:/var/lib/mysql \
  mysql:8.4
```

`-p 3308:3306` permet à l'API lancée **en local** (hors Docker) d'accéder à la BdD sur `localhost:3308`. Aucun MySQL n'est installé sur la machine.

## 2. Créer le projet Spring Boot

Avec [start.spring.io](https://start.spring.io) (ou en ligne de commande) :

```bash
curl https://start.spring.io/starter.tgz \
  -d type=maven-project -d language=java -d bootVersion=4.1.1 -d javaVersion=21 \
  -d groupId=com.ynov -d artifactId=dogs-api -d packageName=com.ynov.dogsapi \
  -d dependencies=web,data-jpa,mysql,validation \
  -d baseDir=dogs-api | tar -xzf -
```

Dépendances choisies :

| Dépendance | Rôle |
|---|---|
| `spring-boot-starter-webmvc` | API REST |
| `spring-boot-starter-data-jpa` | JPA + **Hibernate** |
| `mysql-connector-j` | **Driver JDBC MySQL** utilisé par Hibernate (pour PostgreSQL, ce serait `org.postgresql:postgresql`) |
| `spring-boot-starter-validation` | Validation des données reçues (`@NotBlank`, ...) |

## 3. Développer l'API

### Structure

```
dogs-api/
├── Dockerfile
├── .dockerignore
├── pom.xml
└── src/main/
    ├── java/com/ynov/dogsapi/
    │   ├── DogsApiApplication.java
    │   └── dog/
    │       ├── Dog.java              # @Entity JPA
    │       ├── DogRepository.java    # JpaRepository<Dog, Long>
    │       └── DogController.java    # endpoints REST
    └── resources/application.properties
```

### Entité — `Dog.java`

```java
@Entity
@Table(name = "dog")
public class Dog {
    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    @NotBlank @Column(nullable = false, length = 100)
    private String name;

    @NotBlank @Column(nullable = false, length = 100)
    private String breed;

    @NotNull @PastOrPresent @Column(name = "birth_date", nullable = false)
    private LocalDate birthDate;

    @Column(nullable = false)
    private boolean sterilized;
    // getters / setters
}
```

### Repository — `DogRepository.java`

```java
public interface DogRepository extends JpaRepository<Dog, Long> {
}
```

Spring Data génère l'implémentation (`findAll`, `findById`, `save`, `delete`, ...).

### Contrôleur — `DogController.java`

| Méthode | Endpoint | Réponse |
|---|---|---|
| `GET` | `/api/v1/dogs` | 200 + liste |
| `GET` | `/api/v1/dogs/{dogId}` | 200, ou 404 si l'ID n'existe pas |
| `POST` | `/api/v1/dogs` | 201 + en-tête `Location`, ou 400 si invalide |
| `PUT` | `/api/v1/dogs/{dogId}` | 200, 404 ou 400 |
| `DELETE` | `/api/v1/dogs/{dogId}` | 204 ou 404 |

```java
@RestController
@RequestMapping("/api/v1/dogs")
public class DogController {
    // ...
    @GetMapping                    public List<Dog> findAll()                        { ... }
    @GetMapping("/{dogId}")        public Dog findById(@PathVariable Long dogId)     { ... }
    @PostMapping                   public ResponseEntity<Dog> create(@Valid @RequestBody Dog dog) { ... }
    @PutMapping("/{dogId}")        public Dog update(@PathVariable Long dogId, @Valid @RequestBody Dog dog) { ... }
    @DeleteMapping("/{dogId}")     public ResponseEntity<Void> delete(@PathVariable Long dogId) { ... }

    private Dog getOrThrow(Long dogId) {
        return dogRepository.findById(dogId)
                .orElseThrow(() -> new ResponseStatusException(HttpStatus.NOT_FOUND, "Dog " + dogId + " not found"));
    }
}
```

### Configuration — `application.properties`

```properties
spring.application.name=dogs-api

spring.datasource.url=jdbc:mysql://${DB_HOST:localhost}:${DB_PORT:3308}/${DB_NAME:dogsdb}
spring.datasource.username=${DB_USER:dogs_user}
spring.datasource.password=${DB_PASSWORD:dogs_pass}

spring.jpa.hibernate.ddl-auto=update
spring.jpa.open-in-view=false

spring.web.error.include-message=always
```

La syntaxe `${VAR:défaut}` permet d'avoir **une seule configuration** :
- en local, ce sont les valeurs par défaut qui s'appliquent (`localhost:3308`) ;
- dans Docker, on les remplace par des variables d'environnement (`DB_HOST=ex08-mysql`, `DB_PORT=3306`).

`ddl-auto=update` : Hibernate crée la table `dog` à partir de l'entité.

> Spring Boot 4 : la propriété `server.error.include-message` est remplacée par `spring.web.error.include-message`. Avec l'ancienne, le message « Dog 1 not found » n'apparaît pas dans la réponse 404.

## 4. Tester l'API en local (contre la BdD conteneurisée)

```bash
cd rep_exo/exercice-08/dogs-api
./mvnw package -DskipTests
java -jar target/dogs-api-0.0.1-SNAPSHOT.jar --server.port=9090
```

> J'avais `JAVA_HOME` pointant sur un JDK 17 (erreur `release version 21 not supported`). Correction : `export JAVA_HOME=/usr/lib/jvm/java-21-openjdk`.

```bash
curl -X POST localhost:9090/api/v1/dogs -H 'Content-Type: application/json' \
  -d '{"name":"Rex","breed":"Berger Allemand","birthDate":"2019-05-10","sterilized":true}'
# {"birthDate":"2019-05-10","breed":"Berger Allemand","id":1,"name":"Rex","sterilized":true}
```

## 5. Dockerfile de l'API (multi-stage)

```dockerfile
# ---- Build stage: compile the jar with Maven (no JDK / Maven needed on the host)
FROM maven:3.9-eclipse-temurin-21 AS build
WORKDIR /app
COPY pom.xml .
RUN mvn -q dependency:go-offline
COPY src ./src
RUN mvn -q package -DskipTests

# ---- Runtime stage: only a JRE + the jar
FROM eclipse-temurin:21-jre
WORKDIR /app
COPY --from=build /app/target/*.jar app.jar
EXPOSE 8080
ENTRYPOINT ["java", "-jar", "app.jar"]
```

- **Multi-stage** : la compilation se fait dans une image Maven et l'image finale ne contient qu'un JRE et le `.jar`. Elle est plus légère, et on n'a pas besoin d'installer Java ou Maven sur l'hôte pour la construire.
- `COPY pom.xml` puis `dependency:go-offline` **avant** `COPY src` : la couche des dépendances reste en cache tant que le `pom.xml` ne change pas, donc les rebuilds sont rapides.
- `.dockerignore` : exclut `target/`, `.mvn/`, `mvnw`… du contexte de build.

## 6. Construire l'image

```bash
cd rep_exo/exercice-08/dogs-api
docker build -t dogs-api .
docker images dogs-api
```

## 7. Lancer l'API dans Docker et la connecter à la BdD

Depuis le conteneur, `localhost` désigne le conteneur lui-même : on ne peut pas utiliser `localhost:3308`. On met donc les deux conteneurs sur un même réseau et l'API joint MySQL **par son nom**.

```bash
docker network create ex08-net
docker network connect ex08-net ex08-mysql

docker run -d --name ex08-api \
  --network ex08-net \
  -p 8086:8080 \
  -e DB_HOST=ex08-mysql -e DB_PORT=3306 \
  -e DB_NAME=dogsdb -e DB_USER=dogs_user -e DB_PASSWORD=dogs_pass \
  dogs-api

docker logs -f ex08-api     # attendre "Started DogsApiApplication"
```

## 8. Tests du CRUD (API dans Docker → http://localhost:8086)

```bash
B=localhost:8086/api/v1/dogs

curl -s $B
# [{"birthDate":"2019-05-10","breed":"Berger Allemand","id":1,"name":"Rex","sterilized":true}]
#   ^ le chien créé à l'étape 4 en local : c'est bien la même base

curl -s -X POST $B -H 'Content-Type: application/json' \
  -d '{"name":"Médor","breed":"Labrador","birthDate":"2021-02-14","sterilized":false}'
# {"birthDate":"2021-02-14","breed":"Labrador","id":2,"name":"Médor","sterilized":false}

curl -s $B/2
# {"birthDate":"2021-02-14","breed":"Labrador","id":2,"name":"Médor","sterilized":false}

curl -s -X PUT $B/2 -H 'Content-Type: application/json' \
  -d '{"name":"Médor","breed":"Labrador","birthDate":"2021-02-14","sterilized":true}'
# {"birthDate":"2021-02-14","breed":"Labrador","id":2,"name":"Médor","sterilized":true}

curl -s -o /dev/null -w '%{http_code}\n' -X DELETE $B/1
# 204

curl -s $B/1
# {"timestamp":"...","status":404,"error":"Not Found","message":"Dog 1 not found","path":"/api/v1/dogs/1"}

curl -s -X POST $B -H 'Content-Type: application/json' -d '{"name":""}'
# {"timestamp":"...","status":400,"error":"Bad Request","message":"Validation failed for object='dog'. Error count: 3",...}
```

Vérification directement dans MySQL :

```bash
docker exec -it ex08-mysql mysql --default-character-set=utf8mb4 -udogs_user -pdogs_pass dogsdb -e "SELECT * FROM dog;"
# id  birth_date  breed     name   sterilized
# 2   2021-02-14  Labrador  Médor  1
```

## Bonus — tout lancer avec Docker Compose

[`compose.yaml`](compose.yaml) :

```yaml
name: ex08

services:
  mysql:
    image: mysql:8.4
    restart: unless-stopped
    environment:
      MYSQL_ROOT_PASSWORD: rootpass
      MYSQL_DATABASE: dogsdb
      MYSQL_USER: dogs_user
      MYSQL_PASSWORD: dogs_pass
    volumes:
      - mysql-data:/var/lib/mysql
    ports:
      - "3308:3306"   # Only needed to run the API locally (outside Docker)
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "localhost", "-uroot", "-prootpass"]
      interval: 5s
      timeout: 3s
      retries: 20

  api:
    build: ./dogs-api
    image: dogs-api
    restart: unless-stopped
    environment:
      DB_HOST: mysql
      DB_PORT: 3306
      DB_NAME: dogsdb
      DB_USER: dogs_user
      DB_PASSWORD: dogs_pass
    ports:
      - "8086:8080"
    depends_on:
      mysql:
        condition: service_healthy

volumes:
  mysql-data:
```

```bash
cd rep_exo/exercice-08
docker compose up -d --build
docker compose logs -f api
docker compose down
```

(Il faut d'abord supprimer les conteneurs manuels : ils utilisent les mêmes ports.)

## Nettoyage

```bash
docker rm -f ex08-api ex08-mysql
docker network rm ex08-net
docker volume rm ex08-mysql-data
docker rmi dogs-api
```
