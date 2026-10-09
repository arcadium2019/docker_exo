# Exercice Docker #9 — API CRUD + API Logs conteneurisées

Projets : [`crud-api/`](crud-api/) et [`logs-api/`](logs-api/) · Orchestration : [`compose.yaml`](compose.yaml)

Stack : Java 21, Spring Boot 4.1.1 et MySQL 8.4.

## Architecture

```
                 hôte :8087                     hôte :8088
                     │                              │
  client ──HTTP──▶ crud-api ──RestTemplate POST──▶ logs-api ──▶ /data/logs.jsonl
                     │      /api/v1/logs                          (volume logs-data)
                     │ JDBC (Hibernate)
                     ▼
                   mysql  ──▶ /var/lib/mysql (volume mysql-data)
                   (hôte :3309, seulement pour le dev local)
```

Les trois conteneurs sont sur le réseau créé par Compose et se joignent par **nom de service** (`mysql`, `logs-api`).

---

## API Logs (`logs-api`)

### Modèle

```java
public enum LogLevel { INFO, WARN, ERR }

public record LogEntry(
        @NotBlank String message,
        @NotBlank String source,
        @NotBlank String timestamp,
        @NotNull LogLevel level
) {}
```

### Stockage : fichier JSON Lines

`LogFileRepository` ajoute une ligne JSON par log dans `/data/logs.jsonl`, et la relit pour le `GET`. Les méthodes sont `synchronized` pour que deux écritures en même temps ne se mélangent pas. Le dossier `/data` est un **volume Docker** : les logs restent si on supprime et recrée le conteneur.

Exemple de contenu du fichier :

```json
{"message":"Dog 42 not found","source":"[CrudAPI] GET /api/v1/dogs/42","timestamp":"2026-10-09T09:43:42.069529584Z","level":"WARN"}
```

### Endpoints

| Méthode | Endpoint | Description |
|---|---|---|
| `GET` | `/api/v1/logs` | Tous les logs (filtre facultatif `?level=ERR`) |
| `POST` | `/api/v1/logs` | Ajoute un log (201), ou 400 si invalide (par ex. `level` absent de `INFO/WARN/ERR`) |

### Configuration

```properties
spring.application.name=logs-api
server.port=${SERVER_PORT:8081}
logs.file=${LOGS_FILE:./data/logs.jsonl}
spring.web.error.include-message=always
```

---

## API CRUD (`crud-api`)

Même CRUD que l'exercice 8 (`Dog`, `DogRepository`, `DogController` sur `/api/v1/dogs`), auquel s'ajoute l'envoi des logs.

### Fonctionnement du logging

```
requête ──▶ DogController ──(exception ?)──▶ GlobalExceptionHandler
                                               │ réponse JSON d'erreur
                                               │ + attributs de requête :
                                               │   message d'erreur, moment où elle est levée
                                               ▼
           RequestLoggingInterceptor.afterCompletion()
               → construit le LogEntry (source, level selon le code HTTP)
               → LogClient.send() (@Async, RestTemplate POST vers logs-api)
```

| Classe | Rôle |
|---|---|
| `error/GlobalExceptionHandler` | `@RestControllerAdvice` : transforme chaque exception en réponse JSON (404, 400 validation, 400 JSON mal formé, 400 type invalide, 405, 500) et **enregistre le message et l'heure de l'erreur** dans la requête |
| `logging/RequestLoggingInterceptor` | `HandlerInterceptor` sur `/api/**` : à la fin de chaque appel, crée le log. `source = "[CrudAPI] " + méthode + " " + URI`, et le niveau dépend du code HTTP : **2xx/3xx → INFO, 4xx → WARN, 5xx → ERR** |
| `logging/LogClient` | Client **RestTemplate** (timeouts de 2 s). Appel `@Async` pour ne pas ralentir la réponse. En cas d'échec, il écrit un warning et **ne fait pas planter** l'API CRUD |
| `logging/WebConfig` | Enregistre l'intercepteur et active `@EnableAsync` |

Extrait de `LogClient` :

```java
@Async
public void send(LogEntry entry) {
    try {
        restTemplate.postForEntity(logsUrl, entry, Void.class);
    } catch (RestClientException e) {
        LOGGER.warn("Unable to send log to {}: {}", logsUrl, e.getMessage());
    }
}
```

Extrait de `RequestLoggingInterceptor` :

```java
@Override
public void afterCompletion(HttpServletRequest request, HttpServletResponse response, Object handler, Exception ex) {
    int status = response.getStatus();
    String source = "[CrudAPI] " + request.getMethod() + " " + request.getRequestURI();
    String message = (String) request.getAttribute(GlobalExceptionHandler.ERROR_MESSAGE_ATTRIBUTE);
    if (message == null) {
        message = ex != null ? ex.getMessage() : status + " " + reasonPhrase(status);   // e.g. "200 OK"
    }
    Instant timestamp = (Instant) request.getAttribute(GlobalExceptionHandler.ERROR_TIMESTAMP_ATTRIBUTE);
    if (timestamp == null) {
        timestamp = Instant.now();
    }
    logClient.send(new LogEntry(message, source, timestamp.toString(), levelOf(status)));
}
```

### Configuration

```properties
spring.application.name=crud-api

spring.datasource.url=jdbc:mysql://${DB_HOST:localhost}:${DB_PORT:3309}/${DB_NAME:dogsdb}
spring.datasource.username=${DB_USER:dogs_user}
spring.datasource.password=${DB_PASSWORD:dogs_pass}
# Fail fast when the database is down instead of waiting 30 s per request
spring.datasource.hikari.connection-timeout=3000

spring.jpa.hibernate.ddl-auto=update
spring.jpa.open-in-view=false

logs-api.url=${LOGS_API_URL:http://localhost:8088}
```

---

## Étapes réalisées

### 1. Base de données via Docker (port forwarding)

Pour développer en local (les deux APIs lancées avec `./mvnw`) :

```bash
docker run -d --name ex09-mysql -p 3309:3306 \
  -e MYSQL_ROOT_PASSWORD=rootpass -e MYSQL_DATABASE=dogsdb \
  -e MYSQL_USER=dogs_user -e MYSQL_PASSWORD=dogs_pass \
  mysql:8.4
```

(Dans le `compose.yaml`, ce même service publie aussi le port 3309.)

### 2. Création des deux projets Spring Boot

```bash
cd rep_exo/exercice-09

curl https://start.spring.io/starter.tgz -d type=maven-project -d bootVersion=4.1.1 -d javaVersion=21 \
  -d groupId=com.ynov -d artifactId=logs-api -d packageName=com.ynov.logsapi \
  -d dependencies=web,validation -d baseDir=logs-api | tar -xzf -

curl https://start.spring.io/starter.tgz -d type=maven-project -d bootVersion=4.1.1 -d javaVersion=21 \
  -d groupId=com.ynov -d artifactId=crud-api -d packageName=com.ynov.crudapi \
  -d dependencies=web,data-jpa,mysql,validation -d baseDir=crud-api | tar -xzf -
```

Le driver JDBC MySQL (`mysql-connector-j`) n'est ajouté qu'à `crud-api` : `logs-api` n'a pas de base de données.

### 3. Développement et compilation en local

```bash
export JAVA_HOME=/usr/lib/jvm/java-21-openjdk
(cd logs-api && ./mvnw package -DskipTests && java -jar target/logs-api-0.0.1-SNAPSHOT.jar)   # :8081
(cd crud-api && ./mvnw package -DskipTests && java -jar target/crud-api-0.0.1-SNAPSHOT.jar --logs-api.url=http://localhost:8081)   # :8080
```

### 4. Dockerfiles (multi-stage, comme à l'exercice 8)

`crud-api/Dockerfile` :

```dockerfile
FROM maven:3.9-eclipse-temurin-21 AS build
WORKDIR /app
COPY pom.xml .
RUN mvn -q dependency:go-offline
COPY src ./src
RUN mvn -q package -DskipTests

FROM eclipse-temurin:21-jre
WORKDIR /app
COPY --from=build /app/target/*.jar app.jar
EXPOSE 8080
ENTRYPOINT ["java", "-jar", "app.jar"]
```

`logs-api/Dockerfile` : même stage de build, et un runtime qui déclare le volume :

```dockerfile
FROM eclipse-temurin:21-jre
WORKDIR /app
COPY --from=build /app/target/*.jar app.jar
ENV SERVER_PORT=8081 \
    LOGS_FILE=/data/logs.jsonl
VOLUME /data
EXPOSE 8081
ENTRYPOINT ["java", "-jar", "app.jar"]
```

### 5. Construction des images

```bash
docker build -t logs-api ./logs-api
docker build -t crud-api ./crud-api
```

### 6a. Lancement avec `docker run`

```bash
docker network create ex09-net
docker network connect ex09-net ex09-mysql

docker run -d --name ex09-logs-api --network ex09-net -p 8088:8081 \
  -v ex09-logs-data:/data \
  logs-api

docker run -d --name ex09-crud-api --network ex09-net -p 8087:8080 \
  -e DB_HOST=ex09-mysql -e DB_PORT=3306 -e DB_NAME=dogsdb \
  -e DB_USER=dogs_user -e DB_PASSWORD=dogs_pass \
  -e LOGS_API_URL=http://ex09-logs-api:8081 \
  crud-api
```

### 6b. Lancement avec Docker Compose (ce que j'ai utilisé pour les tests)

[`compose.yaml`](compose.yaml) :

```yaml
name: ex09

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
      - "3309:3306"   # Only needed to run crud-api locally (outside Docker)
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "localhost", "-uroot", "-prootpass"]
      interval: 5s
      timeout: 3s
      retries: 20

  logs-api:
    build: ./logs-api
    image: logs-api
    restart: unless-stopped
    volumes:
      - logs-data:/data
    ports:
      - "8088:8081"

  crud-api:
    build: ./crud-api
    image: crud-api
    restart: unless-stopped
    environment:
      DB_HOST: mysql
      DB_PORT: 3306
      DB_NAME: dogsdb
      DB_USER: dogs_user
      DB_PASSWORD: dogs_pass
      LOGS_API_URL: http://logs-api:8081
    ports:
      - "8087:8080"
    depends_on:
      mysql:
        condition: service_healthy
      logs-api:
        condition: service_started

volumes:
  mysql-data:
  logs-data:
```

```bash
cd rep_exo/exercice-09
docker compose up -d --build
docker compose ps
# ex09-crud-api-1 | Up          | 0.0.0.0:8087->8080/tcp
# ex09-logs-api-1 | Up          | 0.0.0.0:8088->8081/tcp
# ex09-mysql-1    | Up (healthy)| 0.0.0.0:3309->3306/tcp
```

---

## 7. Tests

### Appels au CRUD (succès et erreurs)

```bash
B=localhost:8087/api/v1/dogs; J='Content-Type: application/json'

curl -s -X POST $B -H "$J" -d '{"name":"Rex","breed":"Berger Allemand","birthDate":"2019-05-10","sterilized":true}'
# {"birthDate":"2019-05-10","breed":"Berger Allemand","id":1,"name":"Rex","sterilized":true}   [201]
curl -s $B                       # [{"...","id":1,"name":"Rex",...}]                               [200]
curl -s $B/1                     # {"...","id":1,"name":"Rex",...}                                 [200]
curl -s -X PUT $B/1 -H "$J" -d '{"name":"Rex","breed":"Berger Allemand","birthDate":"2019-05-10","sterilized":false}'   # [200]
curl -s $B/42
# {"timestamp":"...","status":404,"message":"Dog 42 not found","path":"/api/v1/dogs/42"}        [404]
curl -s -X POST $B -H "$J" -d '{"name":"","breed":"Labrador"}'
# {"status":400,"message":"Validation failed: birthDate must not be null, name must not be blank",...}  [400]
curl -s -X POST $B -H "$J" -d '{pas du json'
# {"status":400,"message":"Malformed JSON request body",...}                                    [400]
curl -s $B/abc
# {"status":400,"message":"Invalid value 'abc' for parameter dogId",...}                        [400]
curl -s -X DELETE $B/1           #                                                              [204]

# Panne de la BdD -> erreur 500
docker compose stop mysql
curl -s $B
# {"status":500,"message":"Could not open JPA EntityManager for transaction","path":"/api/v1/dogs"}  [500]
docker compose start mysql
```

### Logs récupérés depuis l'API Logs

```bash
curl -s localhost:8088/api/v1/logs | python3 -m json.tool
```

```json
[
  { "message": "201 Created",      "source": "[CrudAPI] POST /api/v1/dogs",      "timestamp": "2026-10-09T09:43:42.006868742Z", "level": "INFO" },
  { "message": "200 OK",           "source": "[CrudAPI] GET /api/v1/dogs",       "timestamp": "2026-10-09T09:43:42.017696827Z", "level": "INFO" },
  { "message": "200 OK",           "source": "[CrudAPI] GET /api/v1/dogs/1",     "timestamp": "2026-10-09T09:43:42.033996763Z", "level": "INFO" },
  { "message": "200 OK",           "source": "[CrudAPI] PUT /api/v1/dogs/1",     "timestamp": "2026-10-09T09:43:42.057516638Z", "level": "INFO" },
  { "message": "Dog 42 not found", "source": "[CrudAPI] GET /api/v1/dogs/42",    "timestamp": "2026-10-09T09:43:42.069529584Z", "level": "WARN" },
  { "message": "Validation failed: birthDate must not be null, name must not be blank",
                                   "source": "[CrudAPI] POST /api/v1/dogs",      "timestamp": "2026-10-09T09:43:42.090823488Z", "level": "WARN" },
  { "message": "Malformed JSON request body",
                                   "source": "[CrudAPI] POST /api/v1/dogs",      "timestamp": "2026-10-09T09:43:42.098832753Z", "level": "WARN" },
  { "message": "Invalid value 'abc' for parameter dogId",
                                   "source": "[CrudAPI] GET /api/v1/dogs/abc",   "timestamp": "2026-10-09T09:43:42.108193437Z", "level": "WARN" },
  { "message": "204 No Content",   "source": "[CrudAPI] DELETE /api/v1/dogs/1",  "timestamp": "2026-10-09T09:43:42.128397891Z", "level": "INFO" },
  { "message": "Could not open JPA EntityManager for transaction",
                                   "source": "[CrudAPI] GET /api/v1/dogs",       "timestamp": "2026-10-09T09:43:49.035371199Z", "level": "ERR" }
]
```

Filtrer uniquement les erreurs :

```bash
curl -s 'localhost:8088/api/v1/logs?level=ERR'
# 1 log ERR (la panne de la BdD)
```

### Validation de l'API Logs

```bash
curl -s -X POST localhost:8088/api/v1/logs -H 'Content-Type: application/json' \
  -d '{"message":"test","source":"[Manual]","timestamp":"2026-10-09T10:00:00Z","level":"DEBUG"}'
# 400 : "Cannot deserialize value of type LogLevel from String "DEBUG": not one of the values accepted for Enum class: [ERR, INFO, WARN]"
```

### Résilience : l'API CRUD continue de fonctionner sans l'API Logs

```bash
docker compose stop logs-api
curl -s localhost:8087/api/v1/dogs          # [] [200]  -> le CRUD répond toujours
docker compose logs crud-api | grep 'Unable to send log'
# WARN ... LogClient : Unable to send log to http://logs-api:8081/api/v1/logs: I/O error ... Connect timed out
```

### Persistance des logs (volume)

```bash
docker compose rm -sf logs-api       # supprime le conteneur
docker compose up -d logs-api        # le recrée
curl -s localhost:8088/api/v1/logs | python3 -c "import json,sys;print(len(json.load(sys.stdin)))"
# 12   -> tous les logs sont conservés

docker compose exec logs-api tail -2 /data/logs.jsonl
```

---

## Nettoyage

```bash
docker compose down        # conteneurs + réseau
docker compose down -v     # + volumes (BdD et logs)
docker rmi crud-api logs-api
```
