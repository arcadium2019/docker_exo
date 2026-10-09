# Exercice Docker #4 — Deux conteneurs qui communiquent

## 1. Créer un réseau dédié

```bash
docker network create ex04-net
docker network ls | grep ex04
```

C'est un réseau de type `bridge` créé par l'utilisateur. Contrairement au bridge par défaut, il fournit un **DNS interne** : les conteneurs peuvent se joindre par leur nom.

## 2. Créer un premier conteneur et y installer `ping`

```bash
docker run -dit --name ex04-c1 --network ex04-net ubuntu:24.04 bash
docker exec -it ex04-c1 bash
```

Dans le conteneur :

```bash
apt-get update
apt-get install -y iputils-ping
which ping        # /usr/bin/ping
exit
```

## 3. Sauvegarder l'image avec ping

```bash
docker commit ex04-c1 ubuntu-ping
docker images ubuntu-ping
```

## 4. Créer le second conteneur à partir de cette image et le connecter au réseau

Pour montrer les deux méthodes, ce conteneur est créé **sans** réseau puis connecté ensuite :

```bash
docker run -dit --name ex04-c2 ubuntu-ping bash
docker network connect ex04-net ex04-c2
```

(Équivalent en une commande : `docker run -dit --name ex04-c2 --network ex04-net ubuntu-ping bash`)

Le second conteneur a déjà `ping`, sans avoir à le réinstaller.

## 5. Vérifier que les deux conteneurs sont sur le même réseau

```bash
docker network inspect ex04-net --format '{{range .Containers}}{{.Name}} {{.IPv4Address}}{{"\n"}}{{end}}'
# ex04-c2 172.18.0.3/16
# ex04-c1 172.18.0.2/16
```

(ou simplement `docker network inspect ex04-net`, section `Containers`)

## 6. Tester la communication et la résolution DNS par nom

Depuis `ex04-c1` vers `ex04-c2` :

```bash
docker exec -it ex04-c1 ping -c 3 ex04-c2
# PING ex04-c2 (172.18.0.3) 56(84) bytes of data.
# 64 bytes from ex04-c2.ex04-net (172.18.0.3): icmp_seq=1 ttl=64 time=0.062 ms
# ...
# 3 packets transmitted, 3 received, 0% packet loss
```

Depuis `ex04-c2` vers `ex04-c1` :

```bash
docker exec -it ex04-c2 ping -c 3 ex04-c1
# PING ex04-c1 (172.18.0.2) 56(84) bytes of data.
# 64 bytes from ex04-c1.ex04-net (172.18.0.2): icmp_seq=1 ttl=64 time=0.044 ms
# ...
# 3 packets transmitted, 3 received, 0% packet loss
```

Le nom du conteneur est résolu en adresse IP par le DNS intégré de Docker (`127.0.0.11` dans les conteneurs), et le ping passe dans les deux sens.

> Sur le réseau `bridge` par défaut, `ping ex04-c2` échouerait (`Name or service not known`) : la résolution par nom n'existe que sur les réseaux créés par l'utilisateur.

## Nettoyage

```bash
docker rm -f ex04-c1 ex04-c2
docker network rm ex04-net
docker rmi ubuntu-ping
```
