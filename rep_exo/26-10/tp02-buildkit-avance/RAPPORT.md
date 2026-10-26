# TP02 — Rapport : mesures et réponses aux questions

Toutes les mesures ont été faites sur un poste Fedora **amd64**, Docker 29.9.2, avec le builder `docker-container` `shop` (BuildKit v0.33.1, `--driver-opt network=host`, CA du registre TP03 dans [`buildkitd.toml`](buildkitd.toml)). Les commandes et sorties complètes sont dans [`logs/`](logs/). Le déroulé pas à pas est dans [`tp02-buildkit-avance.md`](tp02-buildkit-avance.md).

---

## Étape 1 — Où le secret passé en `ARG` est-il visible ?

Le build de l'énoncé échoue (le registre interne n'existe pas). Pour le prouver sur une image **réellement construite**, j'ai simulé le PyPI interne authentifié avec un `pypiserver` local protégé par htpasswd ([`fake-internal-pypi/`](fake-internal-pypi/)). Le Dockerfile est inchangé ([`shop-worker/Dockerfile.leak`](shop-worker/Dockerfile.leak)) et seul `PIP_INDEX_URL` diffère : `http://svc-ci:Tr3sS3cret@localhost:8090/simple`.

> ⚠️ La commande de l'énoncé, `docker history --no-trunc worker:leak | grep -i secret`, **ne trouve rien** : le mot de passe s'écrit `Tr3sS3cret`, avec un **3**. C'est une bonne leçon : on ne détecte pas un secret en cherchant le mot « secret ».

| # | Où | Preuve | Qui y a accès |
|---|---|---|---|
| 1 | **`docker history`** | `RUN \|1 PIP_INDEX_URL=http://svc-ci:Tr3sS3cret@localhost:8090/simple /bin/sh -c pip install …` et `ARG PIP_INDEX_URL=http://svc-ci:Tr3sS3cret@…` | quiconque a l'image |
| 2 | **Config de l'image** (blob JSON `history[].created_by`, celui que stocke le registre) | `docker save worker:leak \| tar -xO blobs/sha256/09837d9a… \| jq '.history[]…'` montre les deux lignes ci-dessus. `docker image inspect` ne l'affiche pas : un ARG n'est pas dans `.Config.Env`. | quiconque peut faire un `pull` (ou `crane config`) |
| 3 | **Une couche** | `COPY . .` embarque `pip.conf.example` (`index-url = https://svc-ci:Tr3sS3cret@pypi.internal…`) et le Dockerfile lui-même (`ARG PIP_INDEX_URL=https://user:password@…`) | quiconque a l'image, même si un `RUN rm` ultérieur supprimait le fichier : il resterait dans la couche précédente |
| 4 | **Historique des builds BuildKit** (`docker buildx history inspect`) | `BUILD ARG PIP_INDEX_URL https://svc-ci:Tr3sS3cret@pypi.internal.example.com/simple`, **y compris pour le build en échec** | qui a accès au daemon ou au builder, et les exports de build (Docker Desktop, artefacts CI) |
| 5 | **Attestation de provenance** `mode=max` (bonus B2) | `imagetools inspect … --format '{{json .Provenance}}'` → `svc-ci:Tr3sS3cret@`. Le build-arg est enregistré **même si le Dockerfile ne déclare pas l'ARG**. | publié **dans le registre** avec l'image |
| 6 | Logs CI | la ligne de commande `docker build --build-arg …`. pip masque le mot de passe dans sa propre sortie (`svc-ci:****@`), mais pas la CI. | qui lit les logs du pipeline |

L'image fait aussi **1,16 Go** (`python:3.12` complète + pytest et ruff en prod).

**Conséquence** : un identifiant passé par `ARG` est à considérer comme **publié**. Il faut le révoquer, le supprimer du Dockerfile ne suffit pas.

## Étape 2 — Secret mount : vérifications et alternatives

```dockerfile
RUN --mount=type=secret,id=pipconf,target=/etc/pip.conf \
    --mount=type=cache,id=pip-${TARGETARCH},target=/root/.cache/pip,sharing=locked \
    pip install …
```

```text
$ docker build --secret id=pipconf,src=pip.conf -t worker:1.0 .
$ docker history --no-trunc worker:1.0 | grep -i -E "Tr3s|pypi|pip.conf|secret|index"
(rien)
$ docker run --rm worker:1.0 cat /etc/pip.conf
cat: /etc/pip.conf: No such file or directory
$ grep -r -a -l "index-url = https://pypi.org" <rootfs de toutes les couches + blobs JSON>
(aucun résultat)
```

Le secret est monté sur un **tmpfs**, uniquement pendant le `RUN`. Il n'entre ni dans la couche, ni dans l'historique, ni dans la **clé de cache** : une rotation d'identifiant ne force donc pas de rebuild. `pip.conf` est dans `.gitignore`, et le `.dockerignore` est une allowlist, donc ni `pip.conf` ni `pip.conf.example` n'entrent dans le contexte.

**Alternatives** :

- **`--mount=type=ssh`** pour les dépendances dans des dépôts git privés (`pip install git+ssh://git@git.shop-sas.example/platform/libshop.git`). Le build utilise l'agent SSH de l'hôte, `docker build --ssh default .`, et `RUN --mount=type=ssh pip install …`. La clé privée ne quitte jamais l'agent : le conteneur ne voit qu'un socket. Il faut aussi `known_hosts` (`ssh-keyscan` dans un `RUN` ou un fichier copié) pour ne pas désactiver la vérification de l'hôte.
- **Secret exposé en variable d'environnement** (Dockerfile ≥ 1.10) : `docker build --secret id=TOKEN,env=TOKEN` côté client, `RUN --mount=type=secret,id=TOKEN,env=TOKEN …` côté Dockerfile. La variable n'existe que pour ce `RUN`, ce qui est pratique pour les outils qui lisent un token d'env plutôt qu'un fichier. **Utilisé dans [`Dockerfile.uv`](shop-worker/Dockerfile.uv)** : `--mount=type=secret,id=index_url,env=UV_DEFAULT_INDEX`, uv ne lisant pas `pip.conf`.
- Côté CI : le secret vient du coffre (GitHub Actions `secrets:` → `docker/build-push-action` `secrets: |`, GitLab variable masquée, Vault) et n'est **jamais** écrit dans une commande en clair.
- **Ce qu'il ne faut pas faire** : `ARG` ou `ENV` ; `COPY pip.conf` puis `RUN rm` (le fichier reste dans la couche du `COPY`) ; un multi-stage « on copie le secret dans le stage builder seulement ». C'est mieux, mais il reste dans le cache de build, et dans le cache distant en `mode=max`.

## Étape 3 — Cache de couches vs cache mount

Builder `shop`, Dockerfile final, amd64 ([`logs/06-cache-mount.log`](logs/06-cache-mount.log)) :

| Scénario | Total | Wheels téléchargées | Wheels servies par le cache mount |
|---|---|---|---|
| A. À froid (builder vidé) | 7,1 s | 8 | 6 (réutilisées *dans* le même build, entre `builder` et `test`) |
| B. Rebuild sans changement | **0,9 s** | 0 | 0 (aucun `RUN` exécuté : tout vient du cache de couches) |
| C. Cache de **couches** vidé, cache mount conservé, + `requests==2.32.3` | 5,4 s | **5** (requests et ses 4 dépendances) | **32** |
| D. Même scénario, cache mount vidé aussi | 10,2 s | 13 | 16 |
| E. `--no-cache`, cache mount plein | 6,1 s | **13** | 16 |

Avec seulement 8 paquets, les écarts absolus sont faibles. L'effet est bien plus visible au TP01 (npm, 222 paquets : `npm ci` en **21 s** sans mount contre **0,54 s** avec, voir [B2 du TP01](../tp01-optimisation-image/tp01-optimisation-image.md#b2----no-cache-vs-cache-mount)).

**Différence** :

- **Cache de couches** : BuildKit associe à chaque instruction une *clé* (instruction + clé du parent + checksum des fichiers copiés + valeurs des ARG utilisés). Si la clé existe, l'instruction **n'est pas exécutée** et la couche est réutilisée telle quelle. C'est du tout ou rien : modifier `requirements.txt` change la clé du `COPY`, donc tout ce qui suit est rejoué, y compris `pip install`.
- **Cache mount** : un répertoire persistant géré par BuildKit, monté pendant l'exécution d'un `RUN` qui, lui, **est rejoué**. Il ne fait pas partie de l'image. Il accélère l'exécution elle-même : pip y retrouve ses wheels et ne retélécharge que le delta (scénario C : 5 téléchargements au lieu de 13).

**Que se passe-t-il avec `--no-cache` ?** Toutes les instructions sont rejouées, **et les cache mounts sont ignorés** : BuildKit monte un mount **neuf et vide** (nouvel ID à chaque build, visible dans `docker buildx du --verbose`). Le scénario E retélécharge donc tout (13), comme D. L'ancien mount n'est pas détruit et resservira au build normal suivant.

> **Deux corrections par rapport à l'énoncé**, vérifiées ([`logs/05-prune-check.log`](logs/05-prune-check.log), [`logs/07-no-cache-vs-mount.log`](logs/07-no-cache-vs-mount.log)) :
> 1. `docker builder prune -f` **vide aussi les cache mounts**, contrairement au commentaire de l'énoncé : avant, il y avait 2 `exec.cachemount` (pip et npm) ; après, aucun. Pour ne vider que le cache de couches, il faut `docker buildx prune --filter type=regular`, qui fonctionne sur un builder `docker-container`. Sur le driver `docker`, les couches référencées par des images ne sont de toute façon pas « prunables ».
> 2. `--no-cache` n'épargne **pas** les cache mounts (voir ci-dessus).
>
> ⚠️ Lancé sur le builder par défaut, `docker builder prune -f` a vidé **tout** le cache de build du poste (51 Go, tous projets confondus). Toutes les mesures suivantes ont été faites sur le builder isolé `shop`.

## Étape 4 — Multi-architecture

**Choix d'implémentation** : je n'ai pas pu installer QEMU sur l'hôte (`tonistiigi/binfmt`, conteneur `--privileged`, refusé). Le [Dockerfile final](shop-worker/Dockerfile) utilise donc la **compilation croisée**. Tous les `RUN` s'exécutent sur `$BUILDPLATFORM`, et pip télécharge les wheels **de l'architecture cible** :

```dockerfile
FROM --platform=$BUILDPLATFORM ${PYTHON_IMAGE} AS build-base
...
pip install --target /opt/venv/lib/python3.12/site-packages \
     --implementation cp --python-version 3.12 --abi cp312 --only-binary=:all: \
     --platform "manylinux_2_17_${arch}" --platform "manylinux2014_${arch}" --platform "manylinux_2_28_${arch}" -r requirements.txt
```

Le stage `runtime` ne contient **aucun `RUN`**, seulement des `COPY`. Il n'y a donc rien à émuler. Vérification sur l'image poussée ([`logs/10-imagetools.log`](logs/10-imagetools.log)) :

```text
linux/amd64 : _psycopg.cpython-312-x86_64-linux-gnu.so  e_machine=0x3e | python3.12 e_machine=0x3e | {"architecture":"amd64","user":"10001:10001"}
linux/arm64 : _psycopg.cpython-312-aarch64-linux-gnu.so e_machine=0xb7 | python3.12 e_machine=0xb7 | {"architecture":"arm64","user":"10001:10001"}
```

(`0x3e` = x86-64, `0xb7` = AArch64.) En cherchant pourquoi l'API, elle, passait en arm64, j'ai découvert que **l'image `moby/buildkit` embarque ses propres émulateurs** (`buildkit-qemu-aarch64`…). Elle les utilise automatiquement pour un `RUN` non natif quand binfmt n'est pas configuré sur l'hôte. `docker buildx inspect` ne liste pourtant que `linux/amd64, linux/386`, car il n'affiche que les plateformes binfmt. Cela m'a permis de **mesurer** l'émulation, avec [`Dockerfile.emulated`](shop-worker/Dockerfile.emulated) : mêmes stages, tous les `RUN` sur la plateforme cible.

### Mesures ([`logs/17-qemu-vs-cross.log`](logs/17-qemu-vs-cross.log), [`logs/11-multiarch-timing.log`](logs/11-multiarch-timing.log))

Builds à froid, sortie `cacheonly` :

| Dockerfile | Plateforme | Total | `pip install` (×3) | ruff + pytest |
|---|---|---|---|---|
| `Dockerfile.emulated` | linux/amd64 (natif) | 12,2 s | 3,3 s | 0,5 s |
| `Dockerfile.emulated` | **linux/arm64 (QEMU)** | **67,9 s** | **27,9 s** | **6,2 s** |
| `Dockerfile` (croisé) | linux/amd64 | 10,1 s | 2,8 s | 0,5 s |
| `Dockerfile` (croisé) | **linux/arm64** | **11,0 s** | 2,8 s | 0,5 s |

Builds à froid **avec push** du Dockerfile croisé : amd64 11,1 s · arm64 11,4 s · **amd64 + arm64 12,6 s**. Le second arch ne coûte presque rien : un deuxième `pip install` de wheels et des `COPY`.

### Réponses

**Pourquoi `--push` ou `-o` est-il obligatoire avec plusieurs plateformes ?** Le résultat d'un build multi-plateforme est un **index** (manifest list) qui référence plusieurs images. Le magasin d'images classique de dockerd (sans *containerd image store*) associe un tag à **une seule** image pour **une seule** plateforme. Il ne peut pas stocker cet index, donc `--load` refuse au-delà d'une plateforme. Avec le driver `docker-container`, le résultat n'existe que dans le cache de BuildKit. Sans exporteur, il est construit puis jeté (buildx prévient : *« No output specified »*). Il faut donc l'envoyer dans un registre (`--push`) ou l'exporter (`-o type=oci,dest=worker.tar` : l'archive OCI sait contenir un index). Avec le containerd image store activé, `--load` multi-plateforme devient possible.

**Que contient le manifest list ?**

```text
$ SSL_CERT_FILE=…/ca.crt docker buildx imagetools inspect --builder shop localhost:5000/shop-worker:1.0
MediaType: application/vnd.oci.image.index.v1+json
Digest:    sha256:96829ea8972d88835a382f35378be5cc3a4b40d93143a375760c9f96741e1ea9
Manifests:
  Name: …@sha256:c3ddea4b…   Platform: linux/amd64
  Name: …@sha256:4beb4ac7…   Platform: linux/arm64
  Name: …@sha256:fb7b1317…   Platform: unknown/unknown   vnd.docker.reference.type: attestation-manifest  (→ c3ddea4b)
  Name: …@sha256:b1af16da…   Platform: unknown/unknown   vnd.docker.reference.type: attestation-manifest  (→ 4beb4ac7)
```

C'est un **OCI image index** : une liste de descripteurs `{mediaType, digest, size, platform{os, architecture, variant}}`, un par plateforme. Chacun pointe vers un manifeste d'image classique (config + couches de *cette* architecture). buildx ajoute un **manifeste d'attestation** par plateforme (provenance SLSA, minimale par défaut), marqué `unknown/unknown` pour qu'aucun moteur ne tente de l'exécuter et relié à son image par l'annotation `vnd.docker.reference.digest`. Au `pull`, le client lit l'index, choisit l'entrée de sa plateforme et ne télécharge que celle-ci. Le digest qu'on épingle en prod (TP03) est celui de l'index.

**Comment `TARGETARCH` isole-t-il le cache pip par architecture ?** BuildKit définit automatiquement `TARGETARCH` (`amd64`, `arm64`) pour chaque plateforme construite. On le déclare (`ARG TARGETARCH`) puis on l'utilise dans l'**id** du cache mount : `--mount=type=cache,id=pip-${TARGETARCH},…,sharing=locked`. Résultat : deux caches distincts, `pip-amd64` et `pip-arm64` (visibles dans `docker buildx du --verbose`). Cela sert à deux choses :
1. ne pas mélanger les wheels compilées : `psycopg2_binary-…-x86_64.whl` et `…-aarch64.whl`. Les caches de compilation (`ccache`, `~/.cargo`, `go-build`) sont eux réellement incompatibles d'une architecture à l'autre ;
2. avec `sharing=locked`, un seul `RUN` à la fois accède à un mount donné. Un id par architecture permet aux builds amd64 et arm64 de tourner **en parallèle** sans s'attendre.

Le stage `test`, natif, utilise `pip-${BUILDARCH}`.

**Pourquoi le build arm64 est-il plus lent sur une machine amd64 ?** QEMU en mode utilisateur (`binfmt_misc` + `qemu-aarch64`, ou ici l'émulateur intégré à BuildKit) **traduit dynamiquement** chaque instruction ARM en instructions x86 (TCG). Chaque processus lancé (`python`, `pip`, `gcc`…) est interprété ainsi, avec un coût de 5 à 20× sur le CPU, et pire pour les démarrages de processus et les appels système. Mesuré ici, émulé contre natif : **×5,6 sur le build, ×8,5 sur `pip install`, ×12 sur ruff + pytest**. Sur une compilation C (wheel sans binaire, extension native), on passe facilement de quelques minutes à des dizaines de minutes.

**Alternatives** :

- **Builders natifs** : un nœud BuildKit par architecture dans le même builder, et buildx répartit chaque plateforme sur le bon nœud :

  ```bash
  docker buildx create --name shop --platform linux/amd64 --driver docker-container   # nœud local
  docker buildx create --name shop --append --platform linux/arm64 ssh://ci@graviton-runner   # nœud arm64 distant (ou tcp://…:1234 + mTLS)
  docker buildx build --builder shop --platform linux/amd64,linux/arm64 …
  ```

  Variantes : driver `kubernetes` avec un `nodeSelector` par architecture, runners CI arm64 natifs (GitHub `ubuntu-24.04-arm`), Docker Build Cloud.
- **Compilation croisée** (implémentée ici) : `FROM --platform=$BUILDPLATFORM`, téléchargement des binaires cibles (`pip --platform`, `npm` sans scripts natifs) ou compilateur croisé (`GOARCH=$TARGETARCH go build`, `xx-clang` de `tonistiigi/xx` pour le C). Elle est rapide et ne demande aucune infrastructure. Ses limites : les tests ne tournent que sur l'architecture du builder, et il faut que des binaires cibles existent, ici des wheels `manylinux_aarch64`, sinon `--only-binary=:all:` échoue.

> Piège rencontré avec la compilation croisée : dans [`Dockerfile.uv`](shop-worker/Dockerfile.uv), `FROM ${UV_IMAGE} AS uv` est résolu pour la plateforme **cible**. Le binaire `uv` arm64 était donc copié dans le stage de build amd64 (`uv: Exec format error`). Il faut `FROM --platform=$BUILDPLATFORM ${UV_IMAGE} AS uv`.

## Étape 5 — Cache distant

Builder `shop` vidé entre l'export et l'import, pour simuler deux runners CI éphémères. Build amd64 + arm64 + push ([`logs/12-remote-cache.log`](logs/12-remote-cache.log), [`logs/13-cache-min-max.log`](logs/13-cache-min-max.log)) :

| Scénario (runner neuf) | Total | Étapes `CACHED` | `pip install` exécutés | Tests exécutés |
|---|---|---|---|---|
| Sans cache distant | 13,4 s | 0 | 3 | 1 |
| 1er build `--cache-to …,mode=max` (export) | 16,2 s | 0 | 3 | 1 |
| 2e runner `--cache-from` (`max`), rien n'a changé | **4,7 s** | 20 | 0 | 0 |
| 2e runner `--cache-from` (`min`), rien n'a changé | **5,3 s** | 20 | 0 | 0 |
| Code modifié (`worker/main.py`), `--cache-from` **max** | 9,3 s | 14 | **0** | 1 |
| Code modifié (`worker/main.py`), `--cache-from` **min** | 13,0 s | 12 | **1** | 1 |

| Cache exporté | Blobs | Taille |
|---|---|---|
| `cache:worker-max` | 26 | 113 Mio |
| `cache:worker-min` | 16 | 90,3 Mio |

**`mode=min` vs `mode=max`** :

- `min` (défaut) n'exporte que le cache des couches **de l'image finale** (stage `runtime`). Quand rien ne change, cela suffit : le résultat final est trouvé et les stages intermédiaires ne sont même pas évalués. Dès que le code change, les stages intermédiaires qui ne sont pas dans l'image doivent être **reconstruits** : ici, le `pip install` des dépendances de dev du stage `test`.
- `max` exporte **tous les stages** (`builder`, `test`, `users`…). Le cache est plus gros (+25 % ici, beaucoup plus avec une toolchain de compilation) et l'export plus long, mais seul ce qui dépend réellement du changement est rejoué. C'est le bon choix pour un Dockerfile multi-stage en CI.

**Variantes CI** :

```bash
# GitHub Actions (cache de l'API Actions ; docker/setup-buildx-action fournit le token)
--cache-to type=gha,mode=max,scope=shop-worker --cache-from type=gha,scope=shop-worker
# S3 (ou MinIO), partagé entre runners self-hosted
--cache-to type=s3,region=eu-west-3,bucket=shop-buildkit-cache,name=shop-worker,mode=max \
--cache-from type=s3,region=eu-west-3,bucket=shop-buildkit-cache,name=shop-worker
```

Une variante intermédiaire, `type=inline`, inscrit les métadonnées de cache **dans l'image poussée**. Elle n'existe qu'en `mode=min`. À retenir : un cache distant ne transporte que des **couches**. Le contenu des **cache mounts** (`/root/.cache/pip`) n'est **pas** exporté. Sur des runners éphémères, il faut le persister autrement (volume de runner, action `buildkit-cache-dance`) ou s'appuyer sur `mode=max`.

## Étape 6 — `docker buildx bake`

Voir [`docker-bake.hcl`](docker-bake.hcl) et ses sorties dans [`tp02-buildkit-avance.md`](tp02-buildkit-avance.md#6-docker-buildx-bake). Résumé :

| Commande | Résultat |
|---|---|
| `docker buildx bake --print` | plan JSON : 2 cibles héritant de `_common`, tags `${REGISTRY}/<nom>:${VERSION}` et `:sha-${GIT_SHA}`, cache registre `mode=max` par cible, secret `pipconf` pour le worker |
| `VERSION=1.0 GIT_SHA=… docker buildx bake worker-test` | lint + 2 tests OK, sans image produite (`output=type=cacheonly`). Avec un test cassé : `AssertionError`, exit 1 |
| `bake --set '*.platform=linux/amd64' --load` | `localhost:5000/shopapi:1.0` (152 Mo) et `localhost:5000/shop-worker:1.0` (130 Mo) chargées dans dockerd |
| `bake --push` | api et worker poussés en **amd64 + arm64**, en 2 tags chacun |

---

## Bonus

### B1 — Build sans accès Internet (`--network=none`)

Démontré avec [`Dockerfile.uv`](shop-worker/Dockerfile.uv) ([`logs/20-offline.log`](logs/20-offline.log)). Un `ARG` étant visible en variable d'environnement des `RUN`, `--build-arg UV_OFFLINE=true` active le mode hors ligne d'uv : il n'utilise que son cache, ici le cache mount.

```text
1) en ligne                                    → exit=0  Installed 3 packages | Installed 8 packages
3) --network=none --build-arg UV_OFFLINE=true  → exit=0  Installed 3 packages | Installed 8 packages   (cache mount)
4) idem, cache mount vidé                      → exit=1  hint: Packages were unavailable because the network was disabled.
                                                         When the network is disabled, registry packages may only be read from the cache.
```

Le cas 4 prouve que rien ne vient du réseau. Je n'ai pas fait confiance à un succès « sans réseau » sans le vérifier : un `RUN wget https://pypi.org` donne bien `NETWORK-KO` avec `--network=none` et `NETWORK-OK` sans. Avec pip, l'équivalent passe par un *wheelhouse* : `pip download -d /wheels` en ligne, dans un cache mount, puis `pip install --no-index --find-links /wheels` hors ligne. On ne peut pas compter sur le cache HTTP de pip : les pages d'index expirent au bout de 10 min (`max-age=600`), et pip n'a pas de vrai mode hors ligne.

**Utilité en entreprise** :
- **Environnements isolés** (défense, santé, banque, OIV, industriel) : runners de build sans accès à Internet, seulement à un miroir interne. Pré-remplir le cache, ou mieux un miroir PyPI interne, permet de builder quand même.
- **Builds hermétiques** (SLSA niveau 3 ou plus) : la sortie ne dépend que d'entrées déclarées et versionnées. Aucun téléchargement imprévu, au moment du build, ne peut modifier l'image (dépendance republiée, typosquatting, index compromis).
- **Exfiltration** : un `RUN` compromis (script `postinstall` malveillant) ne peut rien envoyer vers l'extérieur.
- **Robustesse** : la CI ne tombe pas quand PyPI ou Docker Hub sont indisponibles ou limitent le débit.

### B2 — Attestations provenance et SBOM

```text
$ docker buildx build … --provenance=mode=max --sbom=true -t localhost:5000/shop-worker:1.0-attested --push .
$ docker buildx imagetools inspect localhost:5000/shop-worker:1.0-attested --format '{{json .Provenance}}' | jq '."linux/amd64".SLSA …'
{
  "args": { "build-arg:GIT_SHA": "068ba9e", "build-arg:VERSION": "1.0", "source": "docker/dockerfile:1.7" },
  "secrets": [ { "id": "pipconf", "optional": true } ],                       ← l'id du secret, jamais sa valeur
  "materials": [ "pkg:docker/docker/buildkit-syft-scanner@stable-1",
                 "pkg:docker/docker/dockerfile@1.7",
                 "pkg:docker/python@3.12.15-slim-trixie?platform=linux%2Famd64" ]   ← images de base avec digest
}
$ docker buildx imagetools inspect … --format '{{json .SBOM}}' | jq '."linux/arm64".SPDX.packages | length, …'
99
["prometheus-client","psycopg2-binary","redis"]                               ← ni pytest ni ruff : SBOM de l'image finale
```

La **provenance** (SLSA) décrit *comment* l'image a été construite : builder, Dockerfile, args, secrets référencés, *materials* (images de base et contextes, par digest) et, en `mode=max`, le détail des étapes. Le **SBOM** (SPDX, généré par le scanner syft intégré à BuildKit) décrit *ce qu'elle contient*, par plateforme. Les deux sont stockés dans le registre, attachés à l'index (manifestes `attestation-manifest`). C'est le lien avec le TP03 : on peut les signer (`cosign attest`), et `trivy sbom` peut scanner ce SBOM sans retélécharger l'image.

⚠️ **Lien avec l'étape 1** : en `mode=max`, la provenance enregistre **tous les `--build-arg`**, même ceux qui ne sont déclarés nulle part dans le Dockerfile :

```text
$ docker buildx build … --build-arg PIP_INDEX_URL=https://svc-ci:Tr3sS3cret@pypi.internal.example.com/simple --provenance=mode=max --push .
$ docker buildx imagetools inspect localhost:5000/shop-worker:leak-provenance --format '{{json .Provenance}}' | grep -o 'svc-ci:[^@]*@'
svc-ci:Tr3sS3cret@
```

C'est une raison de plus pour ne **jamais** faire passer un secret par `--build-arg`. (Le tag de démo a été supprimé du registre.)

### B3 — `uv` au lieu de `pip`

[`Dockerfile.uv`](shop-worker/Dockerfile.uv) : binaire uv copié depuis `ghcr.io/astral-sh/uv:0.13.5`, cache mount `/root/.cache/uv` par architecture, `UV_LINK_MODE=copy` (le cache mount est sur un autre système de fichiers, les hardlinks sont impossibles), index en **secret d'environnement** (`UV_DEFAULT_INDEX`), compilation croisée par `uv pip install --python-platform aarch64-manylinux_2_28 --target …`. Image de 128 Mo, contre 130 Mo avec pip.

Durée des étapes d'installation, amd64 ([`logs/19-uv-vs-pip.log`](logs/19-uv-vs-pip.log)) :

| | `[builder]` deps runtime (3 paquets) | `[test]` runtime + dev (8 paquets) |
|---|---|---|
| pip, à froid | 3,9 s | 2,7 s |
| pip, cache mount plein | 3,1 s | 2,1 s |
| uv, à froid | 2,7 s | 2,9 s |
| uv, **cache mount plein** | **0,1 s** | **0,1 s** |

Builds complets (amd64 + arm64) : pip 7,5 s à froid / 5,3 s avec cache, uv 8,5 s / 4,9 s.

À froid, les deux sont limités par le téléchargement. **Avec cache**, uv est ~30× plus rapide sur l'installation. pip, même avec ses wheels en cache, recontacte l'index pour résoudre les versions (sauf page encore fraîche) et décompresse chaque wheel. uv résout en parallèle, garde l'index en cache selon les en-têtes HTTP et installe depuis un cache déjà décompressé. Sur 8 paquets le gain total reste modeste. Sur un vrai projet (100 à 300 dépendances), il se compte en dizaines de secondes à chaque build.
