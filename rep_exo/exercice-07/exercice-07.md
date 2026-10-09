# Exercice Docker #7 — Image MySQL `kennelDB` pré-initialisée

Fichiers : [`Dockerfile`](Dockerfile) et [`init.sql`](init.sql).

## Principe

L'image officielle `mysql` exécute automatiquement tous les fichiers `.sql`, `.sql.gz` et `.sh` placés dans **`/docker-entrypoint-initdb.d/`** (par ordre alphabétique), au **premier démarrage**, quand le dossier de données `/var/lib/mysql` est vide.

On construit donc notre propre image qui part de `mysql:8.4` et y copie le script d'initialisation.

## 1. Modèle de données

```
client (id, nom, prenom, date_naissance, pseudonyme)
   │ 1..n                         n..1
   └──── client_adresse (client_id, adresse_id) ────┐
                                                    │
adresse (id, numero, rue, code_postal, commune) ────┘

chien (id, nom, date_naissance, race, sterilise, client_id → client)
chat  (id, nom, date_naissance, race, sterilise, client_id → client)
```

- `client_adresse` est la **table d'association** (relation n-n) : un client peut avoir plusieurs adresses, et une adresse peut être partagée par plusieurs clients.
- `sterilise` est un `BOOLEAN` (`TINYINT(1)` dans MySQL : 1 = stérilisé, 0 = non).
- J'ai ajouté une clé étrangère `client_id` (le propriétaire) sur `chien` et `chat`. Ce n'était pas demandé, mais c'est logique pour un chenil.

## 2. Script d'initialisation — `init.sql`

```sql
CREATE DATABASE IF NOT EXISTS kennelDB CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE kennelDB;

CREATE TABLE client (
  id            INT AUTO_INCREMENT PRIMARY KEY,
  nom           VARCHAR(100) NOT NULL,
  prenom        VARCHAR(100) NOT NULL,
  date_naissance DATE        NOT NULL,
  pseudonyme    VARCHAR(50)  NOT NULL UNIQUE
);

CREATE TABLE adresse (
  id          INT AUTO_INCREMENT PRIMARY KEY,
  numero      VARCHAR(10)  NOT NULL,
  rue         VARCHAR(255) NOT NULL,
  code_postal VARCHAR(10)  NOT NULL,
  commune     VARCHAR(100) NOT NULL
);

CREATE TABLE client_adresse (
  client_id  INT NOT NULL,
  adresse_id INT NOT NULL,
  PRIMARY KEY (client_id, adresse_id),
  CONSTRAINT fk_ca_client  FOREIGN KEY (client_id)  REFERENCES client(id)  ON DELETE CASCADE,
  CONSTRAINT fk_ca_adresse FOREIGN KEY (adresse_id) REFERENCES adresse(id) ON DELETE CASCADE
);

CREATE TABLE chien (
  id             INT AUTO_INCREMENT PRIMARY KEY,
  nom            VARCHAR(100) NOT NULL,
  date_naissance DATE         NOT NULL,
  race           VARCHAR(100) NOT NULL,
  sterilise      BOOLEAN      NOT NULL DEFAULT FALSE,
  client_id      INT NULL,
  CONSTRAINT fk_chien_client FOREIGN KEY (client_id) REFERENCES client(id) ON DELETE SET NULL
);

CREATE TABLE chat ( ... même structure que chien ... );

INSERT INTO client (nom, prenom, date_naissance, pseudonyme) VALUES
  ('Dupont','Alice','1990-04-12','alice_d'), ('Martin','Bob','1985-11-03','bobby'),
  ('Durand','Chloé','2000-07-25','chloe25'), ('Lefebvre','David','1978-01-30','dav_lef');
-- + 4 adresses, 5 associations client-adresse, 4 chiens, 3 chats (voir init.sql)
```

(Le script complet est dans [`init.sql`](init.sql).)

## 3. Dockerfile

```dockerfile
FROM mysql:8.4

ENV MYSQL_DATABASE=kennelDB

# Every .sql / .sh file in this folder runs (alphabetical order) on the first start, when the data directory is empty
COPY init.sql /docker-entrypoint-initdb.d/01-init.sql
```

Le mot de passe root **n'est pas** écrit dans l'image (sinon il serait lisible par n'importe qui avec `docker history`). On le donne au lancement avec `-e`.

## 4. Construire l'image

```bash
cd rep_exo/exercice-07
docker build -t kennel-db .
docker images kennel-db
```

## 5. Lancer le conteneur

```bash
docker run -d --name ex07-kennel-db \
  -e MYSQL_ROOT_PASSWORD=rootpass \
  -p 3307:3306 \
  kennel-db
```

(Port 3307 côté hôte, au cas où un MySQL local utilise déjà 3306.)

On attend la fin de l'initialisation :

```bash
docker logs -f ex07-kennel-db
# ... /usr/local/bin/docker-entrypoint.sh: running /docker-entrypoint-initdb.d/01-init.sql
# ... ready for connections ... port: 3306
```

## 6. Vérifier que la base contient bien les tables et les données au lancement

```bash
docker exec -it ex07-kennel-db mysql -uroot -prootpass kennelDB -e "SHOW TABLES;"
# Tables_in_kennelDB
# adresse
# chat
# chien
# client
# client_adresse

docker exec -it ex07-kennel-db mysql -uroot -prootpass kennelDB -e "SELECT * FROM chien;"
# id  nom    date_naissance  race             sterilise  client_id
# 1   Rex    2019-05-10      Berger Allemand  1          1
# 2   Médor  2021-02-14      Labrador         0          2
# 3   Pixel  2023-08-01      Jack Russell     0          3
# 4   Oslo   2017-12-24      Husky Sibérien   1          4

docker exec -it ex07-kennel-db mysql -uroot -prootpass kennelDB -e "SELECT * FROM chat;"
# id  nom    date_naissance  race        sterilise  client_id
# 1   Minou  2020-03-15      Européen    1          1
# 2   Félix  2022-06-30      Maine Coon  0          3
# 3   Luna   2018-09-09      Siamois     1          4
```

Vérification de l'association clients ↔ adresses :

```bash
docker exec -it ex07-kennel-db mysql -uroot -prootpass kennelDB -e "
SELECT c.pseudonyme, CONCAT(a.numero,' ',a.rue,', ',a.code_postal,' ',a.commune) AS adresse
FROM client c
JOIN client_adresse ca ON ca.client_id = c.id
JOIN adresse a         ON a.id = ca.adresse_id;"
# pseudonyme  adresse
# alice_d     12 rue de la République, 69002 Lyon
# bobby       12 rue de la République, 69002 Lyon
# bobby       3bis avenue Jean Jaurès, 31000 Toulouse
# chloe25     45 boulevard Voltaire, 75011 Paris
# dav_lef     8 chemin des Vignes, 33000 Bordeaux
```

> Si les accents s'affichent mal (`M�dor`) dans le client `mysql`, ajouter `--default-character-set=utf8mb4`. Les données sont bien stockées en UTF-8, c'est seulement l'affichage du terminal qui pose problème.

## Point important

Le script ne s'exécute **qu'une fois**, quand le dossier de données est vide. Avec un volume (`-v kennel-data:/var/lib/mysql`) qui contient déjà des données, il n'est pas rejoué. Pour réinitialiser la base :

```bash
docker rm -f ex07-kennel-db
docker volume rm kennel-data     # si un volume était utilisé
```

## Nettoyage

```bash
docker rm -f ex07-kennel-db
docker rmi kennel-db
```
