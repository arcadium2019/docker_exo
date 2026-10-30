# TP09 — CI/CD : de la pull request au déploiement sans interruption

Livrables dans `shop/` :

- `.github/workflows/ci.yml` ;
- `ci-local.sh` ;
- `deploy/rolling-update.sh` et `deploy/measure-downtime.sh` ;
- `compose.yml` adapté.

Les traces (« captures » en texte) sont dans `logs/`.

## 1. Le dépôt

`shop/` regroupe `apps/shopapi`, `apps/shop-worker`, la stack Compose du TP04, `smoke-test.sh`, `release-gate.sh` et `tools.sh` du TP03. `.gitignore` exclut `secrets/*.txt`, `.env`, `ci/out/`, `.scan/` et `.release/`.

Écarts :

- **Pas de `git init` ni de push** : un dépôt imbriqué dans le dépôt du cours poserait problème, et je n'ai rien publié sur GitHub. Le SHA vient du dépôt du cours (`74ae4fe`). La seconde version `b2c3d4e` est un commit **simulé** (`GIT_SHA=b2c3d4e ./ci-local.sh`), qui sert de « nouvelle version » pour le rolling update et le rollback.
- Les chemins de l'énoncé (`../../jour2-run/...`) ne correspondent pas à ce dépôt : les sources viennent de mes réponses TP01-04.

## 2. Le pipeline

**`.github/workflows/ci.yml`** (validé par `actionlint` : 0 erreur, `logs/02-actionlint.txt`) :

| Déclencheur | Jobs |
|-------------|------|
| pull request | `lint` (hadolint ×2, `compose config` base et prod) → `build` en matrice `[shopapi, shop-worker]` : étape `test`, puis build multi-arch **sans push** |
| push `main` | + login GHCR, push `sha-<sha>`, **trivy bloquant** (HIGH/CRITICAL corrigeables), **cosign keyless** (`id-token: write`, OIDC GitHub) → `deploy-preprod` : `cosign verify` (identité du workflow et émetteur OIDC) puis `rolling-update.sh` via `DOCKER_HOST=ssh://deploy@…` |
| tag `v*` | tags semver (`1.2.3`, `1.2`) → `deploy-prod` dans `environment: prod` (**approbation manuelle** configurée dans les règles de protection de l'environnement), vérification de signature avant déploiement |

Points techniques imposés, tous présents :

- `docker/metadata-action` pour les tags et les labels OCI ;
- cache `type=gha` par application ;
- `platforms: linux/amd64,linux/arm64` (QEMU + buildx) ;
- matrice api/worker ;
- secret de build `pipconf` alimenté par `secrets.PIP_CONF`, jamais dans une couche ;
- `provenance: mode=max` et `sbom: true`.

**`ci-local.sh [pr|main]`** rejoue les mêmes étapes en local. Il pousse vers un registre jetable `registry:2.8.3` sur `127.0.0.1:5002` : je n'ai pas relancé le registre TLS du TP03, qui était arrêté.

```
== lint: hadolint                   apps/shopapi/Dockerfile OK / apps/shop-worker/Dockerfile OK
== lint: docker compose config      compose.yml OK / compose.prod.yml OK
== test stage                       shopapi tests OK / shop-worker tests OK
== build sha-74ae4fe
== gate: trivy                      shopapi: 0 fixable HIGH/CRITICAL -> pass / shop-worker: 0 … -> pass
== push to localhost:5002
== sign + verify (cosign, by digest)
verified: shopapi@sha256:cba22caadbf154cf7f8703a634245e04b7aef26a6893739f3030d379e72fc4a9
verified: shop-worker@sha256:3e32153415b5885f8d2e1c9452dc2644a78ac3639ff65e1514b5bc4dff49bc4f
== main pipeline OK: localhost:5002/{shopapi,shop-worker}:sha-74ae4fe
```

Ce sont les traces du pipeline vert : `logs/01-ci-local-main.txt`, `01b-…-b2c3d4e.txt` et `01c-…-pr.txt`. La signature est vérifiée.

Différences assumées entre le local et la CI :

- build mono-arch en `--load` : le driver `docker` ne charge pas une image multi-arch ;
- cosign **avec clé** (`ci/out/cosign.key`, générée par le script et gitignorée), parce que le mode keyless exige le jeton OIDC de la CI ;
- pas d'upload dans le journal de transparence (`--tlog-upload=false`).

Pièges rencontrés :

- `hadolint:v2.12.0` ne connaît pas `HEALTHCHECK --start-interval` (« invalid flag »), d'où le passage en **v2.15.1**.
- Dans une boucle, `cmd && echo OK` neutralise `set -e` : l'erreur passait inaperçue. Le script laisse maintenant `set -e` faire échouer l'étape.

## 3. Déploiement distant

```
$ docker context create shop-preprod --docker "host=unix:///var/run/docker.sock"
$ docker --context shop-preprod ps
$ DOCKER_CONTEXT=shop-preprod docker compose -f compose.yml -f compose.prod.yml up -d --wait
shop-api-1  localhost:5002/shopapi:sha-74ae4fe  Up (healthy) …
$ curl api.localhost/   → {"service":"shopapi","version":"sha-74ae4fe"}
```

Je n'ai pas configuré `ssh://localhost` : il aurait fallu un sshd local et toucher à `~/.ssh/authorized_keys`, ce que je n'ai pas fait. Le contexte pointe sur la socket locale. Le mécanisme est identique : seul le transport change (`host=ssh://deploy@preprod.local`).

**Prérequis côté serveur** :

- Docker Engine et le plugin compose installés ;
- un utilisateur `deploy` dans le groupe `docker` (c'est l'équivalent de root : compte dédié, sans mot de passe) ;
- `sshd` avec authentification par **clé seule**, et la clé publique de la CI dans `authorized_keys` (restreinte par `from=` à l'IP du runner) ;
- l'accès en pull au registre (`docker login` du compte `deploy`, jeton en lecture seule) ;
- **`.env` et `secrets/db_password.txt` présents sur le serveur**, jamais dans git.

**Comment les secrets arrivent en prod** : ils sont posés une fois sur le serveur (Ansible, ou un ops via un coffre type Vault/Bitwarden), avec les droits `600` pour `deploy`.

Il y a un piège avec un `docker context` distant. Compose interprète le fichier **côté client** (la CI), mais les `secrets.file` et les bind mounts (`init.sql`, `secrets/…`) deviennent des montages **résolus par le démon distant** : le fichier doit exister **sur le serveur, au même chemin absolu**. On fixe donc un chemin de déploiement identique des deux côtés (`/srv/shop`), on lance compose depuis un checkout sur le serveur, ou on passe à des secrets externes (Swarm, SOPS).

La CI ne transporte que la clé SSH (`secrets.PROD_SSH_KEY`), jamais le mot de passe de la base.

## 4. Zéro interruption

`measure-downtime.sh 45 100` envoie environ 100 req/s sur `/health` via Traefik et compte tout ce qui n'est pas un 200 (timeout de 2 s par requête).

| Déploiement | Requêtes | Échecs |
|-------------|---------:|-------:|
| **Naïf** `up -d --force-recreate api` (config TP04) | 2 400 | **443** (200 × 404, 170 × 502, 73 timeouts) |
| **Naïf** avec la config Traefik finale | 2 400 | **213** (200 × 404, 7 × 502, 6 × 504) |
| Rolling v1 (retry 3) | 4 400 | 3 × 502 |
| Rolling v2 (retry 5 + back-off 100 ms) | 4 300 | 34 timeouts |
| **Rolling final** (+ `dialtimeout=300ms`) `74ae4fe → b2c3d4e` | 4 300 | **0** |
| **Rollback** final `b2c3d4e → 74ae4fe` | 4 300 | **0** |

Les 404 du naïf correspondent au moment où les deux réplicas sont recréés **en même temps** : Traefik n'a plus aucun backend, donc plus de routeur, donc 404.

**`rolling-update.sh`** :

1. vérifie la signature de l'image cible et **refuse une image non signée** (`VERSION=unsigned` → « signature verification FAILED … abort », exit 1) ;
2. pour chaque ancien réplica : `up --no-recreate --scale api=N+1` crée un réplica avec la nouvelle image, le script attend qu'il soit `healthy`, puis encore 3 s (un health check Traefik), puis lance `docker stop -t 15` sur l'ancien et le supprime.

**Diagnostic des derniers échecs** (logs d'accès Traefik) : les 502 tombaient sur l'IP de l'ancien réplica **juste après son arrêt**. Traefik met environ 2 s à le retirer (délai de regroupement des événements du provider). Pendant ce temps :

- une connexion vers une IP qui n'existe plus attend le **`dialTimeout` par défaut de 30 s** (d'où les 34 timeouts de la v2, où le back-off allongeait encore l'attente) ;
- `--serverstransport.forwardingtimeouts.dialtimeout=300ms` fait échouer cette connexion vite, et le middleware `retry` rejoue la requête sur l'autre réplica.

**Rôle de chaque brique, et ce qui se passe sans elle** :

| Brique | Rôle | Sans elle |
|--------|------|-----------|
| `HEALTHCHECK` de l'image + `start_period` | Docker sait quand le process est prêt ; pendant `start_period`, les échecs ne comptent pas | Le script ne sait pas quand basculer ; une app lente à démarrer serait marquée `unhealthy` et redémarrée en boucle |
| Healthcheck Traefik (`/ready`, 2 s) + conteneurs `healthy` uniquement | Traefik ne route que vers un réplica prêt (base et Redis joignables) | Traefik envoie du trafic à un réplica qui démarre : 502 |
| `--wait` | `compose up` ne rend la main qu'avec une stack saine | La CI déclare le déploiement réussi alors que l'app crashe |
| SIGTERM géré (TP01) | L'API ferme son listener et termine ses requêtes en cours | Kill brutal : requêtes en vol coupées, 502 |
| `stop_grace_period` / `stop -t 15` | Laisse 15 s au drain avant le SIGKILL | Défaut de 10 s : une requête longue est tuée |
| Réplicas ≥ 2 | Il reste toujours un réplica sain pendant le remplacement de l'autre | Aucune capacité pendant la bascule : 404/502 garantis (le cas naïf) |
| Proxy + `retry` + `dialTimeout` court | Absorbe la fenêtre où Traefik route encore vers un réplica arrêté | Quelques 502 ou timeouts à chaque arrêt (mesuré : 3 ou 34) |

## 5. Rollback

`time VERSION=sha-74ae4fe ./deploy/rolling-update.sh` → **23,7 s, 0 échec** (`logs/06-rollback.txt`). C'est exactement la même procédure qu'une mise à jour.

**Ce qui rend le rollback possible** :

- des **tags immuables** `sha-<sha>` : `sha-74ae4fe` désigne toujours le même digest, alors qu'un `latest` aurait été écrasé ;
- l'image encore **présente sur l'hôte** ou dans le registre (rétention du TP03) : pas de rebuild, et un pull rapide ou inutile ;
- une **base compatible** avec les deux versions ;
- la signature de l'ancienne image, toujours valide.

**Migration non rétro-compatible** (renommer ou supprimer une colonne) : le rollback de l'image **ne suffit plus**, car l'ancien code ne comprend pas le nouveau schéma, et pendant le rolling update les deux versions tournent **en même temps**. Il faut appliquer le modèle **expand / contract** :

1. une release ajoute la nouvelle colonne et écrit dans les deux ;
2. un backfill remplit la nouvelle colonne ;
3. une release lit la nouvelle colonne ;
4. plus tard, une release supprime l'ancienne.

Chaque étape reste compatible avec la précédente. À défaut, il faut une restauration de sauvegarde (TP05), avec perte des écritures intervenues entre-temps.
