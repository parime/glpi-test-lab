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
| `lab-<instance>` (une par ligne de `instances.txt`) | `stack/glpi.yml` (+ `stack/glpi.bind.yml`) | `glpi`, `db` |
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

Par défaut (`LAB_STORAGE=bind`), chaque instance a ses données dans
`F:\Dev\glpi-test-lab-data\<instance>\` :

| Dossier | Monté sur | Contenu |
|---|---|---|
| `db` | `/var/lib/mysql` (MariaDB) | base |
| `var` | `/var/glpi` | configuration (dont `config_db.php`, `glpicrypt.key`), fichiers, journaux |
| `plugins` | `/var/www/glpi/plugins` | plugins déployés par `deploy-g12.sh` |

Les volumes sont des volumes Docker nommés (`lab-<instance>_db`…) de type « bind » vers ces
dossiers ; la machine virtuelle de Docker Desktop voit `F:\` sous `/run/desktop/mnt/host/f`.

- Le dossier des plugins est un volume : quand Swarm relance une tâche (nouveau conteneur), les
  plugins déployés sont conservés.
- MariaDB voit un système de fichiers insensible à la casse et passe d'elle-même en
  `lower_case_table_names=2` ; GLPI fonctionne ainsi.
- Les fichiers de Windows sont plus lents que le disque de la machine virtuelle. `LAB_STORAGE=volume`
  dans `.env` utilise des volumes Docker ordinaires (dans `F:\Docker`), plus rapides mais invisibles
  depuis l'explorateur ; à choisir avant `lab up` ou avant un `lab reset`. La valeur peut aussi
  être donnée pour une seule commande : `LAB_STORAGE=volume ./lab reset glpi12-b`. Une instance
  garde ensuite ce mode : la redéployer dans l'autre mode relancerait ses conteneurs sur des volumes
  différents.
- **Disque lent** : `F:` est un disque dur, partagé avec le disque de Docker Desktop et toutes les
  instances de glpi-test-env. La première installation de GLPI y prend de 15 à 45 minutes quand il
  est chargé (contre quelques minutes sur SSD) ; les deux modes de stockage se valent (mesure du
  22/11 : 66 et 41 tables créées en 3 minutes). MariaDB tourne donc sans synchronisation disque à
  chaque transaction, et `lab up` attend jusqu'à 60 minutes (`LAB_INSTALL_TIMEOUT`, en pas de
  5 secondes). Ensuite, l'instance se garde : `lab down` puis `lab up` redémarrent en une minute.
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

## Limites mémoire

Chaque conteneur a un plafond (`deploy.resources.limits.memory`) réglable dans `.env` : 1 Gio par
GLPI, 512 Mio par MariaDB (tampon InnoDB de 128 Mio). Mesures : [memoire.md](memoire.md).
