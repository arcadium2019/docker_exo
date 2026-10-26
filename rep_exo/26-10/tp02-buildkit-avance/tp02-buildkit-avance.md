# TP02 — BuildKit avancé : cache, secrets, multi-architecture, bake

`shop-worker` (Python) repris de `02_exercices_sujet/26-10/tp02-buildkit-avance/starter/shop-worker/`. **Le code (`worker/`, `tests/`, `requirements*.txt`) n'est pas modifié.**

| Fichier | Rôle |
|---|---|
| [`RAPPORT.md`](RAPPORT.md) | **Livrable** : mesures des étapes 3 et 4 (et 5, bonus) + réponses aux questions |
| [`shop-worker/Dockerfile`](shop-worker/Dockerfile) | **Dockerfile final** : `builder → test → users → runtime`, secret mount, cache par arch, multi-arch par compilation croisée |
| [`docker-bake.hcl`](docker-bake.hcl) | **Livrable** : api (TP01) + worker, `_common`, `worker-test` |
| [`shop-worker/.dockerignore`](shop-worker/.dockerignore), [`shop-worker/.gitignore`](shop-worker/.gitignore) | `pip.conf*` hors du contexte et hors de git |
| `shop-worker/pip.conf` | config pip locale (gitignorée), pointe vers `https://pypi.org/simple` pour la formation |
| [`shop-worker/Dockerfile.leak`](shop-worker/Dockerfile.leak) | Dockerfile d'origine, pour l'étape 1 |
| [`shop-worker/Dockerfile.emulated`](shop-worker/Dockerfile.emulated) | variante « tous les `RUN` sur la cible », pour mesurer QEMU |
| [`shop-worker/Dockerfile.uv`](shop-worker/Dockerfile.uv) | bonus B1 (offline) et B3 (uv) |
| [`buildkitd.toml`](buildkitd.toml) | config du builder `shop` : CA du registre TP03, HTTPS forcé sur `localhost:5000` |
| [`fake-internal-pypi/`](fake-internal-pypi/) | PyPI interne authentifié simulé (`pypiserver` + htpasswd), pour l'étape 1 |
| [`e2e-compose.yml`](e2e-compose.yml) | test de bout en bout API → Redis → worker |
| [`logs/`](logs/) | sorties brutes |

Le registre utilisé (`localhost:5000`, TLS + auth) est celui du [TP03](../tp03-registry-supply-chain/tp03-registry-supply-chain.md).

---

## 1. Prouver la fuite

```text
$ docker build --build-arg PIP_INDEX_URL=https://svc-ci:Tr3sS3cret@pypi.internal.example.com/simple -t worker:leak . || true
#8 0.918 Looking in indexes: https://svc-ci:****@pypi.internal.example.com/simple
#8 1.131 WARNING: Retrying (...) Failed to establish a new connection: [Errno -5] No address associated with hostname: /simple/redis/
...
```

Le build échoue, comme prévu. Pour obtenir une image et **montrer** la fuite au lieu de la supposer, je simule le PyPI interne authentifié en local, sans rien envoyer à un service externe :

```bash
./fake-internal-pypi/setup.sh        # pypiserver sur 127.0.0.1:8090, htpasswd svc-ci:Tr3sS3cret, wheels téléchargées une fois
curl -s -o /dev/null -w '%{http_code}' localhost:8090/simple/     # 401
```

```text
$ docker build --network host --build-arg PIP_INDEX_URL=http://svc-ci:Tr3sS3cret@localhost:8090/simple -f Dockerfile.leak -t worker:leak .
#8 0.816 Looking in indexes: http://svc-ci:****@localhost:8090/simple
#8 1.389 Successfully installed iniconfig-2.3.1 packaging-26.3 pluggy-1.7.0 prometheus-client-0.20.0 psycopg2-binary-2.9.9 pytest-8.3.2 redis-5.0.8 ruff-0.6.3
```

(pip considère `localhost` comme une origine sûre et accepte donc le HTTP sans `--trusted-host`. Le Dockerfile n'a pas été modifié.)

```text
# 1) docker history
$ docker history --no-trunc worker:leak | grep -i secret
(rien : « S3cret » s'écrit avec un 3, grep -i secret ne le trouve pas)
$ docker history --no-trunc worker:leak | grep -i -E 'Tr3sS3cret|password'
RUN |1 PIP_INDEX_URL=http://svc-ci:Tr3sS3cret@localhost:8090/simple /bin/sh -c pip install -r requirements-dev.txt # buildkit
ARG PIP_INDEX_URL=http://svc-ci:Tr3sS3cret@localhost:8090/simple

# 2) docker inspect / config de l'image (= blob config dans le registre)
$ docker image inspect worker:leak | grep -n -i -E 'Tr3sS3cret|password'
(rien : ni Env ni Labels, l'ARG n'est pas dans .Config)
$ docker save worker:leak | tar -xO blobs/sha256/09837d9a6c27… | jq '.history[] | select(.created_by|test("Tr3s"))'
"ARG PIP_INDEX_URL=http://svc-ci:Tr3sS3cret@localhost:8090/simple"
"RUN |1 PIP_INDEX_URL=http://svc-ci:Tr3sS3cret@localhost:8090/simple /bin/sh -c pip install -r requirements-dev.txt # buildkit"

# 3) les couches
couche blobs/sha256/c28c0404d03e43785… (11 fichiers) : /app/pip.conf.example
$ docker run --rm worker:leak cat /app/pip.conf.example
index-url = https://svc-ci:Tr3sS3cret@pypi.internal.example.com/simple

# 4) l'historique des builds BuildKit, y compris le build en ÉCHEC
$ docker buildx history ls
BUILD ID                    NAME                                   STATUS      CREATED AT
p64nva4djc7rxr1o2693exlvk   ..0/tp02-buildkit-avance/shop-worker   Completed   22 seconds ago
i5yp1anav00qb60onkz56o1up   ..0/tp02-buildkit-avance/shop-worker   Error       32 seconds ago
$ docker buildx history inspect i5yp1anav00qb60onkz56o1up
BUILD ARG       VALUE
PIP_INDEX_URL   https://svc-ci:Tr3sS3cret@pypi.internal.example.com/simple
```

Synthèse des **6 endroits** (dont la provenance `mode=max` du bonus B2) dans le [RAPPORT](RAPPORT.md#étape-1--où-le-secret-passé-en-arg-est-il-visible-).

## 2. Secret mount

### Le Dockerfile final

La version présentée est la version finale, adaptée à l'étape 4 pour le multi-arch sans émulation. La version de l'étape 2 avait les mêmes stages, avec tous les `RUN` sur la plateforme cible : c'est [`Dockerfile.emulated`](shop-worker/Dockerfile.emulated).

```dockerfile
# syntax=docker/dockerfile:1.7
# shop-worker - multi-stage, secret mount for the private index, per-arch pip cache, multi-arch
# without emulation: every RUN executes on the build platform, the target image only receives COPYs.
ARG PYTHON_IMAGE=python:3.12.15-slim-trixie

# ---- build-base: native image of the machine running the build (BUILDPLATFORM)
FROM --platform=$BUILDPLATFORM ${PYTHON_IMAGE} AS build-base
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1
WORKDIR /app

# ---- builder: runtime dependencies for the TARGET architecture, in a relocatable virtualenv
FROM build-base AS builder
# Set automatically by BuildKit for each target platform (amd64, arm64...).
ARG TARGETARCH
# The venv only holds symlinks to /usr/local/bin/python3.12, identical in every python image.
RUN python -m venv --without-pip /opt/venv
COPY requirements.txt .
# pip.conf (index URL + credentials) only exists for the duration of this RUN: never in a layer.
# The pip cache is isolated per target architecture (one lock per arch, no wheel mix-up).
# --platform/--only-binary: download prebuilt wheels for the target instead of executing it (no QEMU).
RUN --mount=type=secret,id=pipconf,target=/etc/pip.conf \
    --mount=type=cache,id=pip-${TARGETARCH},target=/root/.cache/pip,sharing=locked \
    case "${TARGETARCH}" in \
      amd64) arch=x86_64 ;; \
      arm64) arch=aarch64 ;; \
      *) echo "unsupported TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; \
    esac \
    && pip install --target /opt/venv/lib/python3.12/site-packages \
         --implementation cp --python-version 3.12 --abi cp312 --only-binary=:all: \
         --platform "manylinux_2_17_${arch}" --platform "manylinux2014_${arch}" --platform "manylinux_2_28_${arch}" \
         -r requirements.txt

# ---- test: lint + unit tests, natively on the build platform
FROM build-base AS test
ARG BUILDARCH
COPY requirements.txt requirements-dev.txt ./
RUN --mount=type=secret,id=pipconf,target=/etc/pip.conf \
    --mount=type=cache,id=pip-${BUILDARCH},target=/root/.cache/pip,sharing=locked \
    pip install -r requirements-dev.txt
COPY worker ./worker
COPY tests ./tests
# "python -m pytest" puts the cwd on sys.path so tests can import the worker package.
RUN ruff check --no-cache worker tests && python -m pytest -q -p no:cacheprovider && touch /tmp/.tests-passed

# ---- users: /etc/passwd + /etc/group with the worker account, prepared natively
# The bind mount on the test stage makes every runtime build depend on passing tests.
FROM build-base AS users
RUN --mount=type=bind,from=test,source=/tmp/.tests-passed,target=/tmp/.tests-passed \
    groupadd --system --gid 10001 worker \
    && useradd --system --uid 10001 --gid worker --no-create-home --shell /usr/sbin/nologin worker

# ---- runtime: TARGET platform, no RUN at all
FROM ${PYTHON_IMAGE} AS runtime
ARG VERSION=0.0.0-dev
ARG GIT_SHA=unknown
ARG SOURCE_URL=https://git.shop-sas.example/platform/shop-worker
LABEL org.opencontainers.image.title="shop-worker" \
      org.opencontainers.image.description="Shop SAS order queue consumer" \
      org.opencontainers.image.vendor="Shop SAS" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${GIT_SHA}" \
      org.opencontainers.image.source="${SOURCE_URL}"
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PATH=/opt/venv/bin:$PATH
WORKDIR /app
COPY --from=users /etc/passwd /etc/group /etc/
COPY --from=builder /opt/venv /opt/venv
COPY worker ./worker
USER 10001:10001
EXPOSE 9100
HEALTHCHECK --interval=15s --timeout=3s --start-period=10s --start-interval=1s --retries=3 \
    CMD ["python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:9100/metrics', timeout=2)"]
CMD ["python", "-m", "worker.main"]
```

```text
$ cat shop-worker/pip.conf                # gitignoré, jamais dans le contexte (.dockerignore en allowlist)
[global]
index-url = https://pypi.org/simple
$ docker run --rm -i hadolint/hadolint < Dockerfile ; echo $?
0
```

Points notables :

- **Image de base** `python:3.12.15-slim-trixie` (version figée) au lieu de `python:3.12`, avec un **venv** copié seul dans le runtime : pas de pip ni de dépendances de dev en prod. **1,16 Go → 130 Mo.**
- **Tests obligatoires** : même technique qu'au TP01. Le `RUN --mount=type=bind,from=test` du stage `users` rend tout build du runtime dépendant de la réussite des tests.
- Pour lancer les tests, il faut **`python -m pytest`**. Avec `pytest` seul, la collecte échouait (`ERROR collecting tests/test_process.py`) : pytest n'ajoute que `tests/` au `sys.path`, donc `import worker` ne passe pas. `python -m` ajoute aussi le répertoire courant, sans toucher au code.
- **Non-root** (`10001:10001`, avec un compte nommé), healthcheck sur `/metrics`, `CMD` en forme exec : le worker gère SIGTERM.

### Vérifications

```text
$ docker build --secret id=pipconf,src=pip.conf --build-arg VERSION=1.0 --build-arg GIT_SHA=068ba9e -t worker:1.0 .
#19 [test 5/5] RUN ruff check --no-cache worker tests && python -m pytest -q -p no:cacheprovider && touch /tmp/.tests-passed
#21 naming to docker.io/library/worker:1.0 done

$ docker history --no-trunc worker:1.0 | grep -i -E "Tr3s|pypi|pip.conf|secret|index"
(rien)
$ docker run --rm worker:1.0 cat /etc/pip.conf
cat: /etc/pip.conf: No such file or directory
$ docker run --rm worker:1.0 ls -la /app
drwxr-xr-x. 1 root root 36 Oct 26 09:50 worker
$ docker run --rm worker:1.0 sh -c "id; python -m pip list | grep -iE 'pytest|ruff' || echo no dev deps"
uid=10001(worker) gid=10001(worker) groups=10001(worker)
no dev deps

# Recherche exhaustive dans la config et toutes les couches
$ grep -r -a -l -E "index-url *= *https://pypi.org" <rootfs de toutes les couches + blobs JSON>
(aucun résultat = aucune trace)

$ docker image ls worker
worker:1.0      130MB
worker:leak     1.16GB
```

**Test de bout en bout** ([`e2e-compose.yml`](e2e-compose.yml)) : l'API du TP01 pousse les commandes dans Redis, le worker les consomme.

```text
$ docker compose -f e2e-compose.yml up -d
api Up 8 seconds (healthy)   redis Up 13 seconds (healthy)   worker Up 8 seconds (healthy)
$ curl -X POST localhost:3003/orders -d '{"productId":1,"quantity":2}'    puis    quantity 500
$ docker compose logs worker
{"ts":"2026-10-26 10:31:43,042","level":"INFO","msg":"commande 1793010703042 -> confirmed"}
{"ts":"2026-10-26 10:31:43,048","level":"INFO","msg":"commande 1793010703048 -> rejected"}
orders_processed_total{status="confirmed"} 1.0
orders_processed_total{status="rejected"} 1.0
$ time docker compose stop worker
real	0m0,918s
{"msg":"signal 15 reçu, arrêt en cours"}  {"msg":"worker arrêté proprement"}
```

Alternatives au secret fichier (`ssh`, secret en variable d'environnement) : voir le [RAPPORT](RAPPORT.md#étape-2--secret-mount--vérifications-et-alternatives).

## 3. Cache mount

Le cache mount est en place depuis l'étape 2 : `--mount=type=cache,id=pip-${TARGETARCH},target=/root/.cache/pip,sharing=locked`.

```text
$ docker buildx prune --builder shop -f --filter type=regular      # vide le cache de couches, PAS le cache mount
$ echo "requests==2.32.3" >> requirements.txt
$ time docker buildx build --builder shop --secret id=pipconf,src=pip.conf -t worker:1.0 .
    total 5.4s | wheels téléchargées 5 | servies par le cache mount 32
```

Mesures complètes, explication couches/mount, comportement de `--no-cache`, et **deux corrections de l'énoncé** (`docker builder prune -f` vide aussi les cache mounts ; `--no-cache` ignore les cache mounts) : voir le [RAPPORT](RAPPORT.md#étape-3--cache-de-couches-vs-cache-mount). `requirements.txt` a ensuite été restauré.

## 4. Multi-architecture

```text
$ docker buildx create --name shop --driver docker-container --driver-opt network=host --buildkitd-config buildkitd.toml
$ docker buildx inspect shop --bootstrap
Driver:                docker-container
BuildKit version:      v0.33.1
Platforms:             linux/amd64, linux/amd64/v2, linux/amd64/v3, linux/386
```

`--driver-opt network=host` permet au builder de joindre le registre du TP03 sur `localhost:5000`. Il n'y a pas de `--use` : je ne voulais pas changer le builder par défaut du poste, d'où les `--builder shop` explicites ou `BUILDX_BUILDER=shop`.

[`buildkitd.toml`](buildkitd.toml) est nécessaire. BuildKit traite `localhost` comme un registre **HTTP** en clair : le premier push a échoué avec `unexpected status from HEAD request to http://localhost:5000/…: 400`, du HTTP envoyé sur le port TLS. Il faut aussi faire confiance à la CA interne :

```toml
[registry."localhost:5000"]
  http = false
  insecure = false
  ca = ["../tp03-registry-supply-chain/registry/trust/ca.crt"]
```

```text
$ docker buildx build --builder shop --platform linux/amd64,linux/arm64 --secret id=pipconf,src=pip.conf \
    --build-arg VERSION=1.0 --build-arg GIT_SHA=068ba9e -t localhost:5000/shop-worker:1.0 --push .
#32 pushing manifest for localhost:5000/shop-worker:1.0@sha256:96829ea8972d88835a382f35378be5cc3a4b40d93143a375760c9f96741e1ea9 0.4s done
real 17.1s

$ docker buildx imagetools inspect localhost:5000/shop-worker:1.0
ERROR: … tls: failed to verify certificate: x509: certificate signed by unknown authority
$ SSL_CERT_FILE=../tp03-registry-supply-chain/registry/trust/ca.crt docker buildx imagetools inspect --builder shop localhost:5000/shop-worker:1.0
Name:      localhost:5000/shop-worker:1.0
MediaType: application/vnd.oci.image.index.v1+json
Digest:    sha256:96829ea8972d88835a382f35378be5cc3a4b40d93143a375760c9f96741e1ea9
Manifests:
  Name:        localhost:5000/shop-worker:1.0@sha256:c3ddea4b195fbcd4ffb5a36c5c6693df6b36c347e45cb4f2b9ec49f0a2a4c4d5
  Platform:    linux/amd64
  Name:        localhost:5000/shop-worker:1.0@sha256:4beb4ac778d00cc7597e4ba0f3af736bafada0177523580e24b6c96f52bb50db
  Platform:    linux/arm64
  Name:        …@sha256:fb7b1317…   Platform: unknown/unknown   vnd.docker.reference.type: attestation-manifest
  Name:        …@sha256:b1af16da…   Platform: unknown/unknown   vnd.docker.reference.type: attestation-manifest
```

`imagetools` s'exécute **côté client**, pas dans BuildKit : il lui faut la CA (`SSL_CERT_FILE`) et le builder `shop` pour reprendre la règle « HTTPS sur localhost ».

Quelles étapes tournent où ? Les deux `builder` (cibles amd64 **et** arm64) tournent en `linux/amd64` :

```text
[linux/amd64 builder 3/3] RUN …            ← exécuté 2 fois (TARGETARCH=amd64 puis arm64), en natif
[linux/amd64 test 5/5] RUN …               ← tests natifs
[linux/amd64 users 1/1] RUN …
[linux/arm64 runtime 3/5] COPY             ← la cible arm64 ne reçoit que des COPY
[linux/arm64 runtime 4/5] COPY
[linux/arm64 runtime 5/5] COPY
```

Vérification des binaires (en-tête ELF `e_machine`) et comparaison chiffrée **QEMU contre compilation croisée** (67,9 s contre 11,0 s pour arm64) : voir le [RAPPORT](RAPPORT.md#étape-4--multi-architecture).

## 5. Cache distant

```text
$ docker buildx build --builder shop --platform linux/amd64,linux/arm64 --secret id=pipconf,src=pip.conf … \
    --cache-to type=registry,ref=localhost:5000/cache:worker-max,mode=max \
    --cache-from type=registry,ref=localhost:5000/cache:worker-max --push .
$ docker buildx prune --builder shop -af                 # autre runner CI, vierge
$ time docker buildx build … --cache-from type=registry,ref=localhost:5000/cache:worker-max --push .
  total 4.7s | étapes CACHED 20 | pip install exécutés 0 | tests exécutés 0           (13,4 s sans cache distant)
```

`mode=min` contre `mode=max` (avec un changement de code), variantes `gha` et `s3` : voir le [RAPPORT](RAPPORT.md#étape-5--cache-distant).

## 6. `docker buildx bake`

[`docker-bake.hcl`](docker-bake.hcl) :

```hcl
variable "REGISTRY"  { default = "localhost:5000" }
variable "VERSION"   { default = "0.0.0-dev" }
variable "GIT_SHA"   { default = "unknown" }
variable "PLATFORMS" { default = "linux/amd64,linux/arm64" }

function "image"      { params = [name]  result = ["${REGISTRY}/${name}:${VERSION}", "${REGISTRY}/${name}:sha-${GIT_SHA}"] }
function "cache_from" { params = [name]  result = ["type=registry,ref=${REGISTRY}/cache:${name}"] }
function "cache_to"   { params = [name]  result = ["type=registry,ref=${REGISTRY}/cache:${name},mode=max"] }

group "default" { targets = ["api", "worker"] }

target "_common" {                       # abstraite : préfixe _, dans aucun groupe
  platforms = split(",", PLATFORMS)
  labels = { "org.opencontainers.image.version" = VERSION, "org.opencontainers.image.revision" = GIT_SHA, … }
}
target "api"    { inherits = ["_common"]  context = "../tp01-optimisation-image/shopapi"  args = { APP_VERSION = VERSION, GIT_SHA = GIT_SHA }
                  tags = image("shopapi")  cache-from = cache_from("shopapi")  cache-to = cache_to("shopapi") }
target "worker" { inherits = ["_common"]  context = "shop-worker"  args = { VERSION = VERSION, GIT_SHA = GIT_SHA }
                  secret = ["id=pipconf,src=shop-worker/pip.conf"]
                  tags = image("shop-worker")  cache-from = cache_from("shop-worker")  cache-to = cache_to("shop-worker") }
target "worker-test" { inherits = ["worker"]  target = "test"  platforms = ["linux/amd64"]  tags = []  cache-to = []  output = ["type=cacheonly"] }
```

(Extrait condensé, le fichier complet est commenté.) Des **fonctions** HCL évitent de répéter le schéma des tags et du cache par cible. Le cache ne peut pas aller dans `_common`, puisqu'il dépend du nom de la cible.

```text
$ export BUILDX_BUILDER=shop
$ docker buildx bake --print                         # extrait
  "worker": {
    "context": "shop-worker",
    "args": { "GIT_SHA": "unknown", "VERSION": "0.0.0-dev" },
    "labels": { "org.opencontainers.image.revision": "unknown", "org.opencontainers.image.vendor": "Shop SAS", "org.opencontainers.image.version": "0.0.0-dev" },
    "tags": [ "localhost:5000/shop-worker:0.0.0-dev", "localhost:5000/shop-worker:sha-unknown" ],
    "cache-from": [ { "ref": "localhost:5000/cache:shop-worker", "type": "registry" } ],
    "cache-to":   [ { "mode": "max", "ref": "localhost:5000/cache:shop-worker", "type": "registry" } ],
    "secret": [ { "id": "pipconf", "src": "shop-worker/pip.conf" } ],
    "platforms": [ "linux/amd64", "linux/arm64" ]
  }

$ VERSION=1.0 GIT_SHA=$(git rev-parse --short HEAD) docker buildx bake worker-test
#18 0.079 All checks passed!
#18 0.452 2 passed in 0.06s
exit=0

# Avec un test cassé (seuil 100 → 1000 temporairement dans worker/main.py, restauré ensuite)
$ docker buildx bake worker-test
#16 0.422 E       AssertionError: assert 'confirmed' == 'rejected'
#16 0.422 FAILED tests/test_process.py::test_rejects_large_orders - AssertionError: ass...
exit=1

$ VERSION=1.0 docker buildx bake --set '*.platform=linux/amd64' --load
#28 importing to docker
#47 importing to docker
real 12.1s
$ docker image ls --filter reference="localhost:5000/*:1.0"
localhost:5000/shop-worker:1.0   130MB
localhost:5000/shopapi:1.0       152MB

$ VERSION=1.0 GIT_SHA=068ba9e docker buildx bake --push          # amd64 + arm64
#53 pushing manifest for localhost:5000/shop-worker:1.0@sha256:8b9153a2… done
#53 pushing manifest for localhost:5000/shop-worker:sha-068ba9e@sha256:8b9153a2… done
#60 pushing manifest for localhost:5000/shopapi:1.0@sha256:8924ef7d… done
#60 pushing manifest for localhost:5000/shopapi:sha-068ba9e@sha256:8924ef7d… done
```

Au premier lancement, `failed to configure registry cache importer: localhost:5000/cache:shop-worker: not found` s'affiche : ce n'est qu'un avertissement, le cache n'existe pas encore. Le stage runtime de l'API contient un `RUN apk upgrade` (ajouté au TP03). Son arm64 passe donc par l'émulateur intégré à BuildKit. Les stages de dépendances de l'API ont été passés en `FROM --platform=$BUILDPLATFORM` (npm ci de dépendances JS pures, `--ignore-scripts`) pour qu'aucun `npm ci` ne soit émulé.

> Limite assumée : `VERSION` est commune aux deux cibles. Dans la vraie vie, l'API et le worker ont des cycles de version distincts (`API_VERSION`, `WORKER_VERSION`, ou un fichier bake par composant).

---

## Bonus

B1 (`--network=none`), B2 (provenance et SBOM) et B3 (uv) : voir le [RAPPORT](RAPPORT.md#bonus).

## Nettoyage

```bash
docker compose -f fake-internal-pypi/compose.yml down
docker buildx rm shop                      # builder et son cache
docker image rm worker:leak worker:1.0 worker:1.0-uv
```
