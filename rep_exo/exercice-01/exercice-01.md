# Exercice Docker #1 — Image Ubuntu + NGINX

Objectif : créer une image `ubuntu-nginx` à partir d'un conteneur Ubuntu dans lequel on a installé NGINX à la main, puis la sauvegarder avec `docker commit`.

## 1. Créer un conteneur Ubuntu

```bash
docker run -dit --name ex01-ubuntu ubuntu:24.04 bash
```

- `-d` : lance le conteneur en arrière-plan
- `-i` : garde l'entrée standard ouverte
- `-t` : alloue un pseudo-terminal
- `bash` : processus principal, ce qui garde le conteneur en vie

> Variante en une seule étape, directement en interactif : `docker run -it --name ex01-ubuntu ubuntu:24.04 bash`

## 2. Entrer dans le conteneur

```bash
docker exec -it ex01-ubuntu bash
```

On obtient un prompt du type `root@559a18342c68:/#`.

## 3. Mettre à jour les paquets (dans le conteneur)

```bash
apt-get update
```

## 4. Installer NGINX (dans le conteneur)

```bash
apt-get install -y nginx
nginx -v
# nginx version: nginx/1.24.0 (Ubuntu)
```

## 5. Sortir du conteneur

```bash
exit
```

> Comme on est entré avec `docker exec`, `exit` ferme seulement la session bash ; le conteneur continue de tourner.
> (Si on était entré avec `docker run -it`, on peut faire `Ctrl+P` puis `Ctrl+Q` pour sortir sans arrêter le conteneur.)

## 6. Sauvegarder le conteneur en tant que nouvelle image

```bash
docker commit ex01-ubuntu ubuntu-nginx
# sha256:3e0f9bfc81f0...

docker images ubuntu-nginx
# IMAGE                 ID             DISK USAGE
# ubuntu-nginx:latest   3e0f9bfc81f0   139MB
```

## Vérification (facultatif) : lancer NGINX depuis la nouvelle image

```bash
docker run -d --name ex01-test -p 8081:80 ubuntu-nginx nginx -g 'daemon off;'
curl -s http://localhost:8081 | grep title
# <title>Welcome to nginx!</title>
```

`nginx -g 'daemon off;'` est nécessaire : `docker commit` ne définit pas de commande de démarrage pour NGINX, et NGINX doit rester au premier plan sinon le conteneur s'arrête tout de suite.

## Nettoyage

```bash
docker rm -f ex01-ubuntu ex01-test
docker rmi ubuntu-nginx
```
