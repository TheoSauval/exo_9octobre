# Exercices Docker - Ynov

Exercices réalisés avec Docker Desktop (macOS, Apple Silicon).

| # | Sujet | Rendu | Fichiers |
|---|---|---|---|
| 1 | Image Ubuntu + NGINX (`docker commit`) | `exercice-docker-1.md` | - |
| 2 | Jeu 2048 depuis Docker Hub | `exercice-docker-2.md` | - |
| 3 | Site NGINX personnalisé (Dockerfile) | `exercice-docker-3.md` | `exo-03/` |
| 4 | Réseau + DNS entre deux conteneurs | `exercice-docker-4.md` | - |
| 5 | MySQL + Adminer (volume, restart, compose) | `exercice-docker-5.md` | `exo-05/` |
| 6 | Conteneur de dev NGINX avec volume `-v` | `exercice-docker-6.md` | `exo-06/` |
| 7 | Image MySQL `kennelDB` pré-remplie | `exercice-docker-7.md` | `exo-07/` |
| 8 | API Spring Boot CRUD + PostgreSQL | `exercice-docker-8.md` | `exo-08/` |
| 9 | API CRUD + API de logs (compose) | `exercice-docker-9.md` | `exo-09/` |
| 10 | Compose : variables d'environnement (`.env`) et volumes | `exercice-docker-10.md` | `exo-10/` |
| 11 | TP01 : optimisation d'une image « historique » (multi-stage, non-root, healthcheck, distroless) | `exercice-docker-11.md` | `exo-11/` |
| 12 | TP04 : stack Compose d'entreprise (base, surcharges dev/prod, Traefik, secrets, Makefile) | `exercice-docker-12.md` | `exo-12/` |
| 13 | TP05 : persistance, sauvegarde/restauration, montée PostgreSQL 14 → 16 | `exercice-docker-13.md` | `exo-13/` |
| 14 | TP08 : durcissement (audit, capabilities, proxy de socket, daemon.json) | `exercice-docker-14.md` | `exo-14/` |
| 15 | TP09 : CI/CD et déploiement sans interruption (pipeline, cosign, rolling update) | `exercice-docker-15.md` | `exo-15/` |

Captures navigateur : `captures/`.

## Remarque

Les exercices 1 à 6, 9 et 10 utilisent tous le port 8080 : un seul peut tourner à la fois.
L'exercice 12 utilise le port 80 (Traefik) ; ses ports de debug se règlent dans `exo-12/.env`.
