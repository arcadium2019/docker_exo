# TP06 — Réseau Docker et dépannage

Livrables : `compose.yml` et `nginx/default.conf` corrigés, rapport d'incident **`INCIDENT.md`** (13 anomalies corrigées et 1 relevée). Les preuves sont dans `logs/`.

## Partie 1 — Rappels réseau

`logs/01-rappels.txt` (conteneurs nommés `tp06-a` / `tp06-b` pour ne pas entrer en collision avec d'autres projets) :

```
$ docker exec tp06-a ping -c1 tp06-b          # bridge par défaut
ping: bad address 'tp06-b'
$ docker network create tp06-demo && docker network connect tp06-demo tp06-a && docker network connect tp06-demo tp06-b
$ docker exec tp06-a ping -c1 tp06-b
64 bytes from 192.168.16.3: seq=0 ttl=64 time=0.043 ms
$ docker exec tp06-a cat /etc/resolv.conf
nameserver 127.0.0.11
$ docker run --rm --network container:tp06-a nicolaka/netshoot ip -br a
eth0@if94   UP   172.17.0.2/16      ← bridge par défaut
eth1@if97   UP   192.168.16.2/20    ← tp06-demo : même pile réseau que tp06-a
```

- **Bridge par défaut** : pas de DNS entre conteneurs (seulement l'ancien `--link`). Un **réseau utilisateur** fournit le DNS embarqué (`127.0.0.11`), qui résout les noms de conteneurs, de services et les alias.
- `internal: true` : pas de route vers l'extérieur, donc pas d'Internet et **pas de publication de port**.
- `host` : le conteneur partage la pile réseau de l'hôte, sans isolation, et `ports:` est ignoré.
- `none` : seulement `lo`.
- `container:X` : le conteneur partage la pile de X, ce qui permet de déboguer avec netshoot sans rien installer dans l'image.
- `-p 8081:80` crée une règle DNAT sur l'hôte (iptables/nftables). `expose` est purement déclaratif et n'ouvre rien.

## Partie 2 — Résolution de l'incident

Tout le détail est dans `INCIDENT.md`. En résumé, j'ai remonté la chaîne depuis le symptôme (8081) : `config`, démarrage, publication de port, logs de l'api, port d'écoute, `/ready`, DNS, réseaux, nginx.

Résultat final :

```
NAME               STATUS                    PORTS
incident-api-1     Up 7 seconds (healthy)    3000/tcp
incident-api-2     Up 7 seconds (healthy)    3000/tcp
incident-db-1      Up 13 seconds (healthy)   5432/tcp
incident-front-1   Up 5 seconds (healthy)    0.0.0.0:8081->80/tcp
incident-redis-1   Up 13 seconds (healthy)   6379/tcp
$ curl -si localhost:8081/products  → 200, X-Cache: MISS
$ curl -si localhost:8081/products  → 200, X-Cache: HIT
```

## Partie 3 — Post-mortem

Le classement des anomalies et les 3 garde-fous (CI `config` + `up --wait` + smoke test, healthchecks réels avec `--wait`, revue et lint du compose) sont dans `INCIDENT.md`.
