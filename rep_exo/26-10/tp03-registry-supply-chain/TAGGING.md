# Politique de tags des images Shop SAS

S'applique à tout dépôt de `registry.local:5000`. Seule la CI (compte `ci`) pousse. Les humains (`dev`) ne font que tirer.

## 1. Tags produits

| Tag | Exemple | Produit par | Mutable ? | Usage |
|---|---|---|---|---|
| `X.Y.Z` (semver complet) | `1.4.2` | pipeline de release, **après la porte** (`release-gate.sh`) | **Non, jamais** | prod, staging, rollback |
| `X.Y.Z-<variante>` | `1.4.2-distroless` | idem | **Non** | variante d'une release |
| `X.Y.Z-rc.N` | `1.5.0-rc.1` | pipeline de release candidate | **Non** | recette |
| `sha-<git-sha court>` | `sha-068ba9e` | chaque build de `main` | Non (un commit donne un contenu) | traçabilité, promotion |
| `X.Y` / `X` | `1.4`, `1` | release, pointe sur le dernier patch | **Oui** (flottant) | dev, docs, `FROM` interne toléré hors prod |
| `main` / `<branche>` | `main` | chaque build de branche | **Oui** | environnements éphémères |
| `sha256-<digest>.sig` / `.att` | | cosign | géré par cosign | signature et attestation (ne pas toucher) |
| `latest` | | — | — | **interdit** (voir §3) |

Règles :

- **Promotion, pas reconstruction** : une release ne se reconstruit pas. On retague le build `sha-<commit>` validé (`crane tag` / `skopeo copy`) après le passage de la porte. Le digest de la release est donc *exactement* celui qui a été testé.
- **Labels OCI** obligatoires (`version`, `revision`, `source`) : la porte refuse une image sans eux. Le tag est un pointeur ; les labels, eux, sont dans l'image et la décrivent.
- **Rétention** ([`retention.sh`](retention.sh)) : les tags semver et les artefacts cosign ne sont jamais supprimés. On garde les *N* tags non-semver les plus récents par dépôt (N = 10 sur `main`). Un digest encore référencé par un tag protégé n'est jamais supprimé.

## 2. Tags immuables : pourquoi et comment

Un tag de release qui change de contenu casse trois garanties :

1. **Reproductibilité du déploiement** : `1.4.2` déployé lundi et `1.4.2` redéployé vendredi ne sont plus la même chose (l'incident du vendredi soir).
2. **Rollback** : revenir à `1.4.1` doit redonner *le même binaire*.
3. **Signature et audit** : la signature cosign porte sur un **digest**. Si le tag bouge, `cosign verify <tag>` échoue (`no signatures found`, démontré au TP03 §4), ou pire, vérifie une autre image si quelqu'un l'a signée.

Mise en œuvre :

- `registry:2` (distribution) **ne sait pas** rendre un tag immuable. Ici, on s'appuie sur le fait que seul `ci` peut pousser (nginx), et sur une CI qui refuse de pousser un tag semver existant :

  ```bash
  crane digest registry.local:5000/shopapi:1.4.2 >/dev/null 2>&1 && { echo "1.4.2 existe déjà : immuable"; exit 1; }
  ```

- En entreprise, on utilise les règles d'immuabilité du registre : Harbor (*tag immutability rules*), ECR (`imageTagMutability=IMMUTABLE`), ACR (`az acr repository update --write-enabled false`), Artifactory, GAR.
- Un correctif donne **toujours** un nouveau patch (`1.4.3`), jamais un re-push de `1.4.2`.

## 3. Pourquoi `latest` est interdit en prod

- **Ce n'est pas « la dernière version »** : c'est le tag par défaut quand on n'en précise pas. C'est le dernier build poussé *sans tag*, éventuellement depuis une branche, un poste de dev ou un vieux pipeline.
- **Non déterministe** : deux nœuds qui tirent `latest` à 10 minutes d'écart peuvent exécuter deux versions différentes. Un redémarrage de pod peut mettre à jour la prod sans déploiement.
- **Pas de rollback** : vers quoi revenir ? `latest` d'hier n'existe plus.
- **Cache trompeur** : avec `imagePullPolicy: IfNotPresent`, un nœud garde un vieux `latest` pendant que les autres prennent le nouveau.
- **Illisible** : `docker ps` et les alertes affichent `shopapi:latest`, sans aucun moyen de savoir quel commit tourne.

On ne pousse donc pas de `latest` dans le registre d'entreprise. Les `FROM` et `image:` de prod utilisent un **semver + digest**.

## 4. Référencer une image par digest dans Compose

```yaml
services:
  shopapi:
    # Tag conservé pour la lisibilité, ignoré par le moteur dès qu'un digest est présent.
    image: registry.local:5000/shopapi:1.4.2@sha256:4f902901f59ee8f4e8fb7c21681f070e658cb3da6c311d25b9b80ef5610e4e82
```

Testé avec [`compose.prod.example.yml`](compose.prod.example.yml) :

```text
$ docker compose -f compose.prod.example.yml up -d && docker compose ps
localhost:5000/shopapi:1.4.2@sha256:4f902901f59ee8f4e8fb7c21681f070e658cb3da6c311d25b9b80ef5610e4e82  Up 4 seconds (healthy)
```

Pour obtenir le digest :

```bash
crane digest registry.local:5000/shopapi:1.4.2
# ou, sans outil, via l'API (cf. tp03 §2) :
curl -sI -u dev:… -H "Accept: application/vnd.oci.image.index.v1+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.docker.distribution.manifest.v2+json" \
  https://registry.local:5000/v2/shopapi/manifests/1.4.2 | grep -i docker-content-digest
```

Le digest d'une image **multi-arch** est celui de l'*index* (manifest list). Le moteur choisit ensuite la bonne plateforme.

Les mises à jour des digests épinglés sont automatisées par Renovate ou Dependabot (`pinDigests: true`), qui ouvrent une PR à chaque nouveau patch.

## 5. Retaguer sans pull

```bash
# skopeo (installé sur l'hôte), copie registre → registre sans passer par le daemon
skopeo copy --preserve-digests --src-cert-dir registry/trust --dest-cert-dir registry/trust \
  docker://registry.local:5000/shopapi:sha-068ba9e docker://registry.local:5000/shopapi:1.4.2

# crane (en conteneur, cf. tools.sh) : une simple écriture de manifeste, aucun blob transféré
crane tag registry.local:5000/shopapi:1.4.2 1.4
```
