# Exercice Docker #6 — Conteneur de développement NGINX avec volume

Objectif : coder un site dans un dossier de l'hôte et le voir servi immédiatement par NGINX qui tourne dans un conteneur, sans rien installer en local.

Dossier du site : [`site/`](site/)

## 1. Créer le dossier de travail et une première page

```bash
mkdir -p rep_exo/exercice-06/site
cd rep_exo/exercice-06
```

`site/index.html` :

```html
<!DOCTYPE html>
<html lang="fr">
<head><meta charset="UTF-8"><title>Exercice 06</title></head>
<body><h1>Exercice 06 - site en développement</h1></body>
</html>
```

## 2. Lancer NGINX avec un bind mount (`-v`)

```bash
docker run -d --name ex06-dev \
  -p 8085:80 \
  -v "$(pwd)/site":/usr/share/nginx/html:ro,Z \
  nginx:alpine
```

- `-v <chemin_hôte>:<chemin_conteneur>` avec un **chemin absolu** côté hôte : c'est un **bind mount**. Le dossier de l'hôte remplace `/usr/share/nginx/html` (la racine web de NGINX) dans le conteneur.
- `ro` : lecture seule, le conteneur ne peut pas modifier nos sources.
- `Z` : nécessaire sur Fedora / SELinux, sinon NGINX renvoie `403 Forbidden` (refus SELinux). Pas utile sur Ubuntu, macOS ou Windows.
- Port 8085 utilisé parce que les ports précédents étaient pris par les autres exercices.

Vérification du montage :

```bash
docker inspect -f '{{range .Mounts}}{{.Type}} {{.Source}} -> {{.Destination}} rw={{.RW}}{{end}}' ex06-dev
# bind /home/.../rep_exo/exercice-06/site -> /usr/share/nginx/html rw=false
```

## 3. Tester le développement en direct

```bash
curl -s http://localhost:8085 | grep h1
# <body><h1>Exercice 06 - site en développement</h1></body>

# On modifie le fichier SUR L'HÔTE (éditeur, VS Code, sed...)
sed -i 's/Exercice 06/Version 2 (modifiée sur l hôte)/' site/index.html

curl -s http://localhost:8085 | grep h1
# <body><h1>Version 2 (modifiée sur l hôte) - site en développement</h1></body>
```

La modification est visible tout de suite, sans rebuild ni redémarrage du conteneur : il suffit de rafraîchir **http://localhost:8085** dans le navigateur. On peut ajouter des fichiers (`style.css`, `script.js`, d'autres pages…) dans `site/` et ils sont servis directement.

## Rappel : types de volumes

| Type | Syntaxe | Usage |
|---|---|---|
| Bind mount | `-v /chemin/hote:/chemin/conteneur` | Partager un dossier de l'hôte (ici : le code en développement) |
| Volume nommé | `-v mon_volume:/chemin/conteneur` | Données persistantes gérées par Docker (ex. MySQL, exercice 5) |
| Volume anonyme | `-v /chemin/conteneur` | Données temporaires, nom aléatoire |

## Nettoyage

```bash
docker rm -f ex06-dev
```
