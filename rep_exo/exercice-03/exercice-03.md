# Exercice Docker #3 — Site web personnalisé avec NGINX

Fichiers utilisés : [`index.html`](index.html) et [`Dockerfile`](Dockerfile).

## 1. Page d'accueil personnalisée — `index.html`

```html
<!DOCTYPE html>
<html lang="fr">
<head>
  <meta charset="UTF-8">
  <title>Exercice 03</title>
</head>
<body>
  <h1>Hello World - Exercice 03</h1>
  <p>Site web personnalisé servi par NGINX dans un conteneur Docker.</p>
</body>
</html>
```

## 2. Image basée sur NGINX — `Dockerfile`

```dockerfile
FROM nginx:alpine
COPY index.html /usr/share/nginx/html/index.html
EXPOSE 80
```

On part de l'image officielle `nginx:alpine` et on remplace la page d'accueil par défaut (`/usr/share/nginx/html/index.html`).

## 3. Construire l'image

```bash
cd rep_exo/exercice-03
docker build -t ex03-site .
```

## 4. Lancer le conteneur

```bash
docker run -d --name ex03-site -p 8082:80 ex03-site
```

> J'ai utilisé le port **8082** parce que 8080 était déjà pris par le conteneur 2048 de l'exercice 2. Si 8080 est libre : `-p 8080:80`.

## 5. Vérification

```bash
curl -s http://localhost:8082
# ...
#   <h1>Hello World - Exercice 03</h1>
# ...
```

Dans le navigateur : **http://localhost:8082** affiche « Hello World - Exercice 03 ».

## Variante sans Dockerfile (copie dans un conteneur existant)

```bash
docker run -d --name ex03-site -p 8082:80 nginx:alpine
docker cp index.html ex03-site:/usr/share/nginx/html/index.html
```

## Nettoyage

```bash
docker rm -f ex03-site
docker rmi ex03-site
```
