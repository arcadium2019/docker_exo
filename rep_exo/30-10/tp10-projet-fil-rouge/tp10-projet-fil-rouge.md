# TP10 — Projet fil rouge : GestStock conteneurisé

Le dépôt est dans `geststock-docker/` (pas de `git init`, pour ne pas imbriquer de dépôt dans celui du cours). L'exploitation est décrite dans **`geststock-docker/RUNBOOK.md`**, et les preuves sont dans `geststock-docker/logs/`.

## Livrables

| # | Livrable | Où / preuve |
|---|----------|-------------|
| 1 | `Dockerfile` : multi-stage (`ext` compile pdo_mysql, `supercronic` téléchargé avec vérification sha256, `test` = `php -l`, `runtime`), `php:8.3.35-apache-trixie`, **non-root** (`USER 33:33`, Apache sur 8080), `HEALTHCHECK` sur `?health`, labels OCI, `php.ini-production` + `zz-geststock.ini` (`display_errors=Off`, `upload_max_filesize=20M`, `post_max_size=25M`, `expose_php=Off`), `.dockerignore` en liste blanche | `logs/01-build.txt` : PHP 8.3.35, pdo_mysql, `display_errors => Off` |
| 2 | Logs : `app_log()` écrit sur `php://stderr` ; Apache `ErrorLog /dev/stderr`, `CustomLog /dev/stdout` | `logs/03-fonctionnel.txt` : `INFO geststock: article ajouté…` dans `docker compose logs` |
| 3 | `config.php` lit `getenv()` avec des valeurs par défaut ; mot de passe lu dans `DB_PASS_FILE` (secret Compose) ; aucun mot de passe dans git ni dans l'image (`secrets/*.txt` gitignorés, trivy `--scanners secret` : 0) | `app/lib/config.php` |
| 4 | `compose.yml` (MariaDB 11.4.13 épinglée, volumes `dbdata` + `uploads`, init `schema.sql`, réseaux `front` / `back` internal / `socket` internal, healthchecks partout, `depends_on: service_healthy`, Traefik **via proxy de socket**, logs rotatifs), `compose.override.yml` (Mailpit, code monté), `compose.prod.yml` (image du registre, 2 réplicas, limites, `SMTP_HOST` obligatoire) | `logs/02-up-dev.txt`, `logs/07-prod-audit.txt` |
| 5 | Cron : conteneur `cron` dédié, même image, **supercronic** (`0 6 * * *`), santé et métriques sur `:9746` ; mail via msmtp → Mailpit en dev ; rapport **à la demande** avec `exec cron php bin/rapport.php` | `logs/03-fonctionnel.txt` : rapport généré et mail reçu dans Mailpit |
| 6 | `scripts/migrate-legacy.sh` (import du dump + copie des uploads dans le volume avec chown 33), `backup.sh` / `restore.sh` testés avec `checksum.sh`, procédure dans le RUNBOOK | `logs/04-migration.txt`, `logs/05-backup-restore.txt` |
| 7 | Observabilité : rejoint la stack du TP07 (`observability/compose.geststock.yml`) ; Promtail collecte les logs `project=geststock`, cAdvisor les métriques, Prometheus scrape supercronic | `logs/10-observabilite.txt` |
| 8 | `compose.hardened.yml` (read-only + tmpfs ciblés, `cap_drop: ALL` **sans aucun cap_add**, `no-new-privileges`, limites pids/mémoire) ; `audit.sh` → **0 écart** ; l'image passe le gate (labels, non-root, healthcheck, trivy 0 HIGH/CRITICAL corrigeable, 0 secret) puis la signature cosign | `logs/07-prod-audit.txt`, `logs/06-ci-local.txt` |
| 9 | `ci-local.sh` : hadolint, `compose config` → `php -l` → build → gate → **intégration** (stack prod + durcie éphémère, `up --wait`, curl santé, page, ajout d'article, rapport, `down -v`) → push → signature et vérification ; `scripts/rolling-update.sh` | `logs/06-ci-local.txt`, `logs/06b-…`, `logs/08b-*` |
| 10 | `RUNBOOK.md` : démarrer, mettre à jour, revenir en arrière, sauvegarder/restaurer, rapport, diagnostiquer, rotation des secrets | — |

## Modifications du code (à la marge)

- `lib/config.php` : `define()` alimentés par `getenv()`, avec un helper `secret()` (`*_FILE`). Les constantes et leurs noms sont inchangés.
- `lib/db.php` : `app_log()` écrit sur stderr au lieu de `/var/log/geststock/app.log`.
- `index.php` et `rapport.php` : **aucune modification**. Ils passent `php -l` en PHP 8.3 et fonctionnent tels quels.

## Résultats clés

```
migration      : items=250, 3 photos legacy → servies en 200 (logs/04)
backup/restore : avant  items=250 md5=299ec4c4… uploads=4 md5=cba54165…
                 down -v → items=4 (schema.sql neuf), uploads=0
                 après  items=250 md5=299ec4c4… uploads=4 md5=cba54165…   (identique)
sécurité       : /uploads/evil.php → 403 (PHP désactivé dans uploads) ; base coupée → /?health 503, aucune erreur affichée
audit          : 6 conteneurs, total deviations: 0
CI             : trivy 0 fixable HIGH/CRITICAL, 0 secret ; intégration OK (6 conteneurs healthy) ; signed and verified
rolling        : sha-74ae4fe → sha-c3d4e5f : 3 800 requêtes, 0 échec ; rollback : 1 échec / 3 800 (22,8 s)
```

## Choix argumentés

**Apache intégré (`php:8.3-apache`) plutôt que nginx + php-fpm.** Un seul conteneur et un seul process. C'est l'équivalent du legacy (Apache + mod_php), donc rien à réapprendre pour l'équipe. Il y a moins de pièces mobiles : pas de socket FastCGI ni de volume de code partagé entre deux conteneurs, et le healthcheck teste toute la chaîne. nginx + fpm se justifierait par du fort trafic ou des fichiers statiques nombreux, mais ce n'est pas le cas d'un inventaire interne : 1 vCPU sur le legacy.

**supercronic dans un conteneur dédié** (même image).

- Contre **ofelia** : il pilote par labels mais exige la **socket Docker**, c'est-à-dire root sur l'hôte, exactement ce que le TP08 a supprimé.
- Contre le **cron hôte** (`docker compose run rapport`) : la planification sort de la stack, n'est pas versionnée avec elle et dépend de la machine, ce qui reproduit le « personne ne sait reconstruire la machine » du legacy.
- Avantages de supercronic : il tourne en non-root, logge chaque exécution sur stdout (donc dans Loki), expose des métriques Prometheus et un `/health`, et reste testable à la demande avec `exec`.

**Volume uploads** : un **volume local nommé** en prod, parce qu'il n'y a qu'un hôte (comme le legacy) et que c'est simple et sauvegardé par `backup.sh`. Les 2 réplicas sont sur le même hôte, ils partagent donc le volume. Pour plusieurs hôtes, on passerait sur NFS (`driver_opts type=nfs`) ou, mieux, sur du stockage objet S3/MinIO, mais cela demanderait de modifier le code d'upload, donc hors périmètre « à la marge ».

## Pièges rencontrés

- `traefik…healthcheck.query` n'existe pas en v3.6 : l'erreur « field not found » désactive **tout le service**, d'où un 404. La query se met dans `path: /?health`.
- `pids_limit` / `mem_limit` (fichier durci) et `deploy.resources.limits` (prod) ne se combinent pas (« can't set distinct values ») : tout le durcissement est passé en `deploy.resources.limits`.
- trivy a bloqué l'image à cause de 4 CVE `stdlib` HIGH, venant du binaire Go de **supercronic v0.2.49**. Passage en **v0.2.51** : 0 CVE.
- **Zéro interruption avec Apache.** Le `STOPSIGNAL` de l'image est `SIGWINCH` (graceful-stop). Pendant l'arrêt, le socket d'écoute reste ouvert sans être servi : les connexions aboutissent puis restent bloquées, et ni le `dialTimeout` ni le `retry` de Traefik n'agissent (14 timeouts par arrêt). Avec `docker stop -s SIGTERM`, la connexion est refusée immédiatement et rejouée sur l'autre réplica. Il fallait aussi passer `retry.attempts` à 5, comme au TP09.
- Le rapport lancé avec `exec` n'apparaît pas dans Loki (la sortie d'un `exec` ne passe pas par les logs du conteneur) ; celui lancé par supercronic, si.
- `run --rm` est trop bref pour être découvert par Promtail (rafraîchissement toutes les 10 s).

## Limites (au plus simple)

- Le dump legacy est **simulé** (`legacy-sample/`, 250 articles et 3 photos), faute d'accès au vrai serveur.
- Mêmes simplifications qu'au TP09 pour la CI : registre local jetable, cosign avec clé, mono-arch, pas de push sur GitHub.
- Pas d'exporter MySQL (bonus).
