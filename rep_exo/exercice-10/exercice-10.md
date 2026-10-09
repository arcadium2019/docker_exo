# Exercice Docker #10 — Docker Compose : variables d'environnement et volumes

Application fournie : API Spring Boot de gestion de notes (code repris de `02_exercices_sujet/exercice10/`, **non modifié**) + PostgreSQL.

Fichiers ajoutés :

| Fichier | Rôle |
|---|---|
| [`.env`](.env) | Variables d'environnement (partie 1) |
| [`docker-compose.yml`](docker-compose.yml) | Orchestration app + db, variables, volumes (partie 2) |
| [`Dockerfile`](Dockerfile) | Image de l'application Spring Boot (nécessaire pour `--build`) |
| [`.dockerignore`](.dockerignore) | Exclut `target/`, `init-db/`, `.env`… du contexte de build |

## Analyse du code fourni

`application.yml` lit déjà toutes ses valeurs depuis des variables d'environnement, avec une valeur par défaut (`${VAR:défaut}`) :

| Variable | Utilisée pour |
|---|---|
| `APP_NAME`, `APP_VERSION`, `APP_ENV` | Infos renvoyées par `/api/info/app` |
| `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`, `DB_PASSWORD` | URL JDBC PostgreSQL |
| `UPLOAD_PATH` | Dossier de stockage des fichiers uploadés (`/app/uploads`) |
| `MAX_FILE_SIZE` | Taille max des uploads |
| `LOG_LEVEL`, `SHOW_SQL` | Niveau de logs, affichage des requêtes SQL |

On n'a donc **rien à changer dans le code** : la configuration se fait entièrement depuis Compose.

---

## Partie 1 — Fichier `.env`

```env
# ---- Application
APP_NAME=Notes Manager
APP_VERSION=1.0.0
APP_ENV=production
APP_PORT=8080

# ---- Database (used by both the db and app services)
DB_NAME=notesdb
DB_USER=admin
DB_PASSWORD=secret123

# ---- Uploads
MAX_FILE_SIZE=10MB

# ---- Logging
LOG_LEVEL=INFO
SHOW_SQL=false
```

Docker Compose lit **automatiquement** le fichier `.env` qui se trouve à côté du `docker-compose.yml`, et remplace les `${VAR}` du fichier Compose par ses valeurs.

> Le `.env` contient un mot de passe : dans un vrai projet, on l'ajoute au `.gitignore` et on versionne un `.env.example` sans les secrets.

## Dockerfile de l'application

```dockerfile
# ---- Build stage: compile the jar with Maven (no JDK / Maven needed on the host)
FROM maven:3.9-eclipse-temurin-17 AS build
WORKDIR /app
COPY pom.xml .
RUN mvn -q dependency:go-offline
COPY src ./src
RUN mvn -q package -DskipTests

# ---- Runtime stage: only a JRE + the jar
FROM eclipse-temurin:17-jre
WORKDIR /app
COPY --from=build /app/target/*.jar app.jar
RUN mkdir -p /app/uploads
EXPOSE 8080
ENTRYPOINT ["java", "-jar", "app.jar"]
```

J'utilise Java 17 parce que c'est la version du `pom.xml` fourni (Spring Boot 3.2.0).

## Partie 2 — Fichier `docker-compose.yml`

```yaml
services:
  db:
    image: postgres:16-alpine
    restart: unless-stopped
    environment:
      # Method 1: values read from the .env file
      POSTGRES_DB: ${DB_NAME}
      POSTGRES_USER: ${DB_USER}
      POSTGRES_PASSWORD: ${DB_PASSWORD}
    volumes:
      # Named volume: database files survive "docker compose down"
      - pg_data:/var/lib/postgresql/data
      # Bind mount: SQL scripts executed on the first start (empty pg_data)
      - ./init-db:/docker-entrypoint-initdb.d:ro,Z
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${DB_USER} -d ${DB_NAME}"]
      interval: 5s
      timeout: 3s
      retries: 10
    # No "ports": PostgreSQL is only reachable by the app, through the Compose network

  app:
    build: .
    image: notes-app
    restart: unless-stopped
    environment:
      # Method 1: values read from the .env file
      APP_NAME: ${APP_NAME}
      APP_VERSION: ${APP_VERSION}
      APP_ENV: ${APP_ENV}
      DB_NAME: ${DB_NAME}
      DB_USER: ${DB_USER}
      DB_PASSWORD: ${DB_PASSWORD}
      # Method 2: hard-coded values (internal to the Compose stack)
      DB_HOST: db
      DB_PORT: 5432
      UPLOAD_PATH: /app/uploads
      # Method 3: value from .env, or the default after ":-" if missing / empty
      MAX_FILE_SIZE: ${MAX_FILE_SIZE:-5MB}
      LOG_LEVEL: ${LOG_LEVEL:-INFO}
      SHOW_SQL: ${SHOW_SQL:-false}
    ports:
      - "${APP_PORT:-8080}:8080"
    volumes:
      # Named volume: uploaded files survive container re-creation
      - uploads:/app/uploads
    depends_on:
      db:
        condition: service_healthy

volumes:
  pg_data:
  uploads:
```

### Choix effectués

- **`DB_HOST: db`** : dans le réseau créé par Compose, chaque service est joignable par son **nom de service**. `localhost` dans le conteneur `app` désignerait le conteneur lui-même.
- **Les mêmes variables `DB_*`** servent pour les deux services : PostgreSQL crée la base et l'utilisateur, et l'app s'y connecte avec les mêmes identifiants. Une seule valeur à changer dans le `.env`.
- **Volume `pg_data`** (volume nommé) : persistance des données PostgreSQL.
- **Volume `uploads`** (volume nommé) : persistance des fichiers uploadés par l'API.
- **`./init-db` monté sur `/docker-entrypoint-initdb.d`** (bind mount, en lecture seule) : PostgreSQL exécute `01-data.sql` **uniquement au premier démarrage**, quand `pg_data` est vide. Ce script crée la table `notes` et les 3 notes de démo. `Z` est nécessaire sur Fedora/SELinux et ignoré ailleurs.
- **`healthcheck` + `depends_on: condition: service_healthy`** : l'app ne démarre que quand PostgreSQL accepte les connexions, ce qui évite les erreurs de connexion au démarrage.
- **Pas de `ports` sur `db`** : la base n'est pas exposée sur l'hôte (et on évite un conflit avec un PostgreSQL local déjà sur 5432).

Pour vérifier la configuration finale, avec les variables remplacées :

```bash
docker compose config
```

---

## Validation

> Le port 8080 était déjà pris par le conteneur 2048 de l'exercice 2 : je l'ai arrêté avant (`docker stop ex02-2048`). Autre solution : changer `APP_PORT` dans le `.env`.

### Test 1 : Démarrage

```bash
cd rep_exo/exercice-10
docker compose up -d --build
docker compose ps
```

```
NAME                STATUS                 PORTS
exercice-10-app-1   Up 3 seconds           0.0.0.0:8080->8080/tcp
exercice-10-db-1    Up 8 seconds (healthy) 5432/tcp
```

```bash
curl http://localhost:8080/api/info/health
# {"application":"UP","database":"UP","dbProduct":"PostgreSQL"}
```

### Test 2 : Variables d'environnement

```bash
curl http://localhost:8080/api/info/env
```

```json
{"APP_NAME":"Notes Manager","APP_VERSION":"1.0.0","APP_ENV":"production",
 "DB_HOST":"db","DB_PORT":"5432","DB_NAME":"notesdb","DB_USER":"admin",
 "UPLOAD_PATH":"/app/uploads","MAX_FILE_SIZE":"10MB","LOG_LEVEL":"INFO","SHOW_SQL":"false"}
```

On voit les trois méthodes : les valeurs du `.env` (`APP_NAME`, `DB_USER`…), les valeurs en dur (`DB_HOST=db`, `UPLOAD_PATH`) et les valeurs avec défaut (`MAX_FILE_SIZE=10MB`, prise dans le `.env`). `DB_PASSWORD` n'apparaît pas, l'endpoint ne l'expose pas.

```bash
curl http://localhost:8080/api/info/app
# {"name":"Notes Manager","version":"1.0.0","environment":"production","uploadPath":"/app/uploads"}

curl http://localhost:8080/api/notes
# [ {"id":1,"title":"Bienvenue",...}, {"id":2,"title":"Liste de courses",...}, {"id":3,"title":"Réunion projet",...} ]
#   ^ les 3 notes du script init-db/01-data.sql
```

### Test 3 : Créer des données

```bash
# Créer une note
curl -X POST http://localhost:8080/api/notes \
  -H "Content-Type: application/json" \
  -d '{"title":"Test persistance","content":"Cette note doit survivre au redémarrage","category":"WORK","priority":"HIGH"}'
# {"id":4,"title":"Test persistance","content":"Cette note doit survivre au redémarrage","category":"WORK","priority":"HIGH",...}

# (Bonus) Uploader un fichier attaché à la note -> stocké dans le volume "uploads"
echo "hello docker" > hello.txt
curl -F file=@hello.txt -F noteId=4 http://localhost:8080/api/files/upload
# {"originalName":"hello.txt","filename":"7d1eba49-283b-4131-9e29-8ac04c79b419.txt","size":13}

# Vérifier
curl http://localhost:8080/api/notes        # titres : Bienvenue, Liste de courses, Réunion projet, Test persistance
curl http://localhost:8080/api/files/info   # {"usedMB":"0.00","usedBytes":13,"fileCount":1}
```

### Test 4 : Persistance des données

```bash
# Arrêter sans supprimer les volumes
docker compose down
docker volume ls | grep exercice-10
# exercice-10_pg_data
# exercice-10_uploads      <- les volumes existent toujours

# Redémarrer
docker compose up -d

# Attendre 20 secondes puis vérifier
sleep 20
curl http://localhost:8080/api/notes
# titres : Bienvenue, Liste de courses, Réunion projet, Test persistance   ✅
curl http://localhost:8080/api/files/info
# {"usedMB":"0.00","usedBytes":13,"fileCount":1}                          ✅ le fichier est toujours là
```

La note « Test persistance » existe toujours : `docker compose down` supprime les conteneurs et le réseau, **pas les volumes nommés**.

### Test 5 : Perte des données

```bash
# Arrêter ET supprimer les volumes
docker compose down -v
#  Volume exercice-10_uploads Removed
#  Volume exercice-10_pg_data Removed
#  Network exercice-10_default Removed

# Redémarrer
docker compose up -d

# Attendre puis vérifier
sleep 20
curl http://localhost:8080/api/notes
# titres : Bienvenue, Liste de courses, Réunion projet     <- "Test persistance" a disparu
curl http://localhost:8080/api/files/info
# {"usedMB":"0.00","usedBytes":0,"fileCount":0}           <- fichier supprimé aussi
```

`-v` supprime les volumes. Comme `pg_data` est vide au redémarrage, PostgreSQL rejoue `init-db/01-data.sql` : seules les 3 notes de démo restent.

### Test 6 : Modifier une variable

```bash
# Modifier APP_NAME dans .env
sed -i 's/^APP_NAME=.*/APP_NAME=Mon Application Modifiée/' .env
#   (ou à la main : APP_NAME=Mon Application Modifiée)

# ❌ "restart" ne suffit PAS : il redémarre le même conteneur, avec l'ancienne configuration
docker compose restart app
curl http://localhost:8080/api/info/app
# {"name":"Notes Manager",...}                 <- inchangé

# ✅ Recréer le conteneur app : Compose détecte que la config a changé et recrée le conteneur
docker compose up -d app
#  Container exercice-10-app-1 Recreated / Started
#  (équivalent explicite : docker compose up -d --force-recreate app)

# Vérifier le changement
curl http://localhost:8080/api/info/app
# {"name":"Mon Application Modifiée","version":"1.0.0","environment":"production","uploadPath":"/app/uploads"}
curl http://localhost:8080/api/info/env
# {"APP_NAME":"Mon Application Modifiée", ...}
```

Le nom a changé **sans reconstruire l'image ni modifier le code** : il suffit de recréer le conteneur.

(J'ai ensuite remis `APP_NAME=Notes Manager` dans le `.env`.)

---

## Rappels théoriques

### Variables d'environnement : 3 méthodes d'injection

```yaml
environment:
  # Méthode 1 : depuis le fichier .env
  APP_NAME: ${APP_NAME}

  # Méthode 2 : valeur en dur
  DB_HOST: db

  # Méthode 3 : avec valeur par défaut (utilisée si la variable est absente ou vide)
  LOG_LEVEL: ${LOG_LEVEL:-INFO}
```

Démonstration de la méthode 3 : si on commente `MAX_FILE_SIZE` dans le `.env` :

```bash
sed -i 's/^MAX_FILE_SIZE=/#MAX_FILE_SIZE=/' .env
docker compose config | grep MAX_FILE_SIZE
#       MAX_FILE_SIZE: 5MB      <- valeur par défaut
sed -i 's/^#MAX_FILE_SIZE=/MAX_FILE_SIZE=/' .env
docker compose config | grep MAX_FILE_SIZE
#       MAX_FILE_SIZE: 10MB     <- valeur du .env
```

Autres possibilités :
- `${VAR:?message}` : erreur si la variable est absente ;
- `env_file: .env` : injecte **toutes** les variables du fichier dans le conteneur ;
- `docker compose --env-file prod.env up -d` : utiliser un autre fichier `.env`.

### Volumes

| Type | Exemple | Usage ici |
|---|---|---|
| Volume nommé | `pg_data:/var/lib/postgresql/data` | Données de la BdD et uploads, gérés par Docker, conservés après `down` |
| Bind mount | `./init-db:/docker-entrypoint-initdb.d:ro` | Partager un dossier de l'hôte (scripts SQL) |

| Commande | Conteneurs | Réseau | Volumes |
|---|---|---|---|
| `docker compose stop` | arrêtés | conservé | conservés |
| `docker compose down` | supprimés | supprimé | **conservés** |
| `docker compose down -v` | supprimés | supprimé | **supprimés** |

## Nettoyage

```bash
docker compose down -v
docker rmi notes-app
docker start ex02-2048     # pour relancer le 2048 de l'exercice 2
```
