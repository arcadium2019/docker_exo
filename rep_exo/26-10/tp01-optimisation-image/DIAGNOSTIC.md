# TP01 — Livrable 1 : diagnostic de `shopapi:legacy`

Image construite depuis le `Dockerfile` historique (conservé dans [`shopapi/Dockerfile.legacy`](shopapi/Dockerfile.legacy)).
Toutes les sorties complètes sont dans [`logs/`](logs/) : `diag.log`, `hadolint-legacy.log`, `dive-legacy.log`, `cache-legacy.log`, `stop-legacy.log`.

```bash
cd shopapi
docker build -t shopapi:legacy -f Dockerfile.legacy .
```

> Taille mesurée : **738 Mo**, et non « plus d'1 Go » comme l'annonce l'énoncé. Le `dump-prod-2024.sql` du starter n'est qu'un fichier de 47 octets qui *simule* un dump de 50 Mo. Avec le vrai dump et un `node_modules` local copié, l'image dépasserait le Go.

## Synthèse

| # | Catégorie | Problème | Gravité |
|---|---|---|---|
| 1 | Taille / perf | Base `ubuntu:22.04` + Node installé via NodeSource | Haute |
| 2 | Taille / perf | Outils de build et de debug installés et laissés dans l'image (367 Mo) | Haute |
| 3 | Taille / perf | `apt-get update` dans une couche séparée, listes apt jamais supprimées | Moyenne |
| 4 | Taille / perf | `COPY . /app` avant `npm install` : le cache des dépendances saute à chaque commit | Haute |
| 5 | Taille / perf | Aucun `.dockerignore` : tout le dossier part dans le contexte et dans l'image | Moyenne |
| 6 | Taille / perf | Dépendances de dev, `nodemon` global et cache npm dans l'image finale | Moyenne |
| 7 | Taille / perf | `npm install` sans lockfile versionné : build non reproductible | Moyenne |
| 8 | Sécurité | Le conteneur tourne en **root** | Haute |
| 9 | Sécurité | Mot de passe BdD en clair dans un `ENV` (history, inspect, env) | Critique |
| 10 | Sécurité | `.env` (clé AWS, URL BdD) copié dans l'image | Critique |
| 11 | Sécurité | Dump de prod (`dump-prod-2024.sql`) copié dans l'image | Critique |
| 12 | Sécurité | Rien n'est épinglé (tag de base mutable, `curl \| bash`, paquets apt/npm sans version) | Haute |
| 13 | Sécurité | Surface d'attaque : compilateur, git, curl, wget, vim disponibles pour un attaquant | Moyenne |
| 14 | Exploitabilité | `CMD` en forme shell : `sh` est PID 1, SIGTERM jamais transmis, arrêt en 10 s par SIGKILL | Haute |
| 15 | Exploitabilité | `NODE_ENV=development` en production | Moyenne |
| 16 | Exploitabilité | Pas de `HEALTHCHECK` | Moyenne |
| 17 | Exploitabilité | Pas de labels OCI ; le seul label présent (`version=22.04`) est hérité d'Ubuntu et trompeur | Faible |
| 18 | Exploitabilité | Les tests et le lint ne sont pas exécutés pendant le build | Moyenne |

---

## A. Taille et performance

### 1. Base `ubuntu:22.04` + Node via NodeSource

```text
$ docker image ls shopapi:legacy
IMAGE            ID             DISK USAGE   CONTENT SIZE   EXTRA
shopapi:legacy   f4f132f7d5dc        738MB             0B

$ docker history shopapi:legacy        (extrait)
RUN /bin/sh -c apt-get install -y nodejs # b…   160MB
<missing>  /bin/sh -c #(nop) ADD file:b6c410e935243e562…   78.1MB
```

**Impact** : Ubuntu (78 Mo) + Node du paquet Debian NodeSource (160 Mo) font déjà 238 Mo. L'image officielle `node:20-alpine` fait 136 Mo, Node compris. Le registre sature, et chaque pull en CI et sur les nœuds de prod est plus long.

### 2. Outils inutiles à l'exécution

```text
RUN /bin/sh -c apt-get install -y curl wget …   367MB

$ docker run --rm shopapi:legacy sh -c "which vim git gcc make python3 curl wget"
/usr/bin/vim
/usr/bin/git
/usr/bin/gcc
/usr/bin/make
/usr/bin/python3
/usr/bin/curl
/usr/bin/wget
```

**Impact** : 367 Mo, soit **la moitié de l'image**, pour des outils dont l'API n'a pas besoin (elle n'a aucun module natif à compiler). Les paquets sont aussi installés sans `--no-install-recommends` (hadolint DL3015).

### 3. `apt-get update` isolé, listes non nettoyées

```text
RUN /bin/sh -c apt-get update # buildkit        81.3MB

$ hadolint Dockerfile
-:4 DL3009 info: Delete the apt lists (/var/lib/apt/lists) after installing something
-:5 DL3059 info: Multiple consecutive `RUN` instructions. Consider consolidation.

$ dive shopapi:legacy --ci      (extrait « Inefficient Files »)
    2        540 kB  /var/lib/apt/lists/archive.ubuntu.com_ubuntu_dists_jammy_InRelease
    4        2.1 MB  /var/cache/debconf/templates.dat
    4        992 kB  /var/log/dpkg.log
```

**Impact** : 81 Mo d'index apt figés dans une couche. Comme `update` et `install` sont dans deux `RUN` séparés, le cache de couches peut réutiliser un `apt-get update` vieux de plusieurs mois avec un `install` récent : on obtient des paquets périmés ou des erreurs 404.

### 4. Ordre des couches : le code est copié avant les dépendances

```text
$ echo "// commentaire" >> src/server.js
$ time docker build -t shopapi:legacy .
#12 [8/9] COPY . /app
#12 DONE 0.1s
#13 [9/9] RUN npm install
#13 5.523 added 222 packages, and audited 223 packages in 5s
real	0m6,522s
```

**Impact** : **n'importe quel** changement de fichier (code, README, Dockerfile, dump…) change le checksum de `COPY . /app`, ce qui invalide cette couche et toutes les suivantes, dont `npm install`. Cela prend 6 s en local et environ 4 min en CI, sans cache npm ni réseau rapide. Détail à l'étape 2 du [rapport](tp01-optimisation-image.md#2-invalidation-du-cache).

### 5. Pas de `.dockerignore`

```text
$ docker run --rm shopapi:legacy ls -la /app
-rw-r--r--. 1 root root   179 Oct 26 09:50 .env
-rw-r--r--. 1 root root    20 Oct 26 09:50 .gitignore
-rw-r--r--. 1 root root   505 Oct 26 09:50 Dockerfile
-rw-r--r--. 1 root root    47 Oct 26 09:50 dump-prod-2024.sql
drwxr-xr-x. 1 root root  4260 Oct 26 09:53 node_modules
...
```

**Impact** : le contexte de build (envoyé au daemon) et l'image contiennent tout le répertoire. Sur le poste d'un dev, cela inclut son `node_modules` local (binaires compilés pour macOS, qui écrasent ceux de Linux), `.git` et les dumps. C'est la cause directe des problèmes 10 et 11.

### 6. Dépendances de dev et cache npm dans l'image finale

```text
$ docker run --rm shopapi:legacy sh -c 'ls /app/node_modules | grep -E "^(eslint|nodemon)$"; ls /usr/lib/node_modules'
eslint
nodemon
corepack
nodemon
npm

$ dive shopapi:legacy --ci   →  /root/.npm/_cacache/...  (cache npm laissé dans la couche)
```

**Impact** : `node_modules` pèse 30 Mo avec 222 paquets, contre 114 paquets en prod. `nodemon` est installé deux fois (globalement et en devDependency). Ce sont du code mort et autant de CVE potentielles à scanner.

### 7. Build non reproductible

`package-lock.json` n'est pas versionné : il est **généré dans l'image** au moment du build (on le voit dans le `ls -la /app` ci-dessus, 96 529 octets, daté de l'heure du build). `npm install` résout les plages `^4.19.2`, etc. au moment du build.

**Impact** : deux builds du même commit peuvent embarquer des versions différentes, par exemple `eslint@9.39.5`, que le build a résolue alors que `package.json` demande `^9.9.0`. Un bug ou une CVE peut alors apparaître « sans changement de code ».

## B. Sécurité

### 8. Exécution en root

```text
$ docker run --rm shopapi:legacy id
uid=0(root) gid=0(root) groups=0(root)

$ docker inspect shopapi:legacy --format '{{json .Config.User}}'
""
```

**Impact** : une RCE dans Express ou une dépendance donne un shell root dans le conteneur. L'attaquant peut alors réécrire l'application, installer des outils (apt fonctionne) et, en cas de faille du runtime ou de montage mal configuré, s'évader en root sur l'hôte. L'image est refusée par les politiques Kubernetes `runAsNonRoot` / Pod Security « restricted ».

### 9. Secret dans `ENV`

```text
$ docker run --rm shopapi:legacy env | grep -i -E 'secret|database'
DATABASE_URL=postgres://shop:S3cret!@db.internal:5432/shop

$ docker history shopapi:legacy
<missing>  ENV DATABASE_URL=postgres://shop:S3cret!@db.…   0B
```

**Impact** : le mot de passe de la BdD de prod est lisible par toute personne qui peut faire un `pull`, via `docker history`, `docker inspect` ou le JSON de config de l'image dans le registre. Il reste dans toutes les versions de l'image déjà publiées : il faut le **révoquer**, le supprimer du Dockerfile ne suffit pas. Il doit être injecté au runtime (`-e`, `env_file`, secret Kubernetes, Vault).

### 10. `.env` embarqué

```text
$ docker run --rm shopapi:legacy cat /app/.env
# fichier local d'un dev, commité par erreur
DATABASE_URL=postgres://shop:S3cret!@localhost:5432/shop
REDIS_URL=redis://localhost:6379
AWS_SECRET_ACCESS_KEY=AKIAFAKEFAKEFAKEFAKE
```

**Impact** : une clé AWS dans une image publiée. Les scanners de secrets (trivy, voir TP03) et les attaquants la trouvent en quelques secondes. Le `.gitignore` ne protège pas l'image : seul `.dockerignore` agit sur le contexte de build.

### 11. Dump de production embarqué

```text
$ docker run --rm shopapi:legacy ls -la /app
-rw-r--r--. 1 root root    47 Oct 26 09:50 dump-prod-2024.sql
```

**Impact** : des données de prod, probablement personnelles (clients, commandes), se retrouvent dans un artefact largement distribué. C'est un incident RGPD potentiel, et +50 Mo par image.

### 12. Rien n'est épinglé

```text
$ hadolint Dockerfile
-:5 DL3008 warning: Pin versions in apt get install.
-:6 DL4006 warning: Set the SHELL option -o pipefail before RUN with a pipe in it.
-:7 DL3008 warning: Pin versions in apt get install.
-:8 DL3016 warning: Pin versions in npm.
-:15 DL3025 warning: Use arguments JSON notation for CMD and ENTRYPOINT arguments
exit=1
```

`FROM ubuntu:22.04` est un tag mutable. `curl -fsSL https://deb.nodesource.com/setup_20.x | bash -` exécute en root un script distant sans vérification. Sans `pipefail`, un échec de `curl` passe même inaperçu.

**Impact** : risque de supply chain (script ou paquet compromis), et une image différente à chaque build. **5 warnings hadolint**, alors que le standard n°7 exige 0.

### 13. Surface d'attaque

Ce sont les mêmes outils qu'au point 2 : `gcc`, `make`, `git`, `curl`, `wget`, `python3`, `vim`, `apt`.

**Impact** : après une compromission, l'attaquant dispose de tout ce qu'il faut pour télécharger (curl, wget, git), compiler (gcc) et exécuter des outils. Chaque paquet ajoute aussi des CVE au rapport de scan, souvent des centaines sur une Ubuntu avec build-essential.

## C. Exploitabilité

### 14. Forme shell du `CMD` : SIGTERM perdu

```text
$ docker inspect shopapi:legacy --format '{{json .Config.Cmd}}'
["/bin/sh","-c","npm start"]

$ docker exec api-ps ps -eo pid,ppid,cmd
    PID    PPID CMD
      1       0 /bin/sh -c npm start
      7       1 npm start
     18       7 sh -c node src/server.js
     19      18 node src/server.js

$ time docker stop api-legacy
real	0m10,178s
$ docker inspect api-legacy --format "{{.State.ExitCode}}"
137
```

**Impact** : `docker stop` envoie SIGTERM au PID 1, qui est `/bin/sh`. `sh` ne relaie pas les signaux à ses enfants et, en tant que PID 1, ignore lui-même SIGTERM faute de handler. Le handler `shutdown()` de `server.js` (PID 19) n'est **jamais appelé**. Au bout de 10 s, Docker envoie SIGKILL (exit 137 = 128 + 9) : les connexions en cours sont coupées net et le pool PG n'est pas fermé. C'est la cause des 30 s de rolling update (`terminationGracePeriodSeconds` de Kubernetes à 30 s par défaut). On a en plus 3 processus intermédiaires inutiles (`sh`, `npm`, `sh`).

### 15. `NODE_ENV=development`

```text
ENV NODE_ENV=development
```

**Impact** : en mode développement, Express ne met pas en cache les templates et renvoie des messages d'erreur plus verbeux. De nombreuses bibliothèques désactivent aussi leurs optimisations. Le comportement en prod diffère de ce qui est attendu.

### 16. Pas de `HEALTHCHECK`

```text
$ docker inspect shopapi:legacy --format '{{json .Config.Healthcheck}}'
null
```

**Impact** : Docker ou Compose considère le conteneur sain dès que le processus tourne, même si l'API ne répond plus. Le service `depends_on: condition: service_healthy` est impossible, et il n'y a pas de redémarrage automatique en cas de blocage. L'application expose pourtant `/health` et `/ready`.

### 17. Pas de labels OCI

```text
$ docker inspect shopapi:legacy --format '{{json .Config.Labels}}'
{"org.opencontainers.image.version":"22.04"}
```

**Impact** : impossible de savoir quel commit ou quelle version tourne en prod à partir de l'image. Le seul label est **hérité d'Ubuntu** et annonce une « version 22.04 » qui n'a rien à voir avec l'API 1.4.2. La traçabilité, les rapports de scan et les audits deviennent difficiles (voir la porte de release du TP03).

### 18. Tests non exécutés au build

Aucun `RUN npm test` ni `npm run lint` dans le Dockerfile.

**Impact** : une image cassée peut être construite, poussée et déployée. Le standard n°6 exige une étape de test dans le build.
