# TP01 — Reprendre en main une image « historique »

API `shopapi` (Node.js) reprise de `02_exercices_sujet/26-10/tp01-optimisation-image/starter/shopapi/`. **Le code applicatif (`src/`, `test/`, `package.json`) n'est pas modifié.**

| Fichier | Rôle |
|---|---|
| [`DIAGNOSTIC.md`](DIAGNOSTIC.md) | **Livrable 1** : 18 problèmes classés en taille/perf, sécurité, exploitabilité |
| [`shopapi/Dockerfile`](shopapi/Dockerfile) | **Dockerfile final** (multi-stage `base → deps-dev → test → deps-prod → runtime`) |
| [`shopapi/.dockerignore`](shopapi/.dockerignore) | Allowlist : seuls `package*.json`, `src/`, `test/` entrent dans le contexte |
| [`shopapi/package-lock.json`](shopapi/package-lock.json) | Lockfile ajouté (nécessaire à `npm ci` et à la reproductibilité) |
| [`shopapi/Dockerfile.distroless`](shopapi/Dockerfile.distroless) | Bonus B1 |
| [`shopapi/Dockerfile.legacy`](shopapi/Dockerfile.legacy) (+ `.dockerignore` dédié vide) | Dockerfile historique, conservé pour la comparaison |
| [`logs/`](logs/) | Sorties brutes de toutes les commandes |

Outils non installés sur le poste (pas de sudo), donc lancés **en conteneur** :

```bash
docker run --rm -i hadolint/hadolint < Dockerfile
docker run --rm -e CI=true -v /var/run/docker.sock:/var/run/docker.sock:Z wagoodman/dive shopapi:legacy --ci
```

(`:Z` pour SELinux sous Fedora, sinon le conteneur dive n'a pas accès au socket.)

---

## 1. Diagnostic

Voir **[DIAGNOSTIC.md](DIAGNOSTIC.md)**. En résumé : 738 Mo, dont 367 Mo d'outils de build, root, mot de passe dans un `ENV`, `.env` avec clé AWS et dump de prod dans l'image, `npm install` rejoué à chaque commit, `sh` en PID 1 qui avale SIGTERM, 5 warnings hadolint, ni healthcheck ni labels.

## 2. Invalidation du cache

```text
$ time docker build -t shopapi:legacy .          # rien n'a changé
#13 [9/9] RUN npm install
#13 CACHED
real	0m0,649s

$ echo "// commentaire" >> src/server.js
$ time docker build -t shopapi:legacy .
#11 [7/9] WORKDIR /app
#11 CACHED
#12 [8/9] COPY . /app
#12 DONE 0.1s
#13 [9/9] RUN npm install
#13 5.523 added 222 packages, and audited 223 packages in 5s
#13 DONE 5.8s
real	0m6,522s
```

**Pourquoi `npm install` est rejoué** : BuildKit calcule la clé de cache d'un `COPY` à partir du **checksum des fichiers copiés**. `COPY . /app` copie *tout*, donc modifier `server.js` (ou un README, ou le Dockerfile lui-même) change le checksum, ce qui invalide la couche **et toutes celles qui suivent**. `npm install` arrive après : il est rejoué alors que `package.json` n'a pas bougé.

**Ordre idéal des couches**, du plus stable au plus volatile :

```text
┌──────────────────────────────────────────────┐  change…
│ FROM node:20.20.2-alpine3.23 (épinglée)      │  ← tous les quelques mois (patch Node/Alpine)
├──────────────────────────────────────────────┤
│ WORKDIR /app                                 │
├──────────────────────────────────────────────┤
│ COPY package.json package-lock.json ./       │  ← quand on ajoute ou met à jour une dépendance
├──────────────────────────────────────────────┤
│ RUN npm ci --omit=dev  (+ cache mount npm)   │  ← idem : seule couche lourde, réutilisée
├──────────────────────────────────────────────┤
│ COPY src ./src                               │  ← à chaque commit (quelques Ko)
├──────────────────────────────────────────────┤
│ USER / HEALTHCHECK / CMD (métadonnées)       │
└──────────────────────────────────────────────┘
```

Résultat avec le nouveau Dockerfile :

```text
$ echo "// commentaire" >> src/server.js
$ time docker build --build-arg APP_VERSION=1.4.2 --build-arg GIT_SHA=068ba9e -t shopapi:1.4.2 .
#9  [base 3/3] COPY package.json package-lock.json ./
#9  CACHED
#10 [deps-dev 1/1] RUN --mount=type=cache,target=/root/.npm     npm ci --ignore-scripts --no-audit --no-fund
#10 CACHED
#11 [test 1/3] COPY src ./src
#12 [test 2/3] COPY test ./test
#13 [test 3/3] RUN npm run lint && npm test && touch /tmp/.tests-passed
#13 DONE 3.1s
#14 [deps-prod 1/1] RUN --mount=type=cache,target=/root/.npm  --mount=type=bind,from=test,...  npm ci --omit=dev ...
#14 CACHED
#15 [runtime 3/5] COPY --from=deps-prod /app/node_modules ./node_modules
#15 CACHED
#17 [runtime 5/5] COPY src ./src
#17 DONE 0.0s
real	0m3,995s
```

Les deux `npm ci` sont `CACHED`. Les 4 s restantes correspondent aux tests, qui *doivent* être rejoués quand le code change.

## 3. Le Dockerfile final

> Version finale, après deux ajustements faits dans les TP suivants (voir [§ Mises à jour](#mises-à-jour-après-les-tp02-et-tp03)) : `RUN apk upgrade` + suppression de npm dans le runtime (TP03), stages de build en `--platform=$BUILDPLATFORM` (TP02).

```dockerfile
# syntax=docker/dockerfile:1.7
# shopapi - Shop SAS image standards compliant Dockerfile.
ARG NODE_IMAGE=node:20.20.2-alpine3.23

# ---- base: lockfile only, so dependency layers depend on nothing else
# Build stages run on the build machine's platform: deps are pure JS (--ignore-scripts), so they are
# architecture independent and a multi-arch build does not emulate npm ci.
FROM --platform=$BUILDPLATFORM ${NODE_IMAGE} AS base
WORKDIR /app
COPY package.json package-lock.json ./

# ---- deps-dev: full dependency tree (lint/test tooling)
FROM base AS deps-dev
RUN --mount=type=cache,target=/root/.npm \
    npm ci --ignore-scripts --no-audit --no-fund

# ---- test: lint + unit tests, fails the build on error
FROM deps-dev AS test
COPY src ./src
COPY test ./test
RUN npm run lint && npm test && touch /tmp/.tests-passed

# ---- deps-prod: runtime dependencies only
# The bind mount on the test stage forces BuildKit to run the tests before any release build.
FROM base AS deps-prod
RUN --mount=type=cache,target=/root/.npm \
    --mount=type=bind,from=test,source=/tmp/.tests-passed,target=/tmp/.tests-passed \
    npm ci --omit=dev --ignore-scripts --no-audit --no-fund

# ---- runtime
FROM ${NODE_IMAGE} AS runtime
# Global ARG must be re-declared to be visible inside the stage (used by a label).
ARG NODE_IMAGE
ARG APP_VERSION=0.0.0-dev
ARG GIT_SHA=unknown
ARG SOURCE_URL=https://git.shop-sas.example/platform/shopapi
LABEL org.opencontainers.image.title="shopapi" \
      org.opencontainers.image.description="Shop SAS product catalogue API" \
      org.opencontainers.image.vendor="Shop SAS" \
      org.opencontainers.image.version="${APP_VERSION}" \
      org.opencontainers.image.revision="${GIT_SHA}" \
      org.opencontainers.image.source="${SOURCE_URL}" \
      org.opencontainers.image.base.name="${NODE_IMAGE}"
ENV NODE_ENV=production \
    APP_VERSION=${APP_VERSION} \
    PORT=3000
# Node 20 is EOL: its base image is no longer rebuilt. Apply pending Alpine security fixes and drop
# the package managers bundled with the image (npm ships vulnerable tar/minimatch/cross-spawn...),
# which the runtime never uses. Flagged by trivy in the TP03 release gate.
RUN apk upgrade --no-cache \
    && rm -rf /usr/local/lib/node_modules/npm /usr/local/lib/node_modules/corepack /opt/yarn-* \
              /usr/local/bin/npm /usr/local/bin/npx /usr/local/bin/corepack /usr/local/bin/yarn /usr/local/bin/yarnpkg
WORKDIR /app
# Files stay owned by root: the node user can read but not modify the application.
COPY --from=deps-prod /app/node_modules ./node_modules
COPY package.json ./
COPY src ./src
# Numeric uid (= node) so Kubernetes runAsNonRoot can verify it without /etc/passwd.
USER 1000:1000
EXPOSE 3000
HEALTHCHECK --interval=15s --timeout=3s --start-period=10s --start-interval=1s --retries=3 \
    CMD ["wget", "-q", "-O", "/dev/null", "http://127.0.0.1:3000/health"]
# Exec form: node is PID 1 and receives SIGTERM directly (handled in src/server.js).
CMD ["node", "src/server.js"]
```

`.dockerignore` (allowlist, plus sûr qu'une liste d'exclusions : un nouveau fichier sensible est exclu par défaut) :

```gitignore
*
!package.json
!package-lock.json
!src/
!test/
```

### Choix et justifications

| Standard | Mise en œuvre |
|---|---|
| 1. < 200 Mo, base officielle épinglée | `node:20.20.2-alpine3.23`, avec versions Node **et** Alpine figées dans le tag. On peut aller plus loin avec `@sha256:fb4cd12c…` (immuable) : c'est ce que fait la variante distroless. **Alpine plutôt que slim** : aucun module natif (pg, ioredis, express sont en JS pur), donc musl ne pose pas de problème, et l'image fait 136 Mo contre ~200 Mo. |
| 2. Non-root, forme exec | `USER 1000:1000` (= `node`). Uid numérique pour que `runAsNonRoot` de Kubernetes puisse le vérifier, ce qui supprime aussi le DL3066 de hadolint. `CMD ["node", "src/server.js"]` : node est PID 1 **sans** `npm` intermédiaire (npm ne relaie pas correctement les signaux). |
| 3. Aucun secret ni fichier inutile | `.dockerignore` en allowlist, plus de `ENV DATABASE_URL` : la config arrive au runtime (`-e`, secrets d'orchestrateur). Seuls `node_modules` (prod), `package.json` et `src/` sont copiés dans l'image finale, `test/` reste dans le stage `test`. |
| 4. Reproductible, cache-friendly | `package-lock.json` versionné et `npm ci` (installe exactement le lockfile, échoue s'il est désynchronisé). Manifestes copiés avant le code. Cache mount `/root/.npm`. `--ignore-scripts` : aucun script `postinstall` tiers n'est exécuté. |
| 5. `HEALTHCHECK`, labels OCI | `wget` (busybox, déjà dans Alpine, sans paquet à ajouter) sur `/health`. `--start-interval=1s` : sonde chaque seconde pendant la `start-period`, donc `healthy` en ~1 s au lieu d'attendre le premier `interval`. Labels `version`/`revision`/`source` alimentés par `ARG`. |
| 6. Pas de deps de dev, tests dans le build | Stage `test` dédié (`npm run lint && npm test`). Le `--mount=type=bind,from=test` dans `deps-prod` crée une **dépendance** : BuildKit ne construit que les stages nécessaires à la cible, et sans ce lien un `docker build` sans `--target` *sauterait* les tests. Le fichier n'est monté que pendant le `RUN`, il n'y a donc aucune trace dans l'image finale. |
| 7. hadolint propre | Voir ci-dessous. |

Les fichiers de l'application appartiennent à `root` et sont en lecture seule pour `node` : un attaquant qui exécute du code en tant que `node` ne peut pas modifier l'application. On peut aussi lancer avec `--read-only`.

### Builds

```text
$ docker build --build-arg APP_VERSION=1.4.2 --build-arg GIT_SHA=$(git rev-parse --short HEAD 2>/dev/null || echo local) -t shopapi:1.4.2 .
...
#15 [test 3/3] RUN npm run lint && npm test && touch /tmp/.tests-passed
#15 3.091 ok 1 - le module serveur se charge
#15 3.097 # tests 1
#15 3.097 # pass 1
#15 3.097 # fail 0
#16 [deps-prod 1/1] RUN ... npm ci --omit=dev --ignore-scripts --no-audit --no-fund
#16 0.589 added 114 packages in 408ms
...
#20 naming to docker.io/library/shopapi:1.4.2 done
real	0m10,177s

$ docker build --target test -t shopapi:test .          # les tests doivent passer
#14 naming to docker.io/library/shopapi:test done
```

## 4. Conformité

```text
$ docker image ls shopapi                                # < 200 Mo
IMAGE                      ID             DISK USAGE   CONTENT SIZE   EXTRA
shopapi:1.4.2              daea3db185be        144MB             0B
shopapi:1.4.2-distroless   61590d477954        130MB             0B
shopapi:legacy             b5bce0e99fcf        738MB             0B
shopapi:test               ad33d5dbb06f        157MB             0B

$ docker run --rm shopapi:1.4.2 id                       # uid=1000(node)
uid=1000(node) gid=1000(node) groups=1000(node)

$ docker run --rm shopapi:1.4.2 ls -la /app              # pas de .env ni de *.sql
drwxr-xr-x    1 root     root          2434 Oct 26 09:56 node_modules
-rw-r--r--    1 root     root           545 Oct 26 09:50 package.json
drwxr-xr-x    1 root     root            18 Oct 26 09:56 src

$ docker run --rm shopapi:1.4.2 sh -c 'ls node_modules | grep -cE "^(eslint|nodemon)$"; env | grep -iE "secret|database"; echo none'
0
none

$ docker inspect shopapi:1.4.2 --format '{{json .Config.Labels}}' | jq
{
  "org.opencontainers.image.base.name": "node:20.20.2-alpine3.23",
  "org.opencontainers.image.description": "Shop SAS product catalogue API",
  "org.opencontainers.image.revision": "068ba9e",
  "org.opencontainers.image.source": "https://git.shop-sas.example/platform/shopapi",
  "org.opencontainers.image.title": "shopapi",
  "org.opencontainers.image.vendor": "Shop SAS",
  "org.opencontainers.image.version": "1.4.2"
}

$ docker run -d --name api -p 3000:3000 shopapi:1.4.2
$ sleep 6 && docker inspect api --format '{{.State.Health.Status}}'   # healthy
healthy

$ curl -s localhost:3000/products | jq
[
  { "id": 1, "name": "Clavier mécanique", "price": 89.9, "stock": 12 },
  { "id": 2, "name": "Écran 27\"", "price": 249, "stock": 4 },
  { "id": 3, "name": "Souris sans fil", "price": 29.5, "stock": 40 }
]
$ curl -s localhost:3000/
{"service":"shopapi","version":"1.4.2"}

$ docker exec api ps -o pid,user,args
PID   USER     COMMAND
    1 node     node src/server.js

$ time docker stop api                                   # < 1 s (SIGTERM géré)
real	0m0,172s
$ docker logs api | tail -1
{"level":30,...,"pid":1,"signal":"SIGTERM","msg":"arrêt demandé"}
$ docker inspect api --format "{{.State.ExitCode}}"
0
```

> Petit bug rencontré : au premier build, le label `base.name` était **vide**. Un `ARG` déclaré avant le premier `FROM` n'est visible que dans les lignes `FROM`. Pour l'utiliser dans un stage, il faut le redéclarer (`ARG NODE_IMAGE` sans valeur) à l'intérieur du stage.

### `docker stop` : legacy vs nouvelle image

| | legacy | 1.4.2 |
|---|---|---|
| PID 1 | `/bin/sh -c npm start` → `npm` → `sh` → `node` (PID 19) | `node src/server.js` |
| `time docker stop` | **10,18 s** | **0,17 s** |
| Code de sortie | **137** (SIGKILL) | **0** |
| Log « arrêt demandé » | absent | présent |

**Explication** : `docker stop` envoie **SIGTERM au PID 1** puis attend `--time` (10 s par défaut) avant d'envoyer SIGKILL.

- *Legacy* : la forme shell `CMD npm start` est traduite en `["/bin/sh","-c","npm start"]`, donc PID 1 = `sh`. Le noyau n'applique pas l'action par défaut d'un signal au PID 1 d'un namespace : un SIGTERM sans handler est **ignoré**. `sh` n'a pas de handler et ne propage rien à ses enfants. Node ne voit jamais le signal, et au bout de 10 s Docker envoie SIGKILL, qui ne peut pas être ignoré (exit 128 + 9 = 137). Les requêtes en cours sont coupées et les connexions PG/Redis restent ouvertes côté serveur.
- *Nouvelle image* : la forme exec lance `node` directement en PID 1. Node installe un handler (`process.on('SIGTERM', …)`), donc le signal est délivré, `server.close()` termine les requêtes en cours, et `process.exit(0)` sort en 170 ms.

Pour un processus qui ne gère pas les signaux ou qui crée des enfants (zombies), on ajouterait un init minimal : `docker run --init` (tini) ou `ENTRYPOINT ["/sbin/tini","--"]`. Ce n'est pas nécessaire ici.

## 5. Rapport (livrable 2)

| Critère | `shopapi:legacy` | `shopapi:1.4.2` | Gain |
|---|---|---|---|
| Taille | **738 Mo** | **144 Mo** (152 Mo après le correctif CVE du TP03) | −80 % |
| Couches (`RootFS.Layers`) | 9 | 8 (dont 5 de l'image node) | 3 couches propres à l'app |
| Rebuild après un changement de code | 6,5 s, `npm install` rejoué (≈ 4 min en CI) | 4,0 s, `npm ci` en cache (3,1 s = les tests) | dépendances jamais réinstallées |
| Utilisateur | `uid=0(root)` | `uid=1000(node)` | |
| Temps d'arrêt (`docker stop`) | 10,18 s, exit 137 | 0,17 s, exit 0 | ×60 |
| Secrets / fichiers inutiles | `DATABASE_URL` en ENV, `.env`, dump SQL, Dockerfile | aucun | |
| Deps de dev | eslint, nodemon (×2), 222 paquets | 114 paquets de prod | |
| `HEALTHCHECK` | aucun | `wget /health`, healthy en ~1 s | |
| Labels OCI | `version=22.04` (hérité, faux) | version, revision, source, title, base.name | |
| Tests au build | non | stage `test`, bloquant | |
| hadolint | 5 warnings + 5 infos, exit 1 | **sortie vide, exit 0** | |

Sortie `hadolint` sur le Dockerfile final :

```text
$ docker run --rm -i hadolint/hadolint < Dockerfile
$ echo $?
0
```


## Mises à jour après les TP02 et TP03

1. **TP03, porte de release** : trivy a trouvé 22 CVE HIGH/CRITICAL corrigeables dans **npm**, livré avec l'image de base (tar, minimatch, cross-spawn…), et 4 dans OpenSSL. Node 20 est en fin de vie et `node:20-alpine` n'est plus reconstruite. Le runtime fait donc `apk upgrade` et supprime npm, npx, corepack et yarn, qu'il n'utilise jamais. Résultat : 0 CVE HIGH/CRITICAL corrigeable, et la porte accepte l'image. Elle passe de **144 à 152 Mo** : la suppression se fait dans une nouvelle couche et ne réduit pas les couches de base. La vraie correction durable serait de passer à `node:22`/`node:24-alpine`, ce que `"engines": ">=20"` autorise.
2. **TP02, multi-arch** : les stages `base`/`deps-*`/`test` tournent sur `$BUILDPLATFORM`. Les dépendances sont du JS pur installé avec `--ignore-scripts`, donc indépendantes de l'architecture : un build arm64 n'émule plus `npm ci`, seul le `RUN apk upgrade` du runtime l'est.

Contrôles refaits sur l'image finale ([`logs/after-tp03-fix.log`](logs/after-tp03-fix.log)) :

```text
$ docker image ls shopapi:1.4.2
shopapi:1.4.2   02d56b7cfa7c        152MB
$ docker run --rm shopapi:1.4.2 sh -c "id; which npm npx yarn corepack || echo no package manager; apk info -v | grep -E '^lib(ssl|crypto)3'"
uid=1000(node) gid=1000(node) groups=1000(node)
no package manager
libcrypto3-3.5.9-r0
libssl3-3.5.9-r0
$ docker inspect api --format '{{.State.Health.Status}}'
healthy
$ time docker stop api
real	0m0,163s
$ docker run --rm -i hadolint/hadolint < Dockerfile; echo $?
0
```

---

## Bonus

### B1 — Variante distroless

[`shopapi/Dockerfile.distroless`](shopapi/Dockerfile.distroless) : mêmes stages de build, runtime `gcr.io/distroless/nodejs20-debian12:nonroot` **épinglé par digest**.

```text
$ docker build -f Dockerfile.distroless --build-arg APP_VERSION=1.4.2 --build-arg GIT_SHA=068ba9e -t shopapi:1.4.2-distroless .
$ docker image ls shopapi
shopapi:1.4.2              144MB
shopapi:1.4.2-distroless   130MB

$ docker run -d --name api-dl -p 3001:3000 shopapi:1.4.2-distroless
$ docker inspect api-dl --format '{{.State.Health.Status}}'
healthy
$ docker exec api-dl sh
OCI runtime exec failed: exec failed: unable to start container process: exec: "sh": executable file not found in $PATH
$ docker exec api-dl id
OCI runtime exec failed: exec failed: unable to start container process: exec: "id": executable file not found in $PATH

# Debug : conteneur éphémère qui partage les namespaces PID et réseau
$ docker run --rm --pid container:api-dl --network container:api-dl busybox:1.37 sh -c 'ps; wget -qO- 127.0.0.1:3000/health'
PID   USER     TIME  COMMAND
    1 65532     0:00 /nodejs/bin/node src/server.js
{"status":"ok"}

$ time docker stop api-dl
real	0m0,160s
```

**Healthcheck sans `wget`** : on utilise l'interpréteur déjà présent. Un petit script `/healthcheck.js` (généré dans un stage de build) fait un `fetch()` sur `/health`, et l'image le lance avec `HEALTHCHECK CMD ["/nodejs/bin/node", "/healthcheck.js"]`. Attention : `CMD-SHELL` est impossible puisqu'il n'y a pas de `/bin/sh`, d'où la forme exec obligatoire.

**Compromis** :

| | Alpine | Distroless |
|---|---|---|
| Taille | 144 Mo | 130 Mo (le gain est faible ici : c'est Node qui pèse, pas l'OS) |
| Shell, gestionnaire de paquets | `sh`, `apk` | aucun : une RCE ne peut ni lancer de shell ni installer d'outil |
| CVE de l'OS | busybox, apk, musl | quasi rien en dehors de glibc, libssl et Node |
| Debug | `docker exec -it … sh` | conteneur sidecar (`--pid container:`), `docker debug` (Docker Desktop), tag `:debug` avec busybox, ou `kubectl debug` |
| Healthcheck | `wget` gratuit | script Node : coûte un démarrage de Node (~40 Mo de RAM, ~50 ms) toutes les 15 s |
| Libc | musl (rarissimes incompatibilités avec des modules natifs) | glibc |
| Utilisateur | `node` (1000) | `nonroot` (65532) |

Le choix dépend de la politique sécu. Distroless est très pertinent en prod, mais il demande des procédures de debug outillées.

### B2 — `--no-cache` vs cache mount

Mesures sur le builder `docker-container` `shop` (créé en B3). Sur lui, `prune --filter type=regular` vide le cache de **couches** et laisse les cache mounts en place, ce qui isole proprement l'effet du mount :

```text
# 1) Builder vide (ni couches ni cache mount)
$ docker buildx prune --builder shop -af
$ time docker buildx build --builder shop ... -t shopapi:1.4.2 .
    npm ci : 20.81 added 222 packages in 21s
    total 29.5s
# 2) Couches vidées, cache mount /root/.npm conservé
$ docker buildx prune --builder shop -f --filter type=regular
$ time docker buildx build --builder shop ... -t shopapi:1.4.2 .
    npm ci : 0.646 added 222 packages in 540ms
    total 6.7s
# 3) --no-cache (cache mount plein mais ignoré)
$ time docker buildx build --builder shop ... --no-cache -t shopapi:1.4.2 .
    npm ci : 20.54 added 222 packages in 20s
    total 23.2s
# 4) Couches vidées à nouveau : le mount d'origine est toujours là
$ time docker buildx build --builder shop ... -t shopapi:1.4.2 .
    npm ci : 0.674 added 222 packages in 554ms
    total 9.1s
```

| Scénario | `npm ci` (222 paquets) | Total |
|---|---|---|
| Rien en cache | 21 s | 29,5 s |
| Couches invalidées, **cache mount plein** | **0,54 s** (×39) | 6,7 s |
| `--no-cache` | 20 s | 23,2 s |

- Le **cache de couches** évite d'exécuter l'instruction : tout ou rien, selon la clé de cache.
- Le **cache mount** (`--mount=type=cache`) est un répertoire persistant, géré par BuildKit, monté *pendant* le `RUN` et absent de l'image. Quand la couche doit être rejouée (lockfile modifié, cache de couches purgé, autre branche), `npm ci` retrouve ses tarballs dans `/root/.npm` et ne retélécharge rien.
- **`--no-cache` ignore les deux** : BuildKit monte un cache mount **neuf et vide** (nouvel ID à chaque build, visible dans `docker buildx du --verbose`). L'ancien n'est pas détruit et sert à nouveau au build normal suivant (scénario 4).

> **Correction** : ma première mesure, faite sur le builder par défaut et remplacée depuis dans `logs/b2-cache-mount.log`, semblait montrer qu'un `--no-cache` réutilisait le cache mount (36 s → 1,4 s). Je n'ai pas pu le reproduire. Deux `--no-cache` successifs sur le builder par défaut donnent 26 s puis 28 s ([`logs/b2-recheck.log`](logs/b2-recheck.log)), et le même comportement apparaît au TP02 avec pip. L'écart initial venait très probablement du réseau (premier accès au registre npm). Les mesures ci-dessus, faites sur un builder isolé, sont les bonnes.

### B3 — Build reproductible

Il faut un builder `docker-container` : le driver `docker` sans le containerd image store refuse `-o type=oci` (*« OCI exporter is not supported for the docker driver »*).

```text
$ docker buildx create --name shop --driver docker-container --driver-opt network=host

# Deux builds « naïfs » du même commit
$ docker buildx build --builder shop --no-cache --provenance=false ... -o type=oci,dest=naive-1.tar .
digest naive-1: sha256:9d7368248c6508aae184d15bb75d580a381e499be3d6c0d453e89fc391074605
$ docker buildx build ... -o type=oci,dest=naive-2.tar .
digest naive-2: sha256:54484b3868856f19c16a33659e5c4aac2fa5653618276f48a7d4b5a708e81a7f

# Avec SOURCE_DATE_EPOCH (date du dernier commit) + rewrite-timestamp
$ export SOURCE_DATE_EPOCH=$(git log -1 --format=%ct)
$ docker buildx build --builder shop --no-cache --provenance=false ... -o type=oci,dest=repro-1.tar,rewrite-timestamp=true .
digest repro-1: sha256:8487d66c7c4691c7f413f525397df0fe7723e9d329a38d0a7b11b102bffe8365
$ docker buildx build ... -o type=oci,dest=repro-2.tar,rewrite-timestamp=true .
digest repro-2: sha256:8487d66c7c4691c7f413f525397df0fe7723e9d329a38d0a7b11b102bffe8365   ← identique
```

Ce qui différait entre `naive-1` et `naive-2` (config et manifest extraits des tarballs) :

```text
naive-1  {"created":"2026-10-26T09:59:59.787Z","history":[…"2026-10-26T09:59:59.787Z"…]}  layers: …b7584e935db7 c20dcb8ae983 d60f2c3fe1b8
naive-2  {"created":"2026-10-26T10:00:08.273Z","history":[…"2026-10-26T10:00:08.273Z"…]}  layers: …8dc408d877ed 4da749659f1d 56a0d1db1ec4
```

**Ce qui empêche la reproductibilité** :

1. **Horodatages de la config** (`created`, `history[].created`) : `SOURCE_DATE_EPOCH` les fixe.
2. **mtime des fichiers dans les couches** : chaque fichier créé par `RUN npm ci` ou par `COPY` porte l'heure du build, donc le tar de la couche et son digest changent. `rewrite-timestamp=true` plafonne les mtime à `SOURCE_DATE_EPOCH`.
3. **Attestation de provenance** (activée par défaut avec buildx) : elle contient l'heure de début et de fin du build et l'ID d'invocation. Il faut la désactiver (`--provenance=false`) ou accepter que l'*index* diffère tant que le *manifest de l'image* reste identique.
4. **Entrées non figées** : tag de base mutable (d'où l'intérêt de `@sha256:`), `npm install` sans lockfile, `apt-get install` sans version, `curl | bash`, fichiers générés contenant la date ou un aléa. Ici, le lockfile et le tag de base épinglé règlent ce point.
5. Autres sources classiques : ordre non déterministe des fichiers, UID/GID différents, champs dépendants de l'hôte (hostname), caches (`.pyc`) avec horodatage.

Intérêt : n'importe qui peut reconstruire l'image depuis le commit et **vérifier** que le digest signé (TP03) correspond bien au code source, ce qui détecte une CI compromise.
