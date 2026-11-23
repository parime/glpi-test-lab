# Mémoire et disque par profil

## Méthode

`./lab mem` additionne la mémoire des conteneurs de chaque pile (`docker stats`, mémoire
résidente vue par Docker, cache de pages compris). Mesures du 22/11, Docker Desktop (WSL2) avec
16 Gio attribués à la machine virtuelle, poste chargé (instances g12, Wazuh, Harbor, k3s… en
marche à côté).

## Mesures

Mémoire résidente, en Mio (GLPI + MariaDB) :

| Profil | Contenu | Installé, au repos | GRC déployé, connexion et 6 pages ouvertes |
|---|---|---|---|
| une instance GLPI 12 (`glpi12-a`) | GLPI 12.0.2 + MariaDB | 265 | 375 (155 + 220) |
| `glpi11` | GLPI 11.0.13 + MariaDB | 210 (pendant l'installation) | 370 (160 + 210) |
| `glpi12` | 2 instances GLPI 12 | 530 | 690 (une seule avec GRC) |
| `glpi` | les 3 instances | 740 | 950 (deux avec GRC) |

À retenir pour planifier : **compter 0,4 Gio par instance GLPI en usage**, 0,3 Gio au repos.
Ces mesures ont été prises avec un tampon InnoDB de 128 Mio ; il est maintenant de 64 Mio
(`performance_schema` coupé), ce qui retire environ 60 Mio par base.

Pour comparaison, une instance g12 de glpi-test-env (base de démonstration chargée, plusieurs
plugins) occupe de 0,6 à 1 Gio.

### Briques Docker (lot #3)

Mesures du 23/11 (`./lab mem`), après `./lab up` et l'amorçage (comptes, images copiées, analyses
Trivy terminées). Le disque était chargé (3 instances GLPI, g12 à g12d, Wazuh et la VM Proxmox en
marche à côté). Les valeurs sont la mémoire résidente, cache de pages compris.

| Brique | Services | Au repos, amorcée | Limites mémoire (somme) |
|---|---|---|---|
| `portainer` | serveur + agent | 127 Mio | 352 Mio |
| `wud` | WUD 9.9 | 81 Mio | 256 Mio |
| `wud8` | WUD 8.4 | 90 Mio | 192 Mio |
| `harbor` | 9 services (core 61, PostgreSQL 79, registre 68, Trivy 27, jobservice 22…) | 276 Mio | 2 080 Mio, dont Trivy 768 |
| `registry` | registry:2 | 9 Mio | 128 Mio |
| `forgejo` | Forgejo (SQLite) | 202 Mio | 384 Mio |
| `traefik` | Traefik 3 + Traefik 2 | 72 Mio | 192 Mio |
| `vaultwarden` (hors profil `docker`) | Vaultwarden 1.37 (SQLite) | 44 Mio | 128 Mio |
| piles `lab-demo` et `lab-demo-harbor` | 8 petits services | 34 + 31 Mio | 272 Mio (par réplica) |
| **profil `docker`** | tout | **environ 0,9 Gio** | |
| **profil `docker-leger`** | sans Harbor ni Forgejo | **environ 0,4 Gio** | |

À retenir : **compter 1 Gio pour le profil `docker`**. Pendant une analyse, Trivy charge sa base
en mémoire : son pic n'a pas été mesuré, il est plafonné à 768 Mio par l'adaptateur Trivy. C'est bien
moins que les 2 à 4 Go annoncés pour Harbor (#3), parce que le conteneur de journaux est retiré
et que le nombre de travailleurs et de connexions est réduit.

Chaque service a une limite de mémoire et de CPU et une réservation (`deploy.resources`, vérifiées
par la CI). Les limites valent environ deux à trois fois l'usage mesuré, pour laisser de la marge
aux pics (premier démarrage, analyses, imports).

### Durées (disque F: chargé, 23/11)

| Étape | Durée |
|---|---|
| Portainer, WUD, registre, Traefik : `lab up` puis amorçage | 3 à 8 min chacun |
| Harbor, premier démarrage (initialisation de PostgreSQL, synchronisation du disque) | environ 40 min |
| Harbor, copie des 5 images et analyses Trivy (base Trivy téléchargée au premier passage) | 10 min environ |
| Forgejo, premier démarrage et dépôts de démonstration | 5 min environ |
| Reprise après l'arrêt brutal (`docker kill`) des 26 conteneurs des briques : 25 services de nouveau prêts, sans commande, données et jetons intacts | 7 min 35 s |

## Plafonds

Au plus juste, d'après les mesures ci-dessus (environ deux fois l'usage mesuré, pour
`plugin:install` et les tests PHPUnit) :

| Conteneur | Limite mémoire (`.env`) | Limite CPU | Réservation | Remarque |
|---|---|---|---|---|
| GLPI | `LAB_GLPI_MEMORY=768M` | 1,5 | 128 Mio | Apache + PHP |
| MariaDB | `LAB_DB_MEMORY=320M` | 1 | 128 Mio | tampon InnoDB `LAB_DB_BUFFER_POOL=64M`, 50 connexions |

Un plafond atteint fait redémarrer le conteneur par Swarm : relever le plafond plutôt que de le
retirer.

## Disque

| Élément | Taille | Où |
|---|---|---|
| Images (`glpi/glpi:12.0.2`, `glpi/glpi:11.0.13`, `mariadb:11.8.9`) | environ 1,7 Gio chacune pour GLPI | disque de Docker (`F:\Docker`) |
| Base GLPI 12 vide (avec GRC) | 295 Mio | `F:\Dev\glpi-test-lab-data\<instance>\db` |
| `/var/glpi` | 6 Mio | `…\<instance>\var` |
| Plugins (GRC avec ses dépendances de production) | 76 Mio | `…\<instance>\plugins` |

### Durées mesurées (disque dur F: très chargé, 22/11)

| Étape | GLPI 12 | GLPI 11 |
|---|---|---|
| Première installation (`lab up`, base vide) | 25 à 45 min | 38 min |
| `deploy-g12.sh grcmanager` (installation des tables du plugin) | 19 min | 9 min |
| Page GLPI ou GRC une fois connecté (cache chaud) | 1 à 2 s | 1 à 2 s |

Les durées viennent presque toutes de la création des tables sur un disque dur partagé (taux
d'occupation de F: relevé à plus de 400 %). Sur SSD, compter quelques minutes.
