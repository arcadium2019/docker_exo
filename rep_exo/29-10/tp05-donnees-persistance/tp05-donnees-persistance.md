# TP05 — Données : persistance, sauvegarde, restauration, montée de version

Livrables : `backup.sh`, `restore.sh`, `upgrade-pg.sh` (+ `checksum.sh`, `compose.pg16.yml`), `compose.backup.yml`.
Les transcripts complets sont dans `logs/`. `compose.yml` et `seed.sh` sont ceux du starter (base legacy PG14, projet `shopdata`).

## 1. Anatomie du stockage

La stack du TP04 tourne (`logs/01-anatomie.txt`).

```
$ docker inspect shop-db-1 --format '{{json .Mounts}}' | jq -c '.[]'
{"Type":"bind","Source":".../tp04-compose-entreprise/db/init.sql","Destination":"/docker-entrypoint-initdb.d/init.sql","RW":false}
{"Type":"bind","Source":".../tp04-compose-entreprise/secrets/db_password.txt","Destination":"/run/secrets/db_password","RW":false}
{"Type":"volume","Name":"shop_pgdata","Source":"/var/lib/docker/volumes/shop_pgdata/_data","Destination":"/var/lib/postgresql/data","RW":true}
$ docker volume inspect shop_pgdata  → Driver local, Mountpoint /var/lib/docker/volumes/shop_pgdata/_data, labels com.docker.compose.project=shop
$ docker system df -v
shop_pgdata      1   48.07MB
shop_redisdata   1   1.222kB
```

**Couche inscriptible et volume** : le conteneur écrit dans sa couche overlay2 (`UpperDir` sous `/var/lib/docker/overlay2/<id>/diff`), qui disparaît au `docker rm`. Les fichiers de la base, eux, vont dans le volume (`/var/lib/docker/volumes/shop_pgdata/_data`), qui ne passe pas par overlay2.

```
$ docker exec shop-db-1 touch /tmp/x && docker diff shop-db-1
A /tmp/x                       ← couche inscriptible du conteneur
A /run/postgresql/.s.PGSQL.5432
...                            ← aucune entrée sous /var/lib/postgresql/data : c'est le volume
```

**Cycle de vie de `pgdata`** : testé sur une copie (projet `shopcopy`, `logs/02-cycle-de-vie.txt`). Un produit marqueur est inséré avant les tests.

| Commande | Volume | Données |
|----------|--------|---------|
| `docker compose down` | conservé | conservées (4 produits après redémarrage) |
| `docker compose rm -sf db` | conservé | conservées |
| `docker volume prune` | **conservé** : depuis Docker 23, `prune` ne supprime que les volumes **anonymes** | conservées |
| `docker volume prune -a` | **supprimé** (s'il n'est pas utilisé par un conteneur) | perdues : base neuve, `init.sql` rejoué (3 produits) |
| `docker compose down -v` | **supprimé** | perdues : c'est l'incident de la préprod |

Le `prune` a été limité à la copie avec `--filter label=com.docker.compose.project=shopcopy`. Un `docker volume prune -a` sans filtre aurait effacé les volumes inutilisés de **tous** les projets du poste.

**Volume anonyme** (`logs/03-volume-anonyme.txt`) : l'image `postgres` déclare `VOLUME /var/lib/postgresql/data`, donc un `docker run` sans `-v` crée un volume au nom aléatoire (`173ba45c…`).

- `docker rm` : le volume reste, orphelin, sans nom lisible et sans label de projet. On ne sait plus à quoi il correspond, et il finit soit par saturer le disque, soit effacé par un `prune`.
- `docker rm -v` : il est supprimé avec le conteneur.

C'est un piège classique : on croit avoir une base « jetable » alors qu'elle s'accumule, et on croit avoir une base persistante alors que le prochain `rm -v` ou `prune` l'efface.

**Bind mount, volume nommé ou tmpfs** :

- **Bind mount** : pour du code source en dev ou une config versionnée en lecture seule (`init.sql`, nginx). Il dépend du chemin de l'hôte, des UID et de SELinux.
- **Volume nommé** : pour les données d'un service (PG, Redis). Il est géré par Docker, porte les bons droits et a des performances natives sur Linux.
- **tmpfs** : pour des fichiers temporaires, des secrets ou un `/tmp` avec un rootfs `read_only`. Il est en RAM et disparaît à l'arrêt.
- **Docker Desktop (macOS/Windows)** : les bind mounts traversent la frontière VM ↔ hôte (virtiofs/gRPC FUSE) et peuvent être 3 à 10 fois plus lents sur beaucoup de petits fichiers (`node_modules`). Les volumes nommés vivent dans la VM Linux et gardent une vitesse native.

**`init.sql` n'est pas rejoué** : l'entrypoint ne lance `/docker-entrypoint-initdb.d/*` que si `PGDATA` est vide. Au redémarrage, le volume contient déjà une base (« Database directory appears to contain a database; Skipping initialization »). Pour forcer une réinitialisation, on supprime le volume (`down -v`, après sauvegarde !) ou on rejoue le script à la main avec `psql -f`.

## 2. Sauvegarde et restauration

- `backup.sh` : `pg_dump -Fc` horodaté via `docker compose exec`, sans client sur l'hôte. Avec `RAW=1`, il fait aussi un `tar` du volume via `alpine` (`-v vol:/data:ro`), écrit sur stdout pour que l'archive appartienne à l'utilisateur et pas à root. La rétention garde les `KEEP=7` dernières sauvegardes de chaque type.
- `restore.sh [dump]` : `pg_restore --clean --if-exists` du dernier dump ou de celui passé en argument.

**Sauvegarde brute incohérente** : copier les fichiers d'un PG **en marche** mélange des pages écrites à des instants différents, avec un WAL non synchronisé. On obtient alors une base corrompue ou qui demande une récupération. Il y a deux façons de la rendre cohérente :

- **À froid** : `backup.sh` arrête `db`, fait le `tar`, puis redémarre `db`. C'est simple mais crée une coupure.
- **À chaud** : `SELECT pg_backup_start('label')`, copie, puis `pg_backup_stop()`, en archivant les WAL produits pendant la copie. C'est ce que fait `pg_basebackup`.

Transcript (`logs/04-restauration.txt`) :

```
$ ./seed.sh
 orders |             checksum
 100000 | 19aea9c9d99552d2ad3ba1721b66a48e
$ RAW=1 ./backup.sh
logical dump: ./backups/shop-20261030-100945.dump (1,6M)
raw backup:   ./backups/shopdata_pgdata-20261030-100945.tar.gz (13M)
$ docker compose down -v
 Volume shopdata_pgdata Removed
$ docker compose up -d --wait   → tables publiques: 0
$ ./restore.sh
restoring ./backups/shop-20261030-100945.dump
restore done
$ ./checksum.sh
100000 19aea9c9d99552d2ad3ba1721b66a48e      ← identique
```

Rétention vérifiée avec `KEEP=2` et 3 exécutions : il reste 2 dumps (`logs/05-retention.txt`).

**Sidecar planifié** (`compose.backup.yml`, ajouté à la stack du TP04, `logs/08-sidecar.txt`) : `prodrigestivill/postgres-backup-local:16` lit le mot de passe via `POSTGRES_PASSWORD_FILE` (le même secret que le TP04), se place sur le réseau `back` et écrit dans le volume `shop_backups`.

```
$ docker run --rm -v shop_backups:/b:ro alpine ls /b/last
shop-20261030-091241.sql.gz  shop-20261030-091341.sql.gz  shop-20261030-091441.sql.gz  shop-20261030-091541.sql.gz
shop-latest.sql.gz -> shop-20261030-091541.sql.gz
```

Un dump est bien produit chaque minute. Piège rencontré : le `HEALTHCHECK` de l'image a un intervalle de **5 min** sans `start_interval`, donc `up --wait` restait bloqué 5 min en `starting`. Je l'ai corrigé dans le compose (`interval: 1m`, `start_interval: 2s`).

## 3. Montée de version PostgreSQL 14 → 16

**Changer simplement le tag** (`logs/06-tag-16-naif.txt`) :

```
FATAL:  database files are incompatible with server
DETAIL:  The data directory was initialized by PostgreSQL version 14, which is not compatible with this version 16.4.
```

Le format des fichiers sur disque (catalogue système, pages) change à chaque version majeure. PG16 refuse d'ouvrir un `PGDATA` de PG14. Il faut passer par un export logique (`dump` puis `restore`) ou par `pg_upgrade`.

`upgrade-pg.sh` (`logs/07-montee-version.txt`) :

```
== 1. checksum before      postgres (PostgreSQL) 14.13
100000 19aea9c9d99552d2ad3ba1721b66a48e
== 2. dumps                upgrade-…-all.sql (5,0M, pg_dumpall)  upgrade-…-shop.dump (1,6M, pg_dump -Fc)
== 3. stop PG14 (volume kept)
== 4. PG16 on a new volume  Volume shopdata_pgdata16 Created   postgres (PostgreSQL) 16.4
== 5. restore
== 6. checksum after
100000 19aea9c9d99552d2ad3ba1721b66a48e
VERDICT: OK, no data loss          (real 0m12,980s)
```

**Retour arrière** : `docker compose -f compose.yml up -d --wait db`. Le service repart en PG14 sur `shopdata_pgdata`, qui n'a jamais été modifié. C'est vérifié : on retrouve PG 14.13 et le même checksum. Une fois PG16 validé, on supprime l'ancien volume.

**Questions** :

- **`pg_dumpall` / `pg_dump`** : `pg_dumpall` exporte **toute l'instance** en SQL, y compris les objets globaux (rôles, mots de passe, tablespaces). Il ne produit que du texte et ne permet pas de restauration sélective. `pg_dump` exporte **une seule base**, au format custom (`-Fc`) compressé, et permet un `pg_restore` sélectif ou parallèle (`-j`). On garde donc les deux : `pg_dumpall --globals-only` pour les rôles et `pg_dump -Fc` par base.
- **Nouveau volume** : l'ancien reste intact, ce qui donne un retour arrière immédiat. En écrasant l'ancien volume, une restauration ratée ferait tout perdre, avec le dump comme seul filet.
- **Réduire l'indisponibilité** : la coupure dure ici de l'arrêt PG14 jusqu'à la fin de la restauration, soit environ 10 s pour 100 000 lignes, mais elle croît avec la taille de la base. Pour la réduire :
  - `pg_upgrade --link` (image `tianon/postgres-upgrade:14-to-16`, qui contient les deux binaires) crée des hard links au lieu de copier : quelques secondes, quelle que soit la taille, mais pas de retour arrière une fois PG16 démarré ;
  - la **réplication logique** (publication sur PG14, souscription sur PG16, puis bascule) ramène la coupure à quelques secondes.

## 4. Redis

- **`--save 60 1` (RDB)** : un snapshot est pris toutes les 60 s s'il y a eu au moins une écriture. En cas de crash, on perd **jusqu'à environ 60 s** d'écritures (plus la durée du snapshot en cours).
- **`--appendonly yes` (AOF)** : chaque écriture est journalisée, avec `appendfsync everysec` par défaut. On perd **au plus environ 1 s**.

Dans la stack, Redis contient le **cache** `products` (TTL 30 s, reconstructible depuis PG, sa perte n'a aucune importance) et la **file** `orders:queue`. Une commande dans la file est déjà insérée en base en `pending`, mais si le message est perdu, le worker ne la confirme jamais. La file justifie donc l'**AOF** (`--appendonly yes`, en place dans le TP04 avec le volume `redisdata`). Pour le seul cache, `--save ""` (aucune persistance) suffirait.
