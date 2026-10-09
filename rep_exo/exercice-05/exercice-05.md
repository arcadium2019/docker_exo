# Exercice Docker #5 — MySQL et Adminer

Identifiants utilisés :

| Paramètre | Valeur |
|---|---|
| Base | `ynov_db` |
| Utilisateur | `ynov_user` / `ynov_pass` |
| Mot de passe root | `rootpass` |

## 1. Créer un réseau dédié

```bash
docker network create ex05-net
```

## 2. Créer un volume pour la persistance des données

```bash
docker volume create ex05-mysql-data
```

## 3. Déployer MySQL

```bash
docker run -d --name ex05-mysql \
  --network ex05-net \
  --restart unless-stopped \
  -v ex05-mysql-data:/var/lib/mysql \
  -e MYSQL_ROOT_PASSWORD=rootpass \
  -e MYSQL_DATABASE=ynov_db \
  -e MYSQL_USER=ynov_user \
  -e MYSQL_PASSWORD=ynov_pass \
  mysql:8.4
```

- `--network ex05-net` : réseau commun avec Adminer, pour que les conteneurs se joignent par leur nom.
- `--restart unless-stopped` : redémarrage automatique après un crash ou un redémarrage du démon Docker (sauf si on l'a arrêté nous-mêmes).
- `-v ex05-mysql-data:/var/lib/mysql` : les données sont stockées dans un volume nommé, indépendant du cycle de vie du conteneur.
- **Pas de `-p`** : MySQL n'est pas accessible depuis l'hôte.
- `MYSQL_DATABASE` / `MYSQL_USER` / `MYSQL_PASSWORD` : créent la base et l'utilisateur dédiés au premier démarrage.

Attendre que MySQL soit prêt :

```bash
docker logs -f ex05-mysql     # attendre "ready for connections" (Ctrl+C pour quitter)
```

## 4. Déployer Adminer

```bash
docker run -d --name ex05-adminer \
  --network ex05-net \
  --restart unless-stopped \
  -p 8083:8080 \
  -e ADMINER_DEFAULT_SERVER=ex05-mysql \
  adminer
```

Seul Adminer publie un port (`8083` côté hôte → `8080` dans le conteneur).

```bash
docker ps --filter name=ex05 --format '{{.Names}} | {{.Ports}}'
# ex05-adminer | 0.0.0.0:8083->8080/tcp
# ex05-mysql   | 3306/tcp, 33060/tcp        <- exposé, mais PAS publié sur l'hôte

docker port ex05-mysql     # (aucune sortie)
docker port ex05-adminer   # 8080/tcp -> 0.0.0.0:8083
```

## 5. Se connecter à MySQL depuis Adminer

Ouvrir **http://localhost:8083** :

| Champ | Valeur |
|---|---|
| Système | MySQL / MariaDB |
| Serveur | `ex05-mysql` ← **nom du conteneur**, pas d'IP |
| Utilisateur | `ynov_user` |
| Mot de passe | `ynov_pass` |
| Base de données | `ynov_db` |

### Créer une table et insérer des enregistrements

Dans Adminer → **Requête SQL** :

```sql
CREATE TABLE etudiants (
  id     INT AUTO_INCREMENT PRIMARY KEY,
  nom    VARCHAR(50) NOT NULL,
  prenom VARCHAR(50) NOT NULL,
  promo  VARCHAR(10)
);

INSERT INTO etudiants (nom, prenom, promo) VALUES
  ('Dupont', 'Alice', 'M2'),
  ('Martin', 'Bob',   'M2'),
  ('Durand', 'Chloé', 'M1');
```

> Équivalent en ligne de commande (c'est ce que j'ai lancé, puis j'ai vérifié le résultat dans Adminer) :
> ```bash
> docker exec -it ex05-mysql mysql -uynov_user -pynov_pass ynov_db -e "CREATE TABLE ...; INSERT INTO ...;"
> ```

### Consulter les enregistrements dans Adminer

Adminer → table `etudiants` → **Afficher les données** :

```
id  nom     prenom  promo
1   Dupont  Alice   M2
2   Martin  Bob     M2
3   Durand  Chloé   M1
```

(Vérifié aussi en HTTP : la connexion Adminer avec le serveur `ex05-mysql` répond `302 → ?server=ex05-mysql&username=ynov_user&db=ynov_db`, et la page `select=etudiants` contient bien Dupont, Martin et Durand.)

## 6. Vérifier la persistance (suppression / recréation de MySQL)

```bash
# Supprimer le conteneur (le volume, lui, est conservé)
docker rm -f ex05-mysql

# Recréer le conteneur avec la même commande et le même volume
docker run -d --name ex05-mysql \
  --network ex05-net \
  --restart unless-stopped \
  -v ex05-mysql-data:/var/lib/mysql \
  -e MYSQL_ROOT_PASSWORD=rootpass \
  -e MYSQL_DATABASE=ynov_db \
  -e MYSQL_USER=ynov_user \
  -e MYSQL_PASSWORD=ynov_pass \
  mysql:8.4

# Vérifier les données
docker exec -it ex05-mysql mysql -uynov_user -pynov_pass ynov_db -e "SELECT * FROM etudiants;"
# id  nom     prenom  promo
# 1   Dupont  Alice   M2
# 2   Martin  Bob     M2
# 3   Durand  Chloé   M1
```

La table et ses enregistrements sont toujours là (visible aussi en rafraîchissant Adminer).

## 7. Simuler une panne et vérifier le redémarrage automatique

```bash
docker inspect -f '{{.HostConfig.RestartPolicy.Name}} RestartCount={{.RestartCount}}' ex05-mysql
# unless-stopped RestartCount=0

# Panne : on arrête brutalement le serveur MySQL depuis l'intérieur du conteneur
docker exec ex05-mysql mysqladmin -uroot -prootpass shutdown

sleep 8
docker inspect -f 'RestartCount={{.RestartCount}} Status={{.State.Status}}' ex05-mysql
# RestartCount=1 Status=running     <- Docker a redémarré le conteneur tout seul
```

Points à connaître (vus pendant les tests) :
- `docker stop` / `docker kill` comptent comme un **arrêt manuel** : avec `unless-stopped`, le conteneur **ne redémarre pas** (`Status=exited`). Ce n'est pas une panne. Pour le relancer : `docker start ex05-adminer`.
- `docker exec <c> kill -9 1` n'a aucun effet : à l'intérieur de son namespace, le PID 1 ignore les signaux pour lesquels il n'a pas de handler.
- Une autre façon de simuler une panne depuis l'hôte : `sudo kill -9 $(docker inspect -f '{{.State.Pid}}' ex05-mysql)`.
- Redémarrage du démon Docker : `sudo systemctl restart docker`. Les conteneurs avec `unless-stopped` repartent automatiquement.

---

## Bonus — `compose.yaml`

Fichiers : [`compose.yaml`](compose.yaml) et [`.env`](.env).

`.env` :

```env
MYSQL_ROOT_PASSWORD=rootpass
MYSQL_DATABASE=ynov_db
MYSQL_USER=ynov_user
MYSQL_PASSWORD=ynov_pass
```

`compose.yaml` :

```yaml
name: ex05

services:
  mysql:
    image: mysql:8.4
    restart: unless-stopped
    environment:
      MYSQL_ROOT_PASSWORD: ${MYSQL_ROOT_PASSWORD}
      MYSQL_DATABASE: ${MYSQL_DATABASE}
      MYSQL_USER: ${MYSQL_USER}
      MYSQL_PASSWORD: ${MYSQL_PASSWORD}
    volumes:
      - mysql-data:/var/lib/mysql
    networks:
      - backend
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "localhost", "-uroot", "-p${MYSQL_ROOT_PASSWORD}"]
      interval: 5s
      timeout: 3s
      retries: 20
    # No "ports": MySQL is only reachable from the Docker network

  adminer:
    image: adminer
    restart: unless-stopped
    environment:
      ADMINER_DEFAULT_SERVER: mysql
    ports:
      - "8084:8080"
    networks:
      - backend
    depends_on:
      mysql:
        condition: service_healthy

networks:
  backend:

volumes:
  mysql-data:
```

Avec Compose, le nom DNS de MySQL est le **nom du service** : `mysql`. Le `healthcheck` combiné à `depends_on: condition: service_healthy` fait démarrer Adminer seulement quand MySQL est prêt. Le port 8084 est utilisé pour ne pas entrer en conflit avec la version manuelle (8083).

Commandes :

```bash
cd rep_exo/exercice-05
docker compose up -d          # démarre les 2 services en une seule commande
docker compose ps
# ex05-adminer-1 | Up            | 0.0.0.0:8084->8080/tcp
# ex05-mysql-1   | Up (healthy)  | 3306/tcp, 33060/tcp

docker compose logs -f mysql  # suivre les logs
docker compose down           # arrête et supprime les conteneurs + réseau (le volume est conservé)
docker compose down -v        # supprime aussi le volume (données perdues)
```

Adminer : **http://localhost:8084** (serveur : `mysql`).

## Nettoyage (version manuelle)

```bash
docker rm -f ex05-mysql ex05-adminer
docker network rm ex05-net
docker volume rm ex05-mysql-data
```
