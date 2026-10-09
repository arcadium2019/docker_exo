# Exercice Docker #2 — Jeu 2048

## 1. Trouver une image 2048 sur Docker Hub

Soit sur https://hub.docker.com (rechercher « 2048 »), soit en ligne de commande :

```bash
docker search 2048 --limit 5
# NAME                 DESCRIPTION                                     STARS
# blackicebird/2048    2048 with logging                               8
# runseb/2048          The 2048 game                                   0
# kubespheredev/2048   A docker image for popular game 2048(https:/…   0
# ...
```

> ⚠️ L'image souvent citée `alexwhen/docker-2048` ne fonctionne plus avec les versions récentes de Docker :
> ```
> Error response from daemon: unsupported manifest media type and no default available:
> application/vnd.docker.distribution.manifest.v1+prettyjws
> ```
> Elle utilise un ancien format de manifeste (v1), qui n'est plus pris en charge. On utilise donc à la place `evilroot/docker-2048` (NGINX qui sert le jeu sur le port 80).

## 2. Récupérer l'image localement

```bash
docker pull evilroot/docker-2048
docker images evilroot/docker-2048
```

## 3. Lancer le conteneur sur le port hôte 8080

```bash
docker run -d --name ex02-2048 -p 8080:80 evilroot/docker-2048
```

- `-p 8080:80` : le port 8080 de l'hôte redirige vers le port 80 du conteneur.
- Si 8080 est déjà occupé (`Bind for 0.0.0.0:8080 failed: port is already allocated`), on utilise 8090 :
  `docker run -d --name ex02-2048 -p 8090:80 evilroot/docker-2048`

Vérification :

```bash
docker ps --filter name=ex02
# ex02-2048  evilroot/docker-2048  0.0.0.0:8080->80/tcp

curl -s http://localhost:8080 | grep title
# <title>2048</title>
```

## 4. Accéder au jeu depuis le navigateur de l'hôte

Ouvrir **http://localhost:8080** dans le navigateur : le jeu 2048 s'affiche et on peut jouer avec les flèches du clavier.

## Nettoyage

```bash
docker rm -f ex02-2048
```
