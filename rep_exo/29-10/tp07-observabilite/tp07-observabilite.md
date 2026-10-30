# TP07 — Observabilité : logs, métriques, alertes

Livrables :

- `compose.observability.yml` ;
- `prometheus/prometheus.yml` et `prometheus/alerts.yml` ;
- `promtail/config.yml` ;
- `grafana/provisioning/*` et `grafana/dashboards/shop.json` ;
- `load.sh` ;
- les captures dans `captures/`.

Les sorties brutes sont dans `logs/`. Tout tourne à côté de la stack du TP04 en prod (`shop`, 2 réplicas d'api).

Écarts de versions : `cadvisor:v0.52.1`, `loki`/`promtail:3.1.1`. Prometheus et Grafana sont aux versions de l'énoncé.

## 1. Les logs côté Docker

```
$ docker logs --since 5m --timestamps shop-api-1 | jq
{"level":30,"msg":"request completed","url":"/ready","status":200,"responseTime":0}
$ docker inspect shop-api-1 --format '{{.HostConfig.LogConfig}}'
{json-file map[max-file:3 max-size:10m]}           ← rotation du TP04
$ docker inspect shop-api-1 --format '{{.LogPath}}'
/var/lib/docker/containers/7f0a85de…/7f0a85de…-json.log   (le lire demande sudo, indisponible sur ce poste)
$ docker run --name tp07-nolog --log-driver none alpine echo "pas loggé"; docker logs tp07-nolog
pas loggé                                           ← vu car le terminal était attaché
Error response from daemon: configured logging driver does not support reading
```

- **Sans `max-size`** : le fichier `*-json.log` grossit sans limite. Avec une API qui logge chaque requête (ici environ 65 000 lignes en 5 min sous charge), on atteint des dizaines de Go en 6 mois. `/var/lib/docker` se remplit, puis le démon, les bases et l'OS tombent.
- **stdout/stderr plutôt qu'un fichier** : c'est le flux que capture le runtime. On garde `docker logs`, la rotation, l'envoi par n'importe quel driver ou collecteur, et rien ne s'écrit dans la couche du conteneur (qui gonflerait et disparaîtrait au `rm`). Ça permet aussi un rootfs `read_only`. C'est le facteur III « logs » des 12-factor apps.
- **Drivers** :
  - `json-file` : défaut, JSON par ligne, lisible par `docker logs` et Promtail ;
  - `local` : format binaire compressé avec rotation par défaut, plus compact, mais réservé à `docker logs` ;
  - `journald` : vers systemd, interrogeable avec `journalctl CONTAINER_NAME=…` ;
  - `fluentd` / `awslogs` : envoi direct vers un collecteur ou CloudWatch, `docker logs` fonctionne grâce au dual logging.
- **`mode: non-blocking` + `max-buffer-size`** : par défaut (`blocking`), si le driver est lent, l'écriture sur stdout **bloque l'application**. En `non-blocking`, les logs passent par un tampon en mémoire : l'application ne bloque jamais, mais **on perd des logs** quand le tampon est plein. C'est un compromis entre disponibilité et exhaustivité des logs.

## 2. Métriques côté Docker

`logs/02-metriques-docker.txt` :

```
$ docker stats --no-stream
shop-api-1      0.33%   21.48MiB / 256MiB   8.39%
shop-db-1       0.30%   25.15MiB / 512MiB   4.91%  …
$ docker update --memory 64m --memory-swap 64m shop-api-1 && ./load.sh 3000 50
   2400 200 / 600 201
shop-api-1 26.73MiB / 64MiB 41.76%      OOMKilled=false RestartCount=0
```

À **64 Mo, pas d'OOM** : l'api ne consomme qu'environ 27 Mo, même sous charge. Pour observer réellement le phénomène, j'ai baissé la limite à 24 Mo :

```
$ docker update --memory 24m --memory-swap 24m shop-api-1 && ./load.sh 3000 100
   2283 200 / 563 201 / 154 502            ← Traefik : backend tué en pleine requête
RestartCount=3 Status=running
$ docker events --filter container=shop-api-1 --filter event=oom --filter event=die --filter event=start
oom / die exitCode=137 / start / oom / die exitCode=137 / start …
```

`State.OOMKilled` vaut `false` parce qu'il décrit l'exécution **en cours**, déjà redémarrée par `restart: unless-stopped`. Les preuves sont l'événement `oom`, le code de sortie 137 (SIGKILL) et `RestartCount`. La limite a ensuite été remise à 256 Mo.

## 3. Stack d'observabilité

- **Prometheus** est sur `default`, `shop_front` et `shop_back`. Il scrape :
  - cAdvisor ;
  - l'api via `dns_sd_configs` (`api`, type A, port 3000), avec **une cible par réplica** grâce au DNS embarqué qui renvoie une IP par conteneur ;
  - le worker (`worker:9100`).

  Les réseaux `shop_*` sont `external`, donc le DNS des services du projet `shop` est visible depuis le projet `observability`.
- **Pourquoi pas `docker_sd_configs` pour Prometheus** : `docker exec prometheus id` → `uid=65534(nobody)`. Il ne peut pas lire `/var/run/docker.sock` (root:docker, 660). Et lui donner la socket reviendrait à lui donner **root sur l'hôte** pour un simple scraper exposé sur le réseau. Le DNS suffit et ne demande aucun privilège.
- **cAdvisor** monte `/`, `/var/run`, `/sys` et `/var/lib/docker` en lecture seule, avec `/dev/kmsg` (pour les événements OOM). Il tourne **sans `privileged`** et récupère quand même les noms et labels des conteneurs (`container_label_com_docker_compose_*`).
- **Loki + Promtail** : Promtail lit la socket Docker (`docker_sd_configs`) et pose les labels `container`, `service` et `project` à partir des labels Compose. L'étape `json` extrait `level` en label.
- **Grafana** (port 3001, `admin/admin`) : datasources et dashboard **provisionnés par fichiers** (`readOnly=true`, dossier *Shop*, uid `shop-overview`). L'accès anonyme en lecture seule n'est activé que pour les captures headless, et le port est lié à `127.0.0.1`.
- **Alertes** (`prometheus/alerts.yml`) :

  | Alerte | Condition |
  |--------|-----------|
  | `ApiDown` | `up{job="api"} == 0` pendant 30 s |
  | `ApiHigh5xxRate` | plus de 5 % de 5xx |
  | `ApiHighLatencyP95` | p95 > 500 ms |
  | `ContainerRestarting` | redémarrage d'un conteneur |
  | `ContainerMemoryNearLimit` | mémoire > 90 % de la limite |

  Pour `ContainerRestarting`, cAdvisor **n'expose aucun compteur de redémarrages**, et `container_start_time_seconds` ne change pas lors d'un restart Docker (je l'ai vérifié). La règle utilise donc `changes(process_start_time_seconds[5m])`, métrique exportée par l'api (prom-client) et le worker (prometheus_client).

```
$ curl localhost:9090/api/v1/targets
api         172.31.0.4:3000   up
api         172.31.0.3:3000   up        ← les 2 réplicas trouvés par DNS
cadvisor    cadvisor:8080     up
prometheus  localhost:9090    up
worker      172.30.0.4:9100   up
Loki, valeurs du label service : ["api","cadvisor","db","grafana","loki","prometheus","promtail","redis","traefik","worker"]
{service="worker"} |= "confirmed"  → {"level":"INFO","msg":"commande 1793352352564 -> confirmed"}
sum(rate(http_request_duration_seconds_count[1m])) by (status) → 200: 30.2 req/s, 201: 7.2 req/s
```

Captures :

- `captures/grafana-dashboard.png` : le dashboard sous charge (débit par statut, p50/p95, cibles up, commandes traitées, mémoire et CPU par conteneur, avec les redémarrages d'api-1 visibles en mémoire) ;
- `captures/prometheus-alerts.png` : `ContainerRestarting` en **firing** et `ApiDown` en pending, pendant les OOMKill d'api-1 ;
- `captures/prometheus-targets.png` : les cibles.

Écart avec l'énoncé : la requête `{service="api"} | json | level="50"` ne remonte rien. **pino-http logge toutes les requêtes en `level: 30`**, même les 5xx, faute de `customLogLevel` dans le code. Le niveau 50 ne sert qu'au handler d'erreurs (`erreur non gérée`). On filtre donc sur le statut : `{service="api"} | json | res_statusCode >= 500`. Côté worker, le niveau est textuel (`INFO` / `ERROR`).

## 4. Exercice de corrélation

J'ai injecté moi-même la panne (« Redis arrêté ») avec `docker stop shop-redis-1`, puis je l'ai cherchée uniquement avec les métriques et les logs (`logs/05-correlation.txt`) :

1. **Symptôme** : `./load.sh` → 280 réponses **503** sur 300. Elles viennent de Traefik : `/ready` échoue, le healthcheck de backend retire les réplicas, et il n'y a plus de serveur disponible.
2. **Prometheus** : `rate(http_request_duration_seconds_count{route="/ready",status="503"}[1m])` est non nul. L'api est vivante (`up=1`) mais n'est pas prête : une dépendance est en cause.
3. **Loki** : `{service="api"} | json | res_statusCode >= 500` → `/ready 503` sur les deux réplicas. `{service="worker"} |= "erreur"` → `Error -3 connecting to redis:6379. Temporary failure in name resolution` : le nom `redis` ne résout plus, donc le conteneur n'existe plus sur le réseau.
4. **cAdvisor** : `time() - container_last_seen{name="shop-redis-1"}` = 30 s. Le conteneur n'est plus vu.
5. **Vérification Docker** : `shop-redis-1 Exited (0)`, donc arrêt volontaire (pas un crash : le code de sortie 0 correspond à un SIGTERM propre). Remise en état avec `docker start shop-redis-1` : tout redevient `healthy`.

Diagnostic en moins de 2 minutes. Le message DNS du worker suffit presque à lui seul à pointer Redis.
