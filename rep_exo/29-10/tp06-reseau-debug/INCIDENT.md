# Rapport d'incident — préprod Shop SAS

**Heure de début** : 10:18 · **Heure de résolution** : 10:20 (diagnostic + correctifs, environ 25 min en comptant la rédaction) · **Impact** : préprod indisponible (port 8081 sans réponse)

Livrables corrigés : `compose.yml` (chaque correctif est annoté `#N`) et `nginx/default.conf`. Les preuves brutes sont dans `logs/02-symptomes.txt` et `logs/03-verification.txt`.

Adaptation : les chemins `../../tp04-compose-entreprise/solution/...` pointent désormais vers ma réponse du TP04 (`../tp04-compose-entreprise/...`). Le code et l'image sont inchangés.

## Chronologie du diagnostic

| Heure | Symptôme observé | Commande / preuve | Hypothèse | Résultat |
|-------|------------------|-------------------|-----------|----------|
| 10:18 | La stack ne démarre pas | `docker compose config -q` → `can't set container_name and api as container name must be unique` | `container_name` est incompatible avec `replicas: 2` | Confirmé → #1 |
| 10:18 | Le build échoue | `docker compose up` → bake demande `--allow=fs.read=…/rep_exo` : le contexte `../../tp04…/solution/apps/shopapi` n'existe pas | Chemin relatif faux | Confirmé → #2 |
| 10:18 | `front` ne démarre pas | `not a directory: Are you trying to mount a directory onto a file` | Le dossier `./nginx` est monté sur le fichier `default.conf` | Confirmé → #3 |
| 10:18 | `curl localhost:8081` → code 000 (exit 7, connexion refusée) | `docker inspect front … .NetworkSettings.Ports` → `{"80/tcp":null}` ; `docker network inspect incident_public` → `internal=true` | Un réseau `internal` ne publie pas de port | Confirmé → #8 |
| 10:18 | Les 2 api sont en `Exited (1)` | `docker compose logs api` → `Cannot find module '/app/server.js'` | Mauvais chemin dans `command` | Confirmé → #4 |
| 10:18 | db `healthy`, mais `FATAL: role "postgres" does not exist` toutes les 5 s | `docker compose logs db \| grep FATAL` | Le healthcheck utilise le mauvais utilisateur (`pg_isready` dit « ok » même sans le rôle) | Confirmé → #11 |
| 10:18 | redis absent du réseau, port 6379 ouvert sur **toutes** les interfaces de l'hôte | `docker inspect redis … NetworkMode` → `host` ; `ss -tln \| grep 6379` → `0.0.0.0:6379` | `network_mode: host` : redis est injoignable par son nom et exposé au LAN | Confirmé → #9 |
| 10:19 | Les api restent en `health: starting` | Log du healthcheck : `can't connect to 127.0.0.1` ; `netstat -tln` → écoute sur `:::8080` | `PORT=8080`, alors que l'image (healthcheck) et nginx attendent 3000 | Confirmé → #5 |
| 10:19 | `/ready` → 503 | `wget 127.0.0.1:8080/ready` → 503 ; `getent hosts databse db redis` → aucun résolu | (a) faute de frappe `databse`, (b) l'api n'est que sur `public` | Confirmé → #6, #7 (`.Networks` → `["incident_public"]`) |
| 10:19 | (lecture du compose) | `REDIS_URL: redis://redis:6379` alors que `--requirepass r3dis` | `NOAUTH` dès que redis serait joignable | Corrigé → #10 |
| 10:19 | (lecture de la conf nginx) | `proxy_pass http://localhost:3000` | Dans le conteneur front, `localhost` désigne nginx lui-même | Corrigé → #12 |
| 10:20 | `up` refusé : `container … is not connected to the network incident_backend` | — | Passer redis de `host` à un réseau et changer `internal` exige de recréer conteneurs et réseaux | `docker compose down` (sans `-v`) puis `up` |
| 10:20 | **Résolu** | `docker compose ps` : 5 conteneurs `healthy` ; `curl -si :8081/products` → `MISS` puis `HIT` ; 6379 fermé sur l'hôte ; 0 log `role "postgres"` | | ✅ |

## Anomalies trouvées

| # | Fichier / service | Anomalie | Correction | Catégorie |
|---|-------------------|----------|------------|-----------|
| 1 | compose / api | `container_name: api` avec `deploy.replicas: 2` | Supprimé (Compose nomme `incident-api-N`) | config |
| 2 | compose / api, db | `build` et `init.sql` pointent vers un chemin inexistant | `../tp04-compose-entreprise/...` | config / stockage |
| 3 | compose / front | Bind mount d'un dossier sur un fichier | `./nginx/default.conf:/etc/nginx/conf.d/default.conf:ro` | stockage |
| 4 | compose / api | `command: node server.js` (le fichier est dans `src/`) | `["node", "src/server.js"]` | cycle de vie |
| 5 | compose / api | `PORT: 8080`, alors que le healthcheck de l'image et nginx visent 3000 | `PORT: 3000` | config |
| 6 | compose / api | `DATABASE_URL` vers l'hôte `databse` (faute de frappe) | `db` | config |
| 7 | compose / api | api absente du réseau `backend`, donc pas d'accès à db ni à redis | `networks: [public, backend]` | réseau |
| 8 | compose / networks | `public` en `internal: true`, donc 8081 n'est pas publié, alors que `backend` est ouvert | `public` normal ; `backend` en `internal: true` | réseau |
| 9 | compose / redis | `network_mode: host` : pas de DNS `redis`, et 6379 exposé sur toutes les interfaces de l'hôte | Réseau `backend` | réseau / sécurité |
| 10 | compose / api | `REDIS_URL` sans le mot de passe `r3dis` | `redis://:r3dis@redis:6379` | config |
| 11 | compose / db | Healthcheck `pg_isready -U postgres` (rôle inexistant, logs FATAL) | `pg_isready -U shop -d shop` | config |
| 12 | nginx/default.conf | `proxy_pass http://localhost:3000` | `proxy_pass http://api:3000` | réseau |
| 13 | compose / front, api, redis | Pas de healthcheck sur front ni redis ; `depends_on` sans condition ; api ne dépend pas de redis | Healthchecks + `condition: service_healthy` | cycle de vie |
| 14 | compose | Mots de passe en clair (`shop`, `r3dis`) | Non corrigé ici (hors périmètre de l'incident) → secrets comme au TP04 | sécurité |

## Pourquoi ça n'a pas été détecté avant ?

- Personne n'a lancé `docker compose config`, qui aurait bloqué l'anomalie #1 en une seconde.
- Sans healthchecks ni `up --wait`, un `docker compose up -d` « réussit » même quand l'api crashe en boucle : le retour est vert.
- Aucun test de bout en bout (`curl :8081/products`) après la modification, et pas de revue du compose avant le départ en congé.
- Certaines erreurs restent silencieuses : le healthcheck db est `healthy` malgré le mauvais rôle, et redis en mode `host` « marche » tout en étant exposé.

## Actions de prévention

1. **CI sur le compose** : `docker compose config -q` (schéma et interpolation), puis `docker compose up -d --wait` et un smoke test (`curl -f :8081/products`, vérification de `X-Cache: HIT`), à chaque merge request qui touche `compose.yml` ou `nginx/`. C'est le `smoke-test.sh` du TP04.
2. **Healthchecks obligatoires et `--wait`** : chaque service a un healthcheck **qui teste la vraie dépendance** (`/ready` et pas `/health`, le bon utilisateur PG), et chaque `depends_on` porte une `condition: service_healthy`. Un déploiement qui ne devient pas `healthy` échoue au lieu de passer en vert.
3. **Revue de code et lint** : le compose passe en MR avec une revue obligatoire. Un lint (`dclint` ou une règle maison) refuse `network_mode: host`, `container_name` avec `replicas`, `internal` sur le réseau qui publie des ports, et les mots de passe en clair.
