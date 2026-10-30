# GestStock — RUNBOOK

Raccourcis :

```bash
DEV="docker compose"                                                       # + compose.override.yml (Mailpit)
PROD="docker compose -f compose.yml -f compose.prod.yml -f compose.hardened.yml"
```

## Prérequis sur le serveur

- Docker Engine 25+ avec le plugin compose.
- Un utilisateur `deploy` dans le groupe `docker`. La variable `DOCKER_GID` donne le gid du groupe `docker`, utilisé par le proxy de socket (`getent group docker`).
- Les fichiers **hors git**, présents uniquement sur le serveur :
  - `.env` : `REGISTRY`, `VERSION`, `SMTP_HOST`, `SMTP_PORT`, `REPORT_TO` (modèle : `.env.example`) ;
  - `secrets/db_password.txt` et `secrets/db_root_password.txt`, en mode 644 : MariaDB et l'application les lisent avec des uid non-root (999, 33).
- `ci/out/cosign.pub` : la clé publique qui vérifie les images.

## Démarrer / arrêter

| Action | Commande |
|--------|----------|
| Dev (Mailpit sur `mail.localhost`, code monté) | `$DEV up -d --build --wait` |
| Prod | `$PROD up -d --wait` |
| État | `$PROD ps` (tout doit être `healthy`) |
| Arrêter **sans** perdre les données | `$PROD down` |
| ⚠️ Détruire les données | `$PROD down -v` : **jamais** sans une sauvegarde vérifiée |

URL : `http://geststock.localhost`. Santé : `/?health` renvoie `OK`, ou `503 DB KO`.

## Mettre à jour (zéro interruption)

1. La CI (`./ci-local.sh`) construit et teste l'image, la passe au gate (trivy, non-root, healthcheck, labels), lance le test d'intégration, la pousse avec le tag `sha-<commit>` et la signe.
2. Sur le serveur : `VERSION=sha-<commit> ./scripts/rolling-update.sh`.
   - Le script vérifie la signature et refuse une image non signée.
   - Il remplace les 2 réplicas un par un : un nouveau réplica healthy, puis l'ancien arrêté en SIGTERM.
   - Il recrée ensuite `cron`.
3. Mettre à jour `VERSION` dans `.env` pour que le prochain `up` reste sur cette version.

Mesure de contrôle : `./scripts/measure-downtime.sh 40 100` dans un autre terminal pendant la mise à jour (cible : 0 échec).

## Revenir en arrière

`VERSION=sha-<ancien> ./scripts/rolling-update.sh` prend environ 23 s, sans interruption. C'est possible parce que :

- les tags `sha-*` sont immuables et conservés dans le registre ;
- le schéma est compatible.

En cas de migration de schéma non rétro-compatible, on restaure la sauvegarde prise **avant** la mise à jour (voir ci-dessous).

## Sauvegarder / restaurer

| Action | Commande |
|--------|----------|
| Sauvegarde (à planifier, par exemple avec un cron hôte à 2 h) | `./scripts/backup.sh` → `backups/db-TS.sql.gz` (`mariadb-dump --single-transaction`, à chaud) + `backups/uploads-TS.tar.gz` ; rétention `KEEP=7` |
| Restauration | `./scripts/restore.sh [TS]` (la plus récente par défaut) : réimporte la base, puis **remplace** le contenu du volume uploads |
| Vérifier | `./scripts/checksum.sh` (nombre d'articles + md5, nombre de fichiers + md5) : comparer avec la valeur relevée avant |
| Test de restauration (mensuel) | sur une copie : `backup` → `down -v` → `up` → `restore` → `checksum` identique |

Les sauvegardes doivent quitter le serveur (copie distante ou S3). Une sauvegarde qui reste sur le seul disque du serveur partage son sort, comme celle du legacy, perdue avec le « disque plein depuis mars ».

## Rapport quotidien

- Planifié à 6 h par supercronic dans le conteneur `cron` (`docker/cron/crontab`).
- **À la demande** : `$PROD exec cron php /var/www/geststock/bin/rapport.php`.
- En dev, les mails arrivent dans Mailpit (`http://mail.localhost`). En prod, ils partent vers `SMTP_HOST`.

## Diagnostiquer

| Question | Où regarder |
|----------|-------------|
| Qu'est-ce qui ne va pas ? | `$PROD ps`, puis `docker inspect <c> --format '{{json .State.Health}}'` |
| Logs applicatifs (lignes `geststock:`) et logs Apache (accès/erreurs) | `$PROD logs -f app cron`, ou Grafana → Explore → Loki : `{project="geststock", service="app"}` |
| Erreurs PHP | Mêmes logs (stderr). `display_errors=Off` : rien n'est jamais affiché à l'utilisateur. |
| Base | `$PROD logs db` ; `$PROD exec db healthcheck.sh --connect` |
| Mémoire / CPU par conteneur | `docker stats`, ou Grafana (cAdvisor) : `container_memory_working_set_bytes{container_label_com_docker_compose_project="geststock"}` |
| Routage | `$PROD logs traefik` (logs d'accès : backend choisi, code, durée) |
| Sécurité de la config | `AUDIT_SOCKET_OK=geststock-socket-proxy-1 ./scripts/audit.sh geststock` (doit donner 0 écart) |

Observabilité : `cd observability && docker compose -f <tp07>/compose.observability.yml -f compose.geststock.yml up -d --wait`.

## Rotation des secrets

**Mot de passe applicatif** (`geststock`) :

1. Générer le nouveau mot de passe : `NEW=$(openssl rand -hex 16)`.
2. Le changer en base, avec l'ancien mot de passe encore valide côté application :
   `$PROD exec db sh -c 'mariadb -uroot -p"$(cat /run/secrets/db_root_password)" -e "ALTER USER geststock@\"%\" IDENTIFIED BY \"'$NEW'\""'`
3. Écrire `secrets/db_password.txt` avec le nouveau mot de passe.
4. Lancer `VERSION=<version courante> ./scripts/rolling-update.sh`. Les nouveaux réplicas relisent le secret au démarrage. Les anciens gardent leurs connexions PDO ouvertes, puis sont remplacés. Comme l'application ouvre une connexion par requête, un ancien réplica peut échouer brièvement entre les étapes 2 et 4 : faire les deux à la suite.

**Mot de passe root** : même principe, avec `secrets/db_root_password.txt`. Il ne sert qu'à l'administration.

**Clé cosign** : générer une nouvelle paire, re-signer les images encore déployables, puis distribuer la nouvelle `cosign.pub`. En CI, le mode keyless (OIDC) évite d'avoir une clé à faire tourner.
