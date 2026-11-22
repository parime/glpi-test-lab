# Architecture et choix techniques

## Docker Swarm à un nœud

Le labo tourne sur **Docker Swarm à un nœud**, sur le Docker Desktop (WSL2) du poste, comme prévu
par l'issue #1. `./lab init` l'active si besoin :

```sh
docker network create --driver bridge --subnet 10.211.0.0/16 \
  --opt com.docker.network.bridge.name=docker_gwbridge \
  --opt com.docker.network.bridge.enable_icc=false \
  --opt com.docker.network.bridge.enable_ip_masquerade=true docker_gwbridge
docker swarm init --default-addr-pool 10.210.0.0/16 --default-addr-pool-mask-length 24
```

- **Sans effet sur les conteneurs existants** : `docker swarm init` ne redémarre ni ne modifie les
  conteneurs lancés hors Swarm (g12, g12b à g12d, Wazuh, Portainer…). Vérifié à l'activation :
  les quatre instances g12 ont répondu 200 avant et après.
- **Plages d'adresses choisies** : les réseaux bridge existants occupent déjà presque toute la plage
  172.17-31 de Docker. Le réseau `docker_gwbridge` (10.211.0.0/16) et les réseaux overlay
  (10.210.0.0/16, ingress compris, en /24) sont donc placés hors de cette plage et hors du réseau
  local.
- **Pourquoi Swarm plutôt que `docker compose`** : un même format (fichiers de stack) pour toutes
  les briques, redémarrage automatique des services, réseau overlay commun extensible à d'autres
  nœuds, et les connecteurs (Portainer, Docker Inventory) voient un vrai Swarm.
- **Ce que Swarm change pour les scripts existants** : les conteneurs n'ont plus de nom fixe
  (`lab-glpi12-a_glpi.1.<id>`). Le conteneur GLPI porte donc l'étiquette `lab.instance=<instance>` :
  `./lab container glpi12-a` le retrouve, et les scripts de glpi-test-env le retrouvent à partir de
  `G12=glpi12-a` (voir [compatibilite.md](compatibilite.md)).
- **Revenir en arrière** : `./lab down`, puis `docker swarm leave --force` ; les conteneurs hors
  Swarm ne sont pas concernés.

## Piles

| Pile | Fichier | Services |
|---|---|---|
| `lab-<instance>` (une par ligne de `instances.txt`) | `stack/glpi.yml` | `glpi`, `db` |
| `lab-<brique>` (lots suivants) | `stack/<brique>.yml` | selon la brique |

`lab` ne manipule que les piles dont le nom commence par `lab-`.

## Réseaux

- `lab-net` : overlay commun, attachable, créé par `./lab init`. Chaque GLPI y est joignable sous le
  nom de son instance (`glpi12-a`…) ; les briques des lots suivants s'y rattachent pour que GLPI
  joigne les connecteurs par leur nom.
- `lab-<instance>_default` : overlay privé de l'instance ; la base (`db`) n'est joignable que par
  son GLPI.
- Pas de frontal HTTP (Traefik) à ce stade : chaque service publie un **port fixe** sur localhost
  ([ports.md](ports.md)), ce que les scripts existants attendent (`G12_URL=http://localhost:<port>`).
  Un frontal par nom d'hôte pourra s'ajouter comme brique sans changer les ports.

## Données

Chaque instance a trois **volumes Docker nommés**, dans le disque de Docker Desktop
(`F:\Docker`, donc sur F:) :

| Volume | Monté sur | Contenu |
|---|---|---|
| `lab-<instance>_db` | `/var/lib/mysql` (MariaDB) | base |
| `lab-<instance>_var` | `/var/glpi` | configuration (dont `config_db.php`, `glpicrypt.key`), fichiers, journaux |
| `lab-<instance>_plugins` | `/var/www/glpi/plugins` | plugins déployés par `deploy-g12.sh` |

`F:\Dev\glpi-test-lab-data` reçoit les **sauvegardes** lisibles depuis Windows :
`./lab backup <instance|profil>` y écrit `backups/<instance>-<date>/` (base en SQL compressé,
`/var/glpi` et plugins en archives tar).

### Pourquoi pas de dossier de Windows pour les données

La première version posait les volumes dans `F:\Dev\glpi-test-lab-data\<instance>\` (montage du
disque Windows dans la machine virtuelle de Docker Desktop, en 9p). Après un redémarrage de Docker
Desktop, le labo ne repartait plus :

- MariaDB ne sait pas synchroniser ses fichiers sur ce montage (`Can't sync file … Errcode: 5
  "Input/output error"`, `Errcode: 14 "Bad address"`) ; un arrêt brutal y laisse ses tables système
  Aria corrompues (`Got error '126 "Index is corrupted"' for './mysql/proc.MAI'`) et
  `mariadb-install-db` échoue ensuite à chaque relance ;
- au redémarrage, tant que le partage de `F:` n'est pas prêt, les tâches Swarm qui le montent
  restent « Preparing » et leurs essais répétés ralentissent tout le démon Docker (même un
  `docker run alpine true` ne démarrait plus).

Les volumes Docker ordinaires (ext4 dans le disque virtuel) n'ont aucun de ces problèmes. Essai du
22/11 : `./lab up glpi`, puis `docker desktop restart`. Swarm a relancé seul les six services, et
les trois instances ont répondu de nouveau en 200 au bout de 13 minutes (disque chargé), sans
aucune commande. Leurs plugins étaient toujours activés.

À noter pour la bascule (#7) : au même redémarrage, les conteneurs hors Swarm en
`restart: unless-stopped` (g12, g12b à g12d, Portainer, WUD, Harbor, k3s) **ne sont pas repartis
seuls**. Il a fallu les relancer avec `docker start`. Les services Swarm, eux, repartent toujours.

### Autres points

- Le dossier des plugins est un volume : quand Swarm relance une tâche (nouveau conteneur), les
  plugins déployés sont conservés.
- MariaDB s'arrête proprement (`stop_grace_period` d'une minute) et écrit son journal à chaque
  transaction, synchronisé une fois par seconde (`innodb_flush_log_at_trx_commit=2`) : un arrêt de
  Docker Desktop ne perd rien, une coupure de courant au plus une seconde.
- **Disque lent** : `F:` est un disque dur, partagé avec le disque de Docker Desktop et toutes les
  instances de glpi-test-env. La première installation de GLPI y prend de 15 à 45 minutes quand il
  est chargé (contre quelques minutes sur SSD) ; `lab up` attend jusqu'à 60 minutes
  (`LAB_INSTALL_TIMEOUT`, en pas de 5 secondes). Ensuite l'instance se garde : `lab down` puis
  `lab up`, ou un redémarrage de Docker Desktop, la relancent en une à deux minutes.
- Ce qu'un script copie dans `/tmp` du conteneur (par exemple les dépendances de test de
  `prepare-g12-test-vendors.sh`) est perdu si Swarm relance la tâche : relancer le script.

## Installation de GLPI

L'image officielle `glpi/glpi` installe GLPI au premier démarrage (`GLPI_INSTALL_MODE=DOCKER`,
attente de la base, `database:install`). `lab up` attend ensuite que l'instance réponde 200, puis,
une seule fois (fichier `/var/glpi/config/.lab-initialise`) :

- langue `fr_FR` (`config:set language`, ou `glpi:config:set` selon la version) ;
- `url_base` et `url_base_api` = `http://localhost:<port>`.

Comptes par défaut de GLPI : glpi/glpi (super-admin), tech/tech, normal/normal, post-only/postonly.

## Secrets

`./lab init` copie `.env.example` en `.env` (ignoré par git) et génère les mots de passe MariaDB
(`LAB_DB_ROOT_PASSWORD`, `LAB_DB_PASSWORD`). `lab` les transmet aux piles par l'environnement.
L'image GLPI ne lit pas ses identifiants de base dans un fichier, d'où l'usage de variables plutôt
que de secrets Swarm.

## Ressources : au plus juste

Règle du labo : **rien de surdimensionné**. Chaque service de chaque fichier de stack a des limites
`deploy.resources` (mémoire et CPU), vérifiées par la CI, et une réservation de mémoire :

| Service | Limite mémoire (`.env`) | Limite CPU | Réservation | Mesuré en usage |
|---|---|---|---|---|
| GLPI | 768 Mio (`LAB_GLPI_MEMORY`) | 1,5 cœur | 128 Mio | 135 à 160 Mio |
| MariaDB | 320 Mio (`LAB_DB_MEMORY`) | 1 cœur | 128 Mio | 130 à 220 Mio (tampon de 128 Mio) ; tampon réduit à 64 Mio |

MariaDB tourne aussi sans `performance_schema`, avec 50 connexions au plus et un journal de 48 Mio.
Mesures : [memoire.md](memoire.md).
