# TP03 — Registre privé et chaîne d'approvisionnement

| Fichier | Rôle |
|---|---|
| [`registry/compose.yml`](registry/compose.yml) | Registre + passerelle TLS/auth (nginx) + mirror Docker Hub + UI |
| [`registry/config.yml`](registry/config.yml), [`registry/mirror-config.yml`](registry/mirror-config.yml) | Configuration du registre et du pull-through cache |
| [`registry/nginx/registry.conf`](registry/nginx/registry.conf) | TLS, basic auth bcrypt, **droits push/pull** |
| [`registry/gen-certs.sh`](registry/gen-certs.sh), [`registry/gen-htpasswd.sh`](registry/gen-htpasswd.sh) | CA interne et certificat serveur, comptes `ci` et `dev` |
| [`registry/setup-client.sh`](registry/setup-client.sh), [`registry/daemon.json`](registry/daemon.json) | Configuration côté client (**sudo**, voir encadré) |
| [`registry-env.sh`](registry-env.sh) | Variables pour parler à l'API avec `curl` |
| [`retention.sh`](retention.sh) | Rétention des tags non-semver |
| [`TAGGING.md`](TAGGING.md) | Politique de tags |
| [`tools.sh`](tools.sh) | `syft`, `trivy`, `cosign`, `crane` lancés en conteneur |
| [`trivy-secret.yaml`](trivy-secret.yaml) | Règle de secret personnalisée (mot de passe dans une URL) |
| [`release-gate.sh`](release-gate.sh) | **La porte de release** |
| [`verified-run.sh`](verified-run.sh) | Bonus B3 : `docker run` uniquement si la signature est valide |
| [`compose.prod.example.yml`](compose.prod.example.yml) | Image référencée par digest |
| [`logs/`](logs/) | Sorties brutes |

> **Contraintes du poste** : je n'ai pas les droits sudo, donc je ne peux modifier ni `/etc/hosts`, ni `/etc/docker/certs.d/`, ni `/etc/docker/daemon.json`. Tout est prêt dans `registry/setup-client.sh`. En attendant :
> - **`curl`** atteint `registry.local:5000` via `--resolve registry.local:5000:127.0.0.1 --cacert ca.crt` : le TLS est vérifié pour de vrai contre la CA, avec le bon nom.
> - Le **daemon Docker** utilise `localhost:5000`. Le certificat a un SAN `localhost`, et Docker considère `127.0.0.0/8` comme registre « insecure » par défaut : il accepte alors le certificat sans vérifier la CA. Tout le reste (TLS, auth, droits) est identique.
> - Le **mirror** est testé en tirant explicitement `localhost:5001/library/alpine:3.20`.
>
> Après `./registry/setup-client.sh`, toutes les commandes fonctionnent avec `registry.local:5000` à la place de `localhost:5000`.

---

## 1. Registre sécurisé

### Architecture

```text
                       ┌──────────────────────── shop-registry (compose) ────────────────────────┐
docker / curl ──TLS──► │ gateway  nginx:1.27-alpine  :5000→443                                    │
 (ci / dev)            │   • TLS (cert signé par la CA interne, SAN registry.local, localhost)    │
                       │   • auth_basic, htpasswd bcrypt (coût 10)                                │
                       │   • GET/HEAD : tout compte authentifié — POST/PUT/PATCH/DELETE : ci seul │
                       │        │ http                                                            │
                       │        ▼                                                                 │
                       │ registry  registry:2.8.3  (non publié)  config.yml, volume registry-data │
                       │                                                                          │
navigateur ──────────► │ ui  joxit/docker-registry-ui  127.0.0.1:8089 ──proxy──► gateway (auth)   │
                       │                                                                          │
dockerd ──http───────► │ mirror  registry:2.8.3 en proxy  127.0.0.1:5001 ──► registry-1.docker.io │
                       └──────────────────────────────────────────────────────────────────────────┘
```

**Pourquoi une passerelle nginx ?** L'auth `htpasswd` de `registry:2` ne fait que de l'**authentification** : tout compte valide peut pousser *et* supprimer. Le besoin « `ci` pousse, `dev` tire » est de l'**autorisation**. `registry:2` ne la propose qu'en mode *token* (avec un serveur comme `cesanta/docker_auth`). La solution la plus simple est un reverse proxy qui filtre sur la méthode HTTP et l'utilisateur :

```nginx
map "$request_method:$remote_user" $write_denied {
  default          1;
  "~^(GET|HEAD):"  0;    # lecture : tout utilisateur authentifié
  "~^[A-Z]+:ci$"   0;    # écriture : ci uniquement
}
```

### Mise en place

```bash
cd registry
./gen-certs.sh            # CA interne (10 ans) + certificat serveur (825 j), SAN registry.local, localhost, 127.0.0.1
./gen-htpasswd.sh         # ci:ci-push-2024, dev:dev-pull-2024 (bcrypt -C 10, via httpd:2.4-alpine)
openssl rand -hex 32 | sed 's/^/REGISTRY_HTTP_SECRET=/' > .env
docker compose up -d
```

Le `config.yml` monté remplace la quinzaine de variables `REGISTRY_*` : stockage `filesystem` sur le volume nommé `registry-data`, `storage.delete.enabled: true`, purge des uploads abandonnés, endpoint de debug `:5005` pour le healthcheck, `http.secret` stable (sans lui, un upload commencé sur un réplica échoue sur un autre). `.gitignore` exclut `*.key`, `htpasswd` et `.env`.

```text
$ docker compose ps
SERVICE    STATUS                    PORTS
gateway    Up 25 seconds (healthy)   80/tcp, 0.0.0.0:5000->443/tcp, [::]:5000->443/tcp
mirror     Up 31 seconds (healthy)   127.0.0.1:5001->5000/tcp
registry   Up 30 seconds (healthy)   5000/tcp
ui         Up 15 seconds             127.0.0.1:8089->80/tcp
```

### Validation

```text
$ curl https://registry.local:5000/v2/                       # sans la CA
curl: (60) SSL certificate problem: unable to get local issuer certificate

$ curl --cacert certs/ca.crt -i https://registry.local:5000/v2/          # 401
HTTP/1.1 401 Unauthorized
WWW-Authenticate: Basic realm="Shop SAS registry"

$ curl --cacert certs/ca.crt -u dev:mauvais https://registry.local:5000/v2/
401
$ curl -k -u dev:dev-pull-2024 https://registry.local:5000/v2/_catalog
{"repositories":[]}

$ openssl s_client -connect 127.0.0.1:5000 -servername registry.local -CAfile certs/ca.crt
Protocol: TLSv1.3
Verify return code: 0 (ok)
subject=O=Shop SAS, CN=registry.local
X509v3 Subject Alternative Name: DNS:registry.local, DNS:localhost, IP Address:127.0.0.1

# Droits
$ curl -u dev:dev-pull-2024 -X POST https://registry.local:5000/v2/test/blobs/uploads/
{"errors":[{"code":"DENIED","message":"push requires the ci account"}]} -> 403
$ curl -u ci:ci-push-2024 -X POST https://registry.local:5000/v2/test/blobs/uploads/
202
```

```text
$ echo "$CI_PASSWORD" | docker login localhost:5000 -u ci --password-stdin
Login Succeeded
$ docker tag shopapi:1.4.2 localhost:5000/shopapi:1.4.2 && docker push localhost:5000/shopapi:1.4.2
1.4.2: digest: sha256:0e322832db317fd07e57b36aef41cf23d5f13cae1611bdc0f659ca434add9756 size: 1991

# Compte dev : pull OK, push refusé
$ docker push localhost:5000/dev-test:1          (connecté en dev)
denied: {"errors":[{"code":"DENIED","message":"push requires the ci account"}]}
$ docker pull localhost:5000/shopapi:1.4.2       (connecté en dev)
localhost:5000/shopapi:1.4.2
```

**UI** sur `http://localhost:8089` : son nginx interne relaie `/v2/` vers la passerelle. Le navigateur n'a donc pas de problème CORS, et l'authentification reste appliquée :

```text
$ curl -s -o /dev/null -w "%{http_code}" localhost:8089/v2/_catalog     # sans auth
401
$ curl -s -u dev:dev-pull-2024 localhost:8089/v2/_catalog
{"repositories":["shopapi"]}
```

**Mirror** (pull-through cache, port 5001) :

```text
$ time docker pull localhost:5001/library/alpine:3.20     # 1er pull : récupéré sur Docker Hub
real	0m2,255s
$ time docker pull localhost:5001/library/alpine:3.20     # 2e pull : servi par le cache
real	0m0,591s

$ docker compose logs mirror
msg="Challenge established with upstream : {https registry-1.docker.io /v2/ ...}"  uri="/v2/library/alpine/manifests/3.20"
msg="Adding new scheduler entry for library/alpine@sha256:d9e853e8... with ttl=167h59m59s"
msg="Adding new scheduler entry for library/alpine@sha256:bf8527eb... with ttl=167h59m59s"     ← blob mis en cache
...
msg="response completed" HEAD /v2/library/alpine/manifests/3.20 200                            ← 2e pull :
msg="response completed" GET  /v2/library/alpine/blobs/sha256:bf8527eb... 200                    plus aucun
                                                                                                 « Adding new entry »
```

Au second pull, il n'y a ni nouveau « challenge » ni « scheduler entry » : les blobs sortent du volume `mirror-data`. Seul un `HEAD` de manifeste est encore relayé vers Docker Hub pour vérifier que le tag n'a pas bougé. Ce `HEAD` n'est pas décompté dans le rate limit de Docker Hub.

Pour que le daemon l'utilise de façon transparente (`docker pull alpine` passe alors par le mirror) : [`registry/daemon.json`](registry/daemon.json) avec `"registry-mirrors": ["http://localhost:5001"]`, installé par `setup-client.sh`, qui redémarre dockerd. ⚠️ Ce redémarrage arrête tous les conteneurs. Le mirror ne s'applique **qu'à Docker Hub**.

### Question : `htpasswd` suffit-il en entreprise ?

Non. Il convient pour un labo ou une petite équipe, pas au-delà :

| Besoin | `registry:2` + htpasswd | Harbor / Nexus / Artifactory / ECR / ACR / GAR |
|---|---|---|
| Identités | fichier local, mots de passe partagés, rotation manuelle et redémarrage | LDAP/AD, OIDC/SSO, comptes robots, tokens à durée de vie limitée, IAM cloud (pas de secret statique en CI) |
| Autorisation | aucune (il a fallu nginx ici) | **RBAC** par projet ou dépôt : lecteur, développeur, mainteneur, admin |
| Scan | aucun | **scan intégré** (Trivy dans Harbor, Inspector pour ECR, Defender pour ACR), politique « pas de pull si CVE critique » |
| Immuabilité | impossible | règles d'**immutabilité des tags** (`1.*`, `v*`…) |
| Rétention et quotas | scripts maison (`retention.sh`) et GC manuel avec le registre en lecture seule | politiques de rétention, **quotas** par projet, GC planifié en ligne |
| Réplication | aucune | **réplication** multi-sites ou multi-régions, pull-through vers Docker Hub, GHCR, Quay |
| Signature | stockage passif des `.sig` | vérification de signature (Notation, cosign) et politique de déploiement |
| Audit | logs bruts | journal d'audit (qui a poussé ou supprimé quoi), webhooks |
| Formats | images OCI | Helm, npm, PyPI, Maven… (Nexus, Artifactory) |
| HA | à construire (stockage S3 + plusieurs instances + `http.secret`) | intégrée ou managée (SLA cloud) |

## 2. Parler à l'API du registre (curl + jq)

```bash
source registry-env.sh   # REG=https://registry.local:5000, CURL=(curl -fsS --cacert … --resolve …), ACCEPT=…
```

```text
# Lister les dépôts
$ "${CURL[@]}" -u dev:dev-pull-2024 "$REG/v2/_catalog" | jq
{"repositories":["shopapi"]}

# Lister les tags d'un dépôt
$ "${CURL[@]}" -u dev:dev-pull-2024 "$REG/v2/shopapi/tags/list" | jq
{"name":"shopapi","tags":["1.4.2","sha-a1f3c20","sha-b7d9e41","sha-c2e8f53","sha-d4a6b19","sha-e9c1d07","1.4.2-distroless"]}

# Digest d'un tag : HEAD sur le manifeste, avec le bon Accept
$ "${CURL[@]}" -u dev:dev-pull-2024 -I -H "Accept: $ACCEPT" "$REG/v2/shopapi/manifests/1.4.2"
HTTP/1.1 200 OK
Content-Type: application/vnd.docker.distribution.manifest.v2+json
Docker-Content-Digest: sha256:0e322832db317fd07e57b36aef41cf23d5f13cae1611bdc0f659ca434add9756
```

`ACCEPT` liste les 4 types : OCI index, OCI manifest, Docker manifest list, Docker manifest v2. **Le bon `Accept` est indispensable** :

```text
$ curl -u dev:… -I "$REG/v2/shopapi/manifests/1.4.2"          # sans Accept
Content-Type: application/vnd.docker.distribution.manifest.v1+prettyjws
Docker-Content-Digest: sha256:542dc8bacd28b394a20cd17b9f13e4a21a6cad43f4a9bc4c3684e374d4d13ac7   ← autre digest !
```

Sans `Accept`, `registry:2` convertit le manifeste à la volée en **schema 1**, l'ancien format signé, et renvoie le digest *de cette conversion*. Ce digest ne correspond à rien de ce qui a été poussé : un `DELETE` dessus ne supprimerait rien, et un `pull @sha256:542d…` échouerait.

### Supprimer un tag, puis garbage-collect

Démonstration sur un dépôt jetable `demo-gc` : `busybox` poussé en `a`, puis **retagué côté registre** en `b` (GET du manifeste, PUT de ces mêmes octets sous un autre tag). Les deux tags pointent donc sur **le même manifeste** :

```text
$ MT=application/vnd.docker.distribution.manifest.v2+json
$ "${CURL[@]}" -u ci:… -H "Accept: $MT" $REG/v2/demo-gc/manifests/a -o m.json
$ "${CURL[@]}" -u ci:… -X PUT -H "Content-Type: $MT" --data-binary @m.json $REG/v2/demo-gc/manifests/b
201
$ tags + digests
{"name":"demo-gc","tags":["a","b"]}
a -> Docker-Content-Digest: sha256:63bb1322b9692d0a4ba0084a8168277d767a73048fc79a4869b912fe32d26bee
b -> Docker-Content-Digest: sha256:63bb1322b9692d0a4ba0084a8168277d767a73048fc79a4869b912fe32d26bee

$ "${CURL[@]}" -u ci:… -X DELETE $REG/v2/demo-gc/manifests/a                 # par tag : impossible
{"errors":[{"code":"DIGEST_INVALID","message":"provided digest did not match uploaded content"}]} -> 400
$ curl -u dev:… -X DELETE $REG/v2/demo-gc/manifests/sha256:63bb…              # dev : interdit
{"errors":[{"code":"DENIED","message":"push requires the ci account"}]} -> 403
$ "${CURL[@]}" -u ci:… -X DELETE $REG/v2/demo-gc/manifests/sha256:63bb…       # par digest
202
$ "${CURL[@]}" -u ci:… $REG/v2/demo-gc/tags/list
{"name":"demo-gc","tags":null}                                                ← a ET b ont disparu

$ docker compose exec registry du -sh /var/lib/registry/docker/registry/v2/blobs
97.4M
$ docker compose exec registry registry garbage-collect --delete-untagged /etc/docker/registry/config.yml
46 blobs marked, 4 blobs and 0 manifests eligible for deletion
blob eligible for deletion: sha256:2a9999ca…    Deleting blob: /docker/registry/v2/blobs/sha256/2a/2a9999ca…
blob eligible for deletion: sha256:63bb1322…    ...
$ docker compose exec registry du -sh /var/lib/registry/docker/registry/v2/blobs
95.2M
```

**Deux tags sur le même manifeste** : l'API v2 ne supprime pas un *tag*, elle supprime un *manifeste*, identifié par son digest. Tous les tags qui pointent dessus disparaissent ensemble. Supprimer « le vieux tag `sha-068ba9e` » peut donc emporter la release `1.4.2` si elle a été promue depuis ce build. C'est pour cela que `retention.sh` protège tout digest référencé par un tag semver. Pour retirer un seul tag, il faut un registre qui le permet (Harbor, ou `crane delete` sur les registres compatibles OCI 1.1 / distribution v3), ou faire pointer l'autre tag vers un autre manifeste.

**Garbage collect** : `DELETE` ne libère aucun octet, il ne fait que délier le manifeste. Les blobs sont supprimés par `registry garbage-collect` (*mark & sweep*). Précautions :
- passer le registre en **lecture seule** (`storage.maintenance.readonly.enabled: true`) ou l'arrêter pendant le GC : un push concurrent peut voir ses blobs supprimés en pleine écriture ;
- `--delete-untagged` supprime aussi les manifestes sans tag. Sur `registry:2.8`, cela peut toucher les manifestes **enfants d'un index multi-arch** : à manipuler avec prudence (lancer d'abord `--dry-run`).

### `retention.sh`

[`retention.sh REPO [KEEP] [--apply]`](retention.sh) liste les tags et met de côté les semver (`X.Y.Z[-pre]`) et les artefacts cosign (`sha256-….sig/.att`). Il trie ensuite les autres par **date de création de l'image** (champ `created` de la config, premier manifeste pour un index), garde les `KEEP` plus récents et supprime les autres **par digest**, sauf si ce digest est référencé par un tag protégé ou conservé. Il fonctionne en dry-run par défaut.

```text
# 5 builds de branche datés + sha-068ba9e = même manifeste que 1.4.2 (release promue depuis ce build)
$ ./retention.sh shopapi 2
repository=shopapi keep=2 apply=false protected=2 candidates=6
KEEP    sha-068ba9e  (2026-10-26T10:58:58.261199269+01:00)
KEEP    sha-d4a6b19  (2026-09-26T14:13:20Z)
DELETE  sha-b7d9e41  (2026-09-25T14:13:20Z) sha256:6b3623c9…  [dry-run]
DELETE  sha-e9c1d07  (2026-09-24T14:13:20Z) sha256:cc17e051…  [dry-run]
DELETE  sha-a1f3c20  (2026-09-23T14:13:20Z) sha256:dffcdd9b…  [dry-run]
DELETE  sha-c2e8f53  (2026-09-22T14:13:20Z) sha256:b06d5909…  [dry-run]

$ ./retention.sh shopapi 2 --apply
...
DELETED sha-c2e8f53  (2026-09-22T14:13:20Z) sha256:b06d5909…
$ curl …/v2/shopapi/tags/list
{"name":"shopapi","tags":["1.4.2","1.4.2-distroless","sha-d4a6b19","sha-068ba9e"]}

$ REG_USER=dev REG_PASSWORD=dev-pull-2024 ./retention.sh shopapi 0 --apply     # dev ne peut pas supprimer
SKIP    sha-068ba9e  (…) same digest as protected tag 1.4.2
curl: (22) The requested URL returned error: 403
```

Les tags ont été triés par date et non par ordre alphabétique. Avec `KEEP=0`, `sha-068ba9e` est protégé parce qu'il partage son digest avec `1.4.2`.

> **Piège rencontré** : mes premiers builds de test (`sha-*`) avaient tous **la même date** `created`. Seul un label changeait, tout le reste venait du cache, et BuildKit conserve alors la date des couches. J'ai reconstruit avec `--build-arg SOURCE_DATE_EPOCH=<date du commit>`, comme le ferait la CI. Le registre n'expose pas de date de push : il faut une date fiable *dans* l'image (`created`, ou un label `org.opencontainers.image.created`).
>
> Deuxième piège : mon premier retag « à la main » (`echo "$M" | curl --data-binary @-`) a créé un **autre digest**, parce que `echo` ajoute un `\n` final. Un manifeste doit être recopié **octet pour octet** (`-o fichier` puis `--data-binary @fichier`).

## 3. Politique de tags

Voir **[TAGGING.md](TAGGING.md)** : tags produits, lesquels sont immuables, pourquoi `latest` est interdit, référence par digest dans Compose.

Retag sans pull :

```text
$ skopeo copy --preserve-digests --src-cert-dir registry/trust --dest-cert-dir registry/trust \
    docker://localhost:5000/shopapi:1.4.2 docker://localhost:5000/shopapi:1.4
Copying blob sha256:36fea3e6…   (déjà présents : simple vérification)
Writing manifest to image destination

$ crane tag localhost:5000/shopapi:1.4.2 1                (crane en conteneur, cf. tools.sh)
localhost:5000/shopapi:1: digest: sha256:0e322832db317fd07e57b36aef41cf23d5f13cae1611bdc0f659ca434add9756 size: 1991

$ for t in 1.4.2 1.4 1; do crane digest localhost:5000/shopapi:$t; done
1.4.2 -> sha256:0e322832db317fd07e57b36aef41cf23d5f13cae1611bdc0f659ca434add9756
1.4   -> sha256:0e322832db317fd07e57b36aef41cf23d5f13cae1611bdc0f659ca434add9756
1     -> sha256:0e322832db317fd07e57b36aef41cf23d5f13cae1611bdc0f659ca434add9756
$ docker image ls localhost:5000/shopapi:1.4
(aucune image locale)
```

> `skopeo --cert-dir` doit pointer vers un dossier qui ne contient **que** `ca.crt`. Dans `certs/`, il trouve `ca.key` et le prend pour une clé client (*« missing client certificate ca.cert for key ca.key »*), d'où `registry/trust/`.

## 4. SBOM, scan, signature

Les outils tournent en conteneur via [`tools.sh`](tools.sh) (`source tools.sh`). Deux choix de sécurité :

- **Pas de socket Docker monté** dans syft ou trivy : monter `/var/run/docker.sock` revient à donner un accès root à l'hôte. Les images locales sont exportées avec `docker save` et scannées en archive (`--input` / `docker-archive:`). Les images du registre sont lues directement.
- **`DOCKER_CONFIG` dédié**, qui ne contient que le compte `ci` (`tools_login`). Je ne monte pas `~/.docker/config.json`, qui contient tous les autres identifiants du poste, dans des images tierces.

### SBOM (syft)

```text
$ syft registry:localhost:5000/shopapi:1.4.2 -o spdx-json > sbom.json ; jq '.packages | length' sbom.json
340
$ jq -r ".packages[].name" sbom.json | grep -E "^(express|pg|ioredis|pino|prom-client|eslint|nodemon|musl|busybox|node)$" | sort -u
busybox express ioredis musl node pg pino prom-client          ← pas d'eslint ni de nodemon : pas de deps de dev
$ syft docker-archive:.scan/shopapi_legacy.tar -o spdx-json | jq '.packages | length'
702
```

### Scan de vulnérabilités (trivy)

Sur la `1.4.2` construite au TP01 :

```text
$ trivy image --severity HIGH,CRITICAL --ignore-unfixed localhost:5000/shopapi:1.4.2
localhost:5000/shopapi:1.4.2 (alpine 3.23.4) [alpine]  -> 4 vulns   libssl3/libcrypto3 3.5.6-r0 -> 3.5.7/3.5.8
Node.js [node-pkg]                                   -> 22 vulns  (1 CRITICAL, 21 HIGH)
  CRITICAL tar 6.2.1 -> 7.5.19 (CVE-2026-59873)                usr/local/lib/node_modules/npm/node_modules/tar
  HIGH     cross-spawn 7.0.3 -> 7.0.5 (CVE-2024-21538)        usr/local/lib/node_modules/npm/node_modules/...
  HIGH     minimatch, glob, brace-expansion, pacote, sigstore, ip-address...
```

**Résultat important** : aucune CVE ne vient des dépendances de l'application. Les 22 CVE Node.js sont toutes dans **npm, livré avec l'image de base** (`/usr/local/lib/node_modules/npm`), et les 4 autres dans OpenSSL. La cause : **Node 20 est en fin de vie** (avril 2026) et `node:20-alpine` n'est plus reconstruite (dernière image : 6 mois). L'image passait tous les standards du TP01, mais la porte de release la refuserait.

**Correctif appliqué au [Dockerfile du TP01](../tp01-optimisation-image/shopapi/Dockerfile)**, stage `runtime` :

```dockerfile
RUN apk upgrade --no-cache \
    && rm -rf /usr/local/lib/node_modules/npm /usr/local/lib/node_modules/corepack /opt/yarn-* \
              /usr/local/bin/npm /usr/local/bin/npx /usr/local/bin/corepack /usr/local/bin/yarn /usr/local/bin/yarnpkg
```

Le runtime n'a besoin que de `node`. npm reste disponible dans les stages de build. Résultat : 0 CVE HIGH/CRITICAL corrigeable, et l'image passe de 144 à 152 Mo (`apk upgrade` ajoute une couche, et le `rm` ne réduit pas les couches de base). La vraie solution durable est de **passer sur une LTS maintenue** (`node:22-alpine` ou `node:24-alpine`, que `"engines": ">=20"` autorise). La contrainte `node:20` venait de l'énoncé du TP01.

### Scan de secrets (trivy)

```text
$ trivy image --scanners secret shopapi:legacy      (→ --input .scan/shopapi_legacy.tar)
CRITICAL  aws-access-key-id  /app/.env:4  AWS_SECRET_ACCESS_KEY=********************  (layer: COPY . /app)
```

Trivy **retrouve bien la clé AWS** du TP01 et indique même la couche fautive. En revanche, il **ne voit pas** le mot de passe PostgreSQL (`postgres://shop:S3cret!@…`), ni dans le `.env` ni dans l'`ENV` du Dockerfile, même avec `--image-config-scanners secret`. Aucune règle intégrée ne couvre « mot de passe dans une URL de connexion ». J'ai écrit une règle personnalisée, [`trivy-secret.yaml`](trivy-secret.yaml), avec une *allow-rule* sur `node_modules` et le cache npm : sans elle, on obtient 12 faux positifs, des exemples de doc du type `redis://user:pass@localhost`.

```text
$ trivy image --scanners secret --image-config-scanners secret --secret-config trivy-secret.yaml --input .scan/shopapi_legacy.tar
CRITICAL  aws-access-key-id           /app/.env         AWS_SECRET_ACCESS_KEY=********************
CRITICAL  connection-string-password  /app/.env         DATABASE_URL=postgres://shop:*******@localhost:5432/shop
CRITICAL  connection-string-password  /app/Dockerfile   ENV DATABASE_URL=postgres://shop:*******@db.internal:5432/shop
$ … même commande sur shopapi:1.4.2
0
```

L'`ENV` n'est trouvé ici que parce que le `Dockerfile` a été copié dans l'image. La porte de release ajoute donc son propre contrôle sur `Config.Env`.

### Signature et attestation (cosign)

J'utilise **cosign v2.6.5**, qui stocke la signature sous un tag `sha256-<digest>.sig` comme l'attend l'énoncé (v3 utilise par défaut le *bundle* Sigstore et l'API OCI *referrers*). L'option **`--tlog-upload=false`** est obligatoire ici : par défaut, cosign publie une entrée dans **Rekor, le journal de transparence public**, qui contiendrait le digest et la clé publique d'une image interne. La vérification se fait donc avec `--insecure-ignore-tlog=true`.

```text
$ COSIGN_PASSWORD="" cosign generate-key-pair
Private key written to cosign.key           (-rw-------, gitignorée)
Public key written to cosign.pub

$ cosign sign --yes --key cosign.key --tlog-upload=false localhost:5000/shopapi@sha256:0e322832…
Pushing signature to: localhost:5000/shopapi

$ cosign verify --key cosign.pub --insecure-ignore-tlog=true localhost:5000/shopapi:1.4.2 | jq
The following checks were performed on each of these signatures:
  - The cosign claims were validated
  - The signatures were verified against the specified public key
[{"critical": {"identity": {"docker-reference": "localhost:5000/shopapi"},
               "image": {"docker-manifest-digest": "sha256:0e322832db317fd07e57b36aef41cf23d5f13cae1611bdc0f659ca434add9756"},
               "type": "cosign container image signature"}, "optional": null}]

$ cosign attest --yes --key cosign.key --tlog-upload=false --type spdxjson --predicate sbom.json localhost:5000/shopapi@sha256:0e322832…
$ cosign verify-attestation --key cosign.pub --insecure-ignore-tlog=true --type spdxjson localhost:5000/shopapi:1.4.2 \
    | jq -r .payload | base64 -d | jq '{predicateType, subject, packages: (.predicate.packages|length)}'
{"predicateType":"https://spdx.dev/Document","subject":[{"name":"localhost:5000/shopapi","digest":{"sha256":"0e322832…"}}],"packages":340}
```

**Ce que la signature a créé dans le registre** :

```text
$ curl …/v2/_catalog
{"repositories":["demo-gc","shopapi"]}                        ← pas de nouveau dépôt
$ curl …/v2/shopapi/tags/list
{"tags":["1.4.2", …, "sha256-0e322832db317fd07e57b36aef41cf23d5f13cae1611bdc0f659ca434add9756.sig",
                     "sha256-0e322832db317fd07e57b36aef41cf23d5f13cae1611bdc0f659ca434add9756.att"]}
$ cosign tree localhost:5000/shopapi:1.4.2
└── 💾 Attestations for an image tag: localhost:5000/shopapi:sha256-0e322832….att
└── 🔐 Signatures for an image tag: localhost:5000/shopapi:sha256-0e322832….sig
$ crane manifest localhost:5000/shopapi:sha256-0e322832….sig | jq
{"mediaType": "application/vnd.oci.image.manifest.v1+json",
 "layers": [{"mediaType": "application/vnd.dev.cosign.simplesigning.v1+json",
             "annotations": {"dev.cosignproject.cosign/signature": "MEYCIQCmYSow4W+AEi2M…"}}]}
```

La signature est une **image OCI ordinaire**, rangée dans le même dépôt sous un tag dérivé du digest signé (`sha256:X` devient `sha256-X.sig`). Sa couche contient le *payload simplesigning* (le digest signé), et la signature elle-même est en annotation. L'attestation `.att` est une enveloppe DSSE in-toto qui contient le SBOM. Aucun registre « compatible cosign » n'est nécessaire.

### Re-push sous le même tag : la signature suit-elle le tag ou le digest ?

Je pousse la `1.4.2` **corrigée** (fix CVE ci-dessus) sous le même tag :

```text
$ docker push localhost:5000/shopapi:1.4.2
1.4.2: digest: sha256:4f902901f59ee8f4e8fb7c21681f070e658cb3da6c311d25b9b80ef5610e4e82

$ cosign verify --key cosign.pub --insecure-ignore-tlog=true localhost:5000/shopapi:1.4.2
Error: no signatures found
exit=10

$ cosign verify --key cosign.pub --insecure-ignore-tlog=true localhost:5000/shopapi@sha256:0e322832… | jq '.[0].critical.image'
{"docker-manifest-digest":"sha256:0e322832db317fd07e57b36aef41cf23d5f13cae1611bdc0f659ca434add9756"}
```

**La signature suit le digest**, jamais le tag. `cosign verify <tag>` résout d'abord le tag en digest, puis cherche `sha256-<ce digest>.sig`. Le tag pointe maintenant sur `4f90…`, qui n'a aucune signature. L'ancienne image reste signée (et vérifiable par digest), mais n'est plus accessible par son tag. C'est la protection voulue : une image réécrite sous un tag connu n'hérite pas de la confiance de l'ancienne. Il faut donc **toujours signer et déployer par digest** et ne jamais vérifier un tag puis tirer ce même tag (TOCTOU, voir `verified-run.sh`).

## 5. La porte de release

[`release-gate.sh IMAGE [--push REGISTRY_IMAGE]`](release-gate.sh) :

| Contrôle | Comment |
|---|---|
| Labels OCI `version`, `revision`, `source` | `docker image inspect` → `.Config.Labels` |
| Non-root | `.Config.User` vide, `root`, `0` ou `0:*` → refus |
| `HEALTHCHECK` | `.Config.Healthcheck.Test` absent ou `["NONE"]` → refus |
| Secret dans l'`ENV` | regex sur `.Config.Env` (`*PASSWORD*=`, `*TOKEN*=`, `scheme://user:pass@`…) |
| CVE HIGH/CRITICAL **corrigeable** | `trivy --scanners vuln --severity HIGH,CRITICAL --ignore-unfixed` |
| Secret dans les couches | `trivy --scanners secret --image-config-scanners secret --secret-config trivy-secret.yaml` |
| **Si tout passe et `--push`** | SBOM syft → `docker push` → **digest relu dans le registre** → `cosign sign` + `cosign attest` sur ce digest → `cosign verify` |

Tous les contrôles s'exécutent avant la décision : le rapport liste **toutes** les violations, pas seulement la première. Les rapports JSON sont écrits dans `.release/<image>/`. Codes de sortie : `0` publiée ou conforme, `1` politique violée, `2` erreur d'usage ou d'outillage. Le script passe shellcheck sans remarque.

```text
$ ./release-gate.sh shopapi:legacy --push localhost:5000/shopapi:legacy

== Metadata (shopapi:legacy)
  PASS label org.opencontainers.image.version=22.04
  FAIL label org.opencontainers.image.revision missing
  FAIL label org.opencontainers.image.source missing
  FAIL runs as root (User='')
  FAIL no HEALTHCHECK
  FAIL secret in image Env: DATABASE_URL=***

== Scans (trivy, from a docker save archive)
  FAIL 22 fixable HIGH/CRITICAL CVE(s):
         CRITICAL tar@6.2.1 -> 7.5.19 (CVE-2026-59873)
         HIGH brace-expansion@2.0.1 -> 1.1.18, 2.1.4, 3.0.6, 5.0.9 (CVE-2026-69152)
         HIGH cross-spawn@7.0.3 -> 7.0.5, 6.0.6 (CVE-2024-21538)
         ...
         ... see .release/shopapi_legacy/vulns.json
  FAIL 3 secret(s) found:
         CRITICAL aws-access-key-id in /app/.env
         CRITICAL connection-string-password in /app/.env
         CRITICAL connection-string-password in /app/Dockerfile

REJECTED shopapi:legacy: 7 policy violation(s). Reports in .release/shopapi_legacy/
exit=1
```

```text
$ ./release-gate.sh shopapi:1.4.2 --push localhost:5000/shopapi:1.4.2

== Metadata (shopapi:1.4.2)
  PASS label org.opencontainers.image.version=1.4.2
  PASS label org.opencontainers.image.revision=068ba9e
  PASS label org.opencontainers.image.source=https://git.shop-sas.example/platform/shopapi
  PASS non-root user (1000:1000)
  PASS HEALTHCHECK ["CMD","wget","-q","-O","/dev/null","http://127.0.0.1:3000/health"]
  PASS no secret in image Env

== Scans (trivy, from a docker save archive)
  PASS no fixable HIGH/CRITICAL CVE
  PASS no secret in layers

COMPLIANT shopapi:1.4.2

== Release to localhost:5000/shopapi:1.4.2
  PASS SBOM: 136 packages
  PASS pushed localhost:5000/shopapi@sha256:4f902901f59ee8f4e8fb7c21681f070e658cb3da6c311d25b9b80ef5610e4e82
  PASS signed
  PASS SBOM attestation attached
  PASS signature verified

RELEASED localhost:5000/shopapi@sha256:4f902901f59ee8f4e8fb7c21681f070e658cb3da6c311d25b9b80ef5610e4e82
exit=0
```

Le SBOM passe de 340 à 136 paquets : c'est npm et ses ~200 dépendances retirés du runtime.

Remarques :
- Le label `version=22.04` de legacy **passe**, alors qu'il est hérité d'Ubuntu et faux. Un contrôle plus strict comparerait `version` au tag poussé et `revision` au commit de la CI.
- La variante **distroless** est refusée : `libssl3 3.0.18` a 7 CVE HIGH/CRITICAL corrigées (log `16-gate-distroless.log`). `nodejs20-debian12` est en fin de vie et, contrairement à Alpine, **on ne peut pas la patcher soi-même** (pas d'`apt`). Le seul correctif est de changer d'image de base (`nodejs22-debian12`). C'est le revers de distroless.

---

## Bonus

### B1 — Scan continu : serveur trivy partagé

```text
$ trivy image --download-db-only                  # une fois, dans le volume shop-trivy-cache
$ docker run -d --name trivy-server -p 127.0.0.1:4954:4954 -v shop-trivy-cache:/root/.cache/trivy \
    aquasec/trivy:0.76.1 server --listen 0.0.0.0:4954 --token "$TRIVY_TOKEN"

$ time trivy image --server http://127.0.0.1:4954 --token … --scanners vuln --severity HIGH,CRITICAL --ignore-unfixed --input .scan/shopapi_legacy.tar
"legacy: 22 CVE"         real 0m0,747s
$ time trivy image --server … --input .scan/shopapi_1.4.2.tar
"1.4.2: 0 CVE"           real 0m0,271s
$ … --token wrong
unauthenticated
```

En mode client/serveur, le **client** analyse l'image (liste des paquets, secrets) et envoie l'inventaire au **serveur**, qui détient la base de vulnérabilités (1,5 Go décompressée ici, republiée toutes les 6 h) et fait la correspondance. La base n'est téléchargée qu'une fois pour toute l'équipe et les runners, les clients sont légers, et le serveur garde en cache l'analyse des couches déjà vues (d'où les temps inférieurs à la seconde). C'est la brique du **scan continu** : un job planifié (cron) rescanne chaque nuit les images *déployées* (`kubectl get pods -o jsonpath='{..image}'`) contre la base du jour, et alerte quand une CVE apparaît sur une image qui était saine à son build. Harbor fait exactement cela en interne.

### B2 — Signature keyless (Fulcio / Rekor)

Non réalisée, volontairement : elle exige une authentification OIDC interactive (navigateur) et **publie** l'entrée dans le journal public Rekor. Je ne voulais pas exposer publiquement une image interne du TP.

Principe : `cosign sign <img@digest>` sans `--key` ouvre un flux OIDC (GitHub, Google, ou le token OIDC du runner GitHub Actions). **Fulcio** émet un certificat X.509 valable **10 minutes** qui lie une clé éphémère à l'identité (`user@example.com`, ou `https://github.com/org/repo/.github/workflows/release.yml@refs/tags/v1.4.2`). L'image est signée, l'entrée est horodatée dans **Rekor**, puis la clé est jetée. Vérification : `cosign verify --certificate-identity=… --certificate-oidc-issuer=https://token.actions.githubusercontent.com img`.

| | Clé (`cosign.key`) | Keyless |
|---|---|---|
| Secret à protéger | clé privée longue durée (fuite = tout est signable jusqu'à révocation) | aucun : clé éphémère, identité = OIDC |
| Rotation et révocation | à organiser soi-même | inutile (certificats de 10 min) |
| Ce qu'on vérifie | « signé par la clé X » | « signé par **ce workflow de ce dépôt** » : plus expressif |
| Preuve temporelle | aucune par défaut | horodatage Rekor : prouve que la signature date de la validité du certificat |
| Hors ligne / air-gap | ✅ | ❌ (Fulcio et Rekor, ou une instance Sigstore privée) |
| Confidentialité | rien de public | identité et digest **publiés** dans Rekor (public par défaut) |
| Dépendances | aucune | infrastructure Sigstore (publique ou auto-hébergée) |

En entreprise : keyless en CI publique et open source, clé dans un **KMS/HSM** (`--key awskms://…`, `gcpkms://`, `hashivault://`) ou instance Sigstore privée pour l'interne.

### B3 — Policy as code : `verified-run.sh`

[`verified-run.sh [options docker run] IMAGE [cmd…]`](verified-run.sh) résout l'image en **digest** dans le registre, vérifie la signature cosign de **ce digest**, puis lance `docker run` **sur le digest** et non sur le tag. Ainsi, un re-push entre la vérification et le lancement est sans effet.

```text
$ ./verified-run.sh --rm localhost:5000/shopapi:1.4.2 node -e "console.log(process.env.APP_VERSION)"
verified-run: signature OK for localhost:5000/shopapi@sha256:4f902901f59ee8f4e8fb7c21681f070e658cb3da6c311d25b9b80ef5610e4e82
1.4.2
exit=0

$ ./verified-run.sh --rm localhost:5000/shopapi:sha-d4a6b19 id               # build de branche jamais signé
verified-run: REFUSED localhost:5000/shopapi:sha-d4a6b19 (sha256:a4b89d0f…): no valid Shop SAS signature
exit=126

$ ./verified-run.sh --rm localhost:5000/shopapi:1.4.2-distroless             # refusée par la porte, donc jamais signée
verified-run: REFUSED localhost:5000/shopapi:1.4.2-distroless (sha256:109b1b26…): no valid Shop SAS signature
exit=126
```

C'est contournable (il suffit d'appeler `docker run` directement). La vraie application de la politique se fait au niveau de l'orchestrateur : admission controller **Kyverno** (`verifyImages`) ou **Sigstore policy-controller** sur Kubernetes, *Binary Authorization* sur GKE, ou un plugin d'autorisation dockerd.

### B4 — Scanner le SBOM plutôt que l'image

```text
$ trivy sbom --severity HIGH,CRITICAL --ignore-unfixed sbom.json             # SBOM de l'ANCIENNE 1.4.2
22 CVE HIGH/CRITICAL, ex: brace-expansion@2.0.1 CVE-2026-102276, …

# SBOM récupéré depuis l'attestation signée de la nouvelle release
$ cosign verify-attestation --key cosign.pub --insecure-ignore-tlog=true --type spdxjson localhost:5000/shopapi:1.4.2 \
    | jq -r .payload | base64 -d | jq .predicate > sbom-from-registry.json
$ trivy sbom --severity HIGH,CRITICAL --ignore-unfixed sbom-from-registry.json
0
```

**Intérêt pour une CVE publiée 6 mois après le build** : le SBOM est l'inventaire figé de ce qui a été livré. Quand une CVE sort (Log4Shell, xz…), il suffit de **rescanner les SBOM** de toutes les releases (quelques Ko de JSON chacune, et le scan prend une fraction de seconde) contre la base du jour. Pas besoin de retrouver, tirer et décompresser des centaines d'images de plusieurs centaines de Mo, qui ont parfois été purgées du registre entre-temps. Quand le SBOM est **attesté** (signé et attaché au digest), on sait aussi qu'il décrit bien l'image déployée et qu'il n'a pas été modifié. On peut même répondre « sommes-nous touchés ? » avec un simple `jq` sur un nom de paquet et sa version, sans scanner du tout (Dependency-Track, GUAC).
