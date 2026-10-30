# TP04 — Une stack Compose d'entreprise

Livrables : `compose.yml`, `compose.override.yml`, `compose.prod.yml`, `.env.example`, `Makefile`,
`smoke-test.sh`, `db/init.sql`, `migrations/002-add-sku.sql`. Les sorties brutes sont dans `logs/`.

Les applications (`apps/shopapi`, `apps/shop-worker`) sont copiées du TP01 et du TP02 sans aucune modification.

## 1. Critique de `starter/docker-compose.yml`

| # | Problème | Conséquence |
|---|----------|-------------|
| 1 | `version: '3'` | Clé obsolète, ignorée par Compose v2, qui affiche un warning. |
| 2 | `links` | Mécanisme legacy : le DNS d'un réseau utilisateur suffit. |
| 3 | `image: postgres` / `redis` sans tag | `latest` change sans prévenir (PG 16 → 17 casse le volume). |
| 4 | `ports` 5432 et 6379 publiés | Base et Redis joignables depuis le LAN, voire Internet ; Redis sans mot de passe. |
| 5 | Mots de passe en clair (`POSTGRES_PASSWORD`, `DATABASE_URL`) | Secret versionné dans git et visible dans `docker inspect`. |
| 6 | Superutilisateur `postgres` utilisé par l'application | Aucun moindre privilège. |
| 7 | `sleep 10 && node ...` | Démarrage fragile : trop court sur une machine lente, du temps perdu ailleurs. `sh` devient PID 1 et ne relaie pas SIGTERM. |
| 8 | Un seul réseau `default` | Pas de segmentation : tout le monde parle à la base. |
| 9 | Aucun healthcheck | `depends_on` n'attend que le démarrage du conteneur et `up --wait` ne prouve rien. |
| 10 | Pas de volume nommé pour PG et Redis | Volume anonyme : les données sont perdues au `rm -v` et difficiles à identifier. |
| 11 | `restart` incohérent (`always` sur le worker seulement) | La base et l'API ne redémarrent pas après un crash ou un reboot. |
| 12 | Pas de limites CPU/mémoire ni de rotation des logs | Un conteneur peut saturer l'hôte, et `json-file` remplit le disque. |
| 13 | Pas de reverse proxy, l'API est exposée directement | Pas de point d'entrée unique, pas de répartition de charge entre réplicas. |
| 14 | Pas de nom de projet | Les noms de réseaux et de volumes dépendent du nom du dossier. |

## 2. Fichier de base `compose.yml`

Choix principaux :

- **`name: shop`** : réseaux et volumes stables (`shop_front`, `shop_back`, `shop_pgdata`), ce dont les TP05 et TP07 ont besoin.
- **Réseaux** : `front` (traefik, api, adminer) et `back` en `internal: true` (api, worker, db, redis, migrate). Redis et PG ne sont sur aucun réseau qui sort de l'hôte et ne publient aucun port.
- **Ancres YAML** : `x-healthcheck-defaults` (fusionnée avec `<<:` dans chaque `healthcheck`), `x-logging` (json-file 10m × 3) et `x-app` (ce qui est commun à l'api et au worker : restart, secret, depends_on).
- **Secret** : `secrets/db_password.txt` (gitignored) est monté dans `/run/secrets/db_password`. PG le lit via `POSTGRES_PASSWORD_FILE`. Pour l'api et le worker, qui ne lisent que `DATABASE_URL`, la commande construit l'URL au démarrage sans toucher au code :
  ```yaml
  command: [sh, -c, 'export DATABASE_URL="postgres://shop:$$(cat /run/secrets/db_password)@db:5432/shop" && exec node src/server.js']
  ```
  `$$` empêche Compose d'interpoler, et `exec` laisse node en PID 1, qui reçoit donc SIGTERM. Le mot de passe est en hexadécimal, donc il n'y a pas d'encodage d'URL à faire. Le fichier est en `644` parce que l'entrypoint postgres le relit après être passé à l'utilisateur `postgres` (uid 70), et l'api (uid 1000) doit aussi le lire.
- **Démarrage ordonné** : `depends_on: condition: service_healthy` et le healthcheck de l'api sur `/ready` (db + redis), pas `/health`. `up --wait` ne rend la main qu'une fois toute la stack `healthy`.
- **Traefik** : routage par labels, `api.localhost` → api:3000, healthcheck de backend sur `/ready`.
  - ⚠️ L'énoncé demande `traefik:v3.1`, mais son client Docker parle l'API 1.24, refusée par Docker 29 (API minimale 1.40) : aucune route n'est découverte. J'utilise donc **`traefik:v3.6`**, la première ligne compatible.
- **Profils** : `tools` (adminer sur `adminer.localhost`) et `ops` (`migrate`, à usage unique).

```
$ docker compose up -d --build --wait && docker compose ps
NAME             IMAGE                  STATUS                   PORTS
shop-api-1       shop-api               Up 1 second (healthy)    0.0.0.0:3000->3000/tcp
shop-db-1        postgres:16.4-alpine   Up 5 seconds (healthy)   0.0.0.0:5432->5432/tcp
shop-redis-1     redis:7.4-alpine       Up 5 seconds (healthy)   6379/tcp
shop-traefik-1   traefik:v3.6           Up 5 seconds (healthy)   0.0.0.0:80->80/tcp, 0.0.0.0:8080->8080/tcp
shop-worker-1    shop-worker            Up 1 second (healthy)    9100/tcp

$ make migrate M=002-add-sku.sql
ALTER TABLE
UPDATE 3

$ make tools && curl -s -o /dev/null -w '%{http_code}' http://adminer.localhost/
200
```

À noter : juste après `make tools`, adminer a d'abord répondu 404. Traefik n'ajoute la route d'un conteneur qu'une fois son healthcheck sorti de l'état `starting`.

## 3. Surcharge dev `compose.override.yml`

- L'api reçoit `./apps/shopapi/src` en bind mount (`ro`) et tourne avec `node --watch`, `LOG_LEVEL=debug` et le port 3000 publié.
- Le dashboard Traefik est activé sur le port 8080 via `TRAEFIK_API_INSECURE` : une variable d'environnement se fusionne, alors que surcharger `command` aurait remplacé toute la liste.
- Le port 5432 est publié. Un réseau `internal` ne peut pas publier de port, donc **en dev uniquement** `back` repasse à `internal: false`.

```
$ curl api.localhost/
{"service":"shopapi","version":"0.0.0-dev"}
# server.js modifié
api-1  | Restarting 'src/server.js'
api-1  | {"level":30,...,"msg":"shopapi démarré"}
$ curl localhost:3000/
{"service":"shopapi","reloaded":true,"version":"0.0.0-dev"}
```

## 4. Surcharge prod `compose.prod.yml`

- `build: !reset null` supprime la clé héritée. L'image vient de `${REGISTRY}/shopapi:${VERSION}`, avec `${REGISTRY:?…}` qui rend la variable obligatoire (bonus B4) :
  ```
  $ REGISTRY= docker compose -f compose.yml -f compose.prod.yml config
  error while interpolating services.api.image: required variable REGISTRY is missing a value: REGISTRY must be set
  ```
- Le registre du TP03 est arrêté : `.env` pointe sur `localhost:5000` avec `VERSION=1.0`, et `pull_policy: missing` utilise les images déjà présentes en local, sans pull.
- L'api et le worker sont durcis avec `read_only` + `tmpfs: /tmp`, `cap_drop: [ALL]` et `no-new-privileges`. Tous les services ont des limites CPU/mémoire. Aucun port de debug ni de dashboard n'est ouvert.

```
NAME             IMAGE                            STATUS                   PORTS
shop-api-1       localhost:5000/shopapi:1.0       Up 2 seconds (healthy)   3000/tcp
shop-api-2       localhost:5000/shopapi:1.0       Up 2 seconds (healthy)   3000/tcp
shop-traefik-1   traefik:v3.6                     Up 4 seconds (healthy)   0.0.0.0:80->80/tcp
...
# 6 × curl api.localhost/products, logs d'accès Traefik (URL du backend) :
      3 "api@docker" "http://172.31.0.3:3000"
      3 "api@docker" "http://172.31.0.4:3000"
ReadOnly=true CapDrop=[ALL] SecOpt=[no-new-privileges:true] Mem=268435456 NanoCpus=500000000
prod: 5432 fermé / prod: 8080 (dashboard) fermé
OK: smoke test passed
```

Traefik répartit les requêtes en round-robin entre les deux réplicas, sans que l'application ait à exposer son id.

**`up -d --scale api=3` puis `up -d`** : le scale crée `shop-api-3`, que Traefik découvre automatiquement. Le `up -d` suivant revient à la valeur déclarée (`deploy.replicas: 2`) et **supprime** `shop-api-3`. Le scale manuel n'est pas persistant : le fichier reste la source de vérité.

## 5. Outillage

`make up | down | prod-up | prod-down | migrate M=… | tools | test | config`.
`smoke-test.sh` passe par Traefik : `/ready`, puis `/products` deux fois (le second appel doit renvoyer `X-Cache: HIT`), puis `POST /orders`. Il attend ensuite que la dernière commande passe en `confirmed` en base, ce qui prouve que le worker l'a consommée. Il passe en dev et en prod (`COMPOSE="docker compose -f compose.yml -f compose.prod.yml"`).

## Bonus

- **B3** : adminer est sur `front` **et** `back`. Traefik le joint par `front`, un réseau qui sort de l'hôte, et adminer joint la base par `back`. `internal` empêche seulement la sortie vers l'extérieur du réseau `back`, pas un conteneur relié à deux réseaux de faire passerelle.
- **B4** : fait (voir l'étape 4).
