# TP08 — Durcir les conteneurs pour la production

Livrables :

- `audit.sh` ;
- `compose.hardened.yml` (surcharge de la stack TP04, commentée directive par directive) ;
- `daemon.json` ;
- les sorties dans `logs/`.

Commande :

```bash
cd ../../29-10/tp04-compose-entreprise
docker compose -f compose.yml -f ../../30-10/tp08-hardening/compose.hardened.yml up -d --wait
```

## 1. Mesurer

`audit.sh [projet]` affiche, pour chaque conteneur en cours d'exécution :

- l'utilisateur ;
- `Privileged` ;
- les capabilities ajoutées et retirées ;
- le rootfs en lecture seule ;
- la limite mémoire ;
- `PidsLimit` ;
- `no-new-privileges` ;
- le montage de la socket Docker.

Il sort avec le code 1 s'il y a au moins un écart. `AUDIT_SOCKET_OK="nom"` autorise explicitement un conteneur à monter la socket (le proxy de socket).

**Avant** (stack TP04 `compose.yml` + `compose.prod.yml`, `logs/01-audit-avant.txt`) : **19 écarts**.

```
shop-api-1      1000:1000    … no-pids-limit
shop-api-2      1000:1000    … no-pids-limit
shop-traefik-1  root         … root,no-cap-drop-all,rootfs-rw,no-pids-limit,no-nnp,docker-socket
shop-worker-1   10001:10001  … no-pids-limit
shop-redis-1    root         … root,no-cap-drop-all,rootfs-rw,no-pids-limit,no-nnp
shop-db-1       root         … root,no-cap-drop-all,rootfs-rw,no-pids-limit,no-nnp
total deviations: 19
```

**docker-bench-security** (`logs/02-docker-bench.txt`) : **Checks: 105, Score: 12**.

L'image `docker/docker-bench-security` embarque un client Docker 18.06 (API 1.38), refusé par Docker 29 (« client version 1.38 is too old ») : le premier lancement ne vérifie rien. Il faut forcer `-e DOCKER_API_VERSION=1.40`.

Les 5 `WARN` que je juge prioritaires :

| WARN | Pourquoi c'est prioritaire |
|------|----------------------------|
| 5.31 Docker socket mounted inside containers | La socket donne root sur l'hôte : un Traefik compromis peut lancer un conteneur `--privileged -v /:/host`. |
| 4.1 / 5.x containers running as root | Une évasion du conteneur arrive en root, et un volume monté est modifiable en root. |
| 5.25 / 2.18 no-new-privileges | Les binaires setuid restent des tremplins d'élévation (voir l'expérience ci-dessous). |
| 5.28 PIDs cgroup limit / limites mémoire | Une fork bomb ou une fuite mémoire dans un seul conteneur fait tomber tout l'hôte. |
| 2.8 user namespace support | Sans userns-remap, root dans le conteneur est root (uid 0) sur l'hôte. |

À noter aussi : 2.1 (`icc` sur le bridge par défaut), 2.14 (`live-restore`) et 5.12 (rootfs en lecture-écriture). Les sections 1.x (partition dédiée, auditd) relèvent de l'administration de l'hôte : sans sudo, elles sont hors de portée ici.

## 2. Comprendre chaque mesure

Expériences sur des conteneurs alpine jetables (`logs/03-experiences.txt`) :

| Mesure | Expérience | Résultat observé |
|--------|-----------|------------------|
| `--read-only` | `touch /x`, puis `--tmpfs /tmp` et `touch /tmp/x` | `Read-only file system`, puis OK dans le tmpfs. |
| `--cap-drop ALL` | `ping 1.1.1.1` | **Réussit quand même**. Docker règle `net.ipv4.ping_group_range` : ping utilise un socket ICMP « datagramme » non privilégié, sans `NET_RAW`. Il n'y a rien à réajouter. |
| | `chown 1000 /etc/hostname` | `Operation not permitted`, puis OK avec `--cap-add CHOWN`. |
| | `apk add curl` | **Réussit sans aucune capability**. root reste propriétaire des fichiers qu'il écrit, et le contrôle d'accès (DAC) le laisse écrire chez lui. Les capabilities ne servent qu'à franchir les droits d'**autres** utilisateurs (`DAC_OVERRIDE`, `CHOWN`, `FOWNER`). Conclusion : `cap_drop` ne remplace pas `read_only` ni un utilisateur non-root. |
| `no-new-privileges` | Le busybox d'alpine 3.20 n'est pas setuid (`su: must be suid`), l'expérience de l'énoncé ne prouve donc rien. J'ai refait l'essai avec une copie setuid de `id`. | `--user 1000` → `uid=1000 euid=0(root)` (élévation). Avec `no-new-privileges` → `uid=1000` (bit setuid ignoré). |
| `--pids-limit 50` | Lancer 100 `sleep &` | `can't fork: Resource temporarily unavailable`. |
| `--memory 32m` | `python -c "x='a'*100_000_000"` | `OOMKilled=true`, `ExitCode=137`. |
| `--user 1000` | `id` | `uid=1000 gid=0(root)` : le groupe reste root si on ne précise pas `1000:1000`. |
| | Un volume créé par root, puis écriture en `--user 1000` | `Permission denied` : le volume garde les droits de son premier écrivain. Il faut le préparer (chown dans l'image avant `VOLUME`) ou utiliser le même uid partout. |
| seccomp | `unshare --user id` | Par défaut : `Operation not permitted`. Avec `seccomp=unconfined` : OK, on crée un user namespace. |

**Combien de syscalls le profil par défaut bloque-t-il ?** C'est une **liste blanche** (`defaultAction: SCMP_ACT_ERRNO`). Le profil `moby/profiles` autorise 363 noms sans condition, et 426 avec les conditionnels (capability, architecture). Ces listes couvrent toutes les architectures. Sur x86_64, la documentation Docker parle d'**environ 44 syscalls bloqués sur plus de 300**, dont : `bpf`, `clone`/`clone3` avec un nouveau namespace, `mount`/`fsopen`/`fsmount`, `kexec_load`, `init_module`, `reboot`, `unshare`, `keyctl`, `ptrace` (sur les noyaux anciens). La plupart redeviennent autorisés si on ajoute `CAP_SYS_ADMIN`, c'est pourquoi il ne faut jamais l'ajouter.

## 3. Durcir la stack

`compose.hardened.yml`. Une ancre `x-hardening` s'applique à tous les services :

- `read_only` : impossible d'écrire un binaire ou de persister dans le rootfs ;
- `cap_drop: [ALL]` : root sans privilèges noyau ;
- `no-new-privileges` : plus d'élévation par setuid ;
- `pids_limit: 200` : une fork bomb reste confinée.

S'y ajoutent des limites CPU et mémoire par service, et des `tmpfs` ciblés (`/tmp`, `/run`, `/var/run/postgresql`).

| Service | Mesures spécifiques |
|---------|---------------------|
| **traefik** | `user: 65534` (nobody). **Aucune capability** pour le port 80, parce que Docker règle `net.ipv4.ip_unprivileged_port_start=0` dans le conteneur (vérifié). La socket est **retirée** (`volumes: !reset []`) au profit de `--providers.docker.endpoint=tcp://socket-proxy:2375`. |
| **socket-proxy** | `tecnativa/docker-socket-proxy:v0.4.2` (la `v0.3.0` n'existe pas sur le Hub). Il n'autorise que les GET `CONTAINERS`, `NETWORKS`, `EVENTS` et `VERSION`, avec `POST=0`. Il est seul sur le réseau `socket` en `internal: true`. Il tourne en `nobody:docker` (gid 975 de l'hôte, variable `DOCKER_GID`), avec un tmpfs `/run` appartenant à 65534 pour le pidfile haproxy (premier essai : `Cannot create pidfile /run/haproxy.pid`). |
| **db** | Voir les essais ci-dessous. Il tourne finalement **en `user: 70:70`, sans aucune capability**. |
| **redis** | `user: 999:1000` (utilisateur `redis` de l'image). Le volume `/data` lui appartient déjà, donc aucune capability n'est nécessaire. |
| **api / worker** | Ils étaient déjà non-root (TP01/TP02) ; ajout de `pids_limit` et de `tmpfs /tmp`. |

**Essais et erreurs pour PostgreSQL** (`logs/04-essais-caps.txt`), lancé en root comme l'image par défaut :

| Essai | `cap_add` | Erreur dans les logs |
|-------|-----------|----------------------|
| 1 | aucune | `find: /var/lib/postgresql/data: Permission denied` et `chmod: Operation not permitted` (root n'a plus le droit d'entrer dans un dossier 700 appartenant à l'uid 70) |
| 2 | `DAC_OVERRIDE, FOWNER` | `chown: /var/run/postgresql: Operation not permitted` |
| 3 | + `CHOWN` | `error: failed switching to "postgres": operation not permitted` (gosu) |
| 4 | + `SETUID, SETGID` | ✅ healthy |

Il faut donc **5 capabilities** en root, uniquement pour que l'entrypoint corrige les droits puis passe à l'utilisateur `postgres`. **Essai 5** : `user: "70:70"` (le propriétaire du volume) et un tmpfs `/var/run/postgresql:uid=70,gid=70`. L'entrypoint saute alors toute cette étape : healthy, **avec zéro capability**.

Pour Traefik, la question ne se pose plus : il ne demandait des privilèges que pour le port 80 (`NET_BIND_SERVICE`), que Docker rend inutiles.

**Validation** (`logs/05-audit-apres.txt`) :

```
$ docker compose -f compose.yml -f …/compose.hardened.yml up -d --wait   → tout healthy
$ ./smoke-test.sh                                                         → OK: smoke test passed
$ ./audit.sh shop
shop-socket-proxy-1  65534:975    … y 64M  200 y YES  docker-socket
shop-db-1            70:70        … y 512M 200 y no   OK
shop-traefik-1       65534:65534  … y 128M 200 y no   OK
shop-api-1           1000:1000    … y 256M 200 y no   OK
shop-worker-1        10001:10001  … y 128M 200 y no   OK
shop-redis-1         999:1000     … y 128M 200 y no   OK
total deviations: 1        ← le proxy, dont c'est le rôle
$ AUDIT_SOCKET_OK=shop-socket-proxy-1 ./audit.sh shop
total deviations: 0
```

On passe de 19 écarts à **0 sur les services applicatifs**. La seule exception, assumée, est le proxy, qui monte la socket en lecture seule et ne la ré-expose qu'en GET.

Preuves que le proxy filtre (`logs/06-socket-proxy.txt`) : `GET /containers/json` → 200, `POST /containers/create` (conteneur privilégié) → **403**, `GET /images/json` → 403, port 2375 non publié sur l'hôte.

## 4. Côté daemon

`daemon.json` est proposé mais **pas appliqué** (pas de sudo sur le poste, et cela redémarrerait dockerd pour tous les projets).

| Clé | Effet |
|-----|-------|
| `no-new-privileges: true` | `no-new-privileges` par défaut pour tous les conteneurs (CIS 2.18). |
| `icc: false` | Plus de trafic entre conteneurs sur le **bridge par défaut** (CIS 2.1). |
| `live-restore: true` | Les conteneurs continuent de tourner pendant un redémarrage ou une mise à jour de dockerd (CIS 2.14). |
| `userland-proxy: false` | La publication de ports passe par iptables/nft au lieu d'un processus `docker-proxy` par port (CIS 2.15). |
| `log-driver` + `log-opts` | Rotation des logs par défaut, même pour un `docker run` oublié. |
| `userns-remap: default` | Root dans le conteneur devient un uid non privilégié de l'hôte (100000+), via l'utilisateur `dockremap` (CIS 2.8). |

**Effets de bord** :

- **`icc: false`** : il ne concerne que le réseau `bridge` **par défaut** (docker0). Notre stack n'utilise que des réseaux utilisateur (`shop_front`, `shop_back`, `shop_socket`), elle n'est donc **pas affectée**. Seuls les `docker run` sans `--network`, ou les anciens `--link`, ne se parleraient plus. Pour un réseau utilisateur, l'équivalent est `com.docker.network.bridge.enable_icc=false` par réseau.
- **`userns-remap`** :
  - Docker utilise un **nouveau `data-root`** (`/var/lib/docker/100000.100000/`) : les images, conteneurs et volumes existants « disparaissent » (ils restent dans l'ancien dossier) ;
  - les volumes migrés à la main appartiennent à uid 0/70/999 de l'hôte, alors que le conteneur les voit maintenant décalés de 100000 : il faut un `chown -R` avec le décalage (par exemple 100070 pour `pgdata`) ;
  - les bind mounts du dépôt (`init.sql`, secrets) doivent être lisibles par l'uid 100000+ ;
  - `--privileged` et `--userns=host` deviennent des exceptions explicites ;
  - certaines images qui font des `chown` au démarrage échouent sur les bind mounts.
- **Alternative : Docker rootless.** Le démon lui-même tourne sans root, ce qui protège même en cas de bug du démon. En contrepartie : pas de ports < 1024 sans `sysctl ip_unprivileged_port_start`, réseau via slirp4netns/pasta plus lent, cAdvisor et certains cgroups limités, et `--memory`/`--cpus` qui exigent cgroup v2 avec délégation.
