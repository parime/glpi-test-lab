# glpi-test-lab

Infrastructure de test des plugins GLPI de parime, **reproductible et versionnée** : instances
GLPI 11 et 12, puis (lots suivants) les logiciels que les connecteurs des plugins interrogent
(Portainer, What's Up Docker, Harbor, Forgejo, Zabbix, Wazuh, FreePBX, Active Directory, pfSense…).
Plan d'ensemble : issue #1. Toutes les données sont fictives.

## Principes

- **Tout en code** : un fichier de stack par brique (`stack/`), une commande unique (`lab`), des
  listes déclaratives (`instances.txt`, `profiles.txt`). Rien n'est monté à la main.
- **Uniquement des logiciels gratuits** : logiciels open source, versions d'évaluation gratuites ou
  offres gratuites. Aucune licence payante ni service cloud payant.
- **Par profils** : on ne démarre que les briques utiles au test en cours (la machine a 32 Go de RAM,
  partagés avec le reste).
- **Tout sur F:** : les données vivantes sont dans des volumes Docker (disque de Docker Desktop,
  `F:\Docker`), les sauvegardes dans `F:\Dev\glpi-test-lab-data`. Rien sur C:.
- **Rien de surdimensionné** : chaque service a des limites `deploy.resources` (mémoire et CPU)
  taillées d'après les mesures, et la CI refuse un service sans limite.
- **Survit aux redémarrages** : après un redémarrage du PC ou de Docker Desktop, Swarm relance
  seul toutes les piles démarrées ; aucune commande à refaire.
- **Secrets locaux** : les mots de passe sont générés dans `.env` (ignoré par git), jamais commités.
- **Versions épinglées** : images officielles `glpi/glpi` et `mariadb` à une version précise.
- **Compatible avec l'existant** : les instances du labo se prennent avec `grc-lock.sh take-any` et
  se visent avec `G12=<instance>` dans `deploy-g12.sh` et `test-g12.sh` (voir
  [docs/compatibilite.md](docs/compatibilite.md)). Les instances g12, g12b, g12c et g12d de
  glpi-test-env ne sont pas touchées ; leur remplacement est le lot #7.

## Architecture

```
Windows 11 (Git Bash)          Docker Desktop (WSL2), Docker Swarm à un nœud
  ./lab up glpi   ───────────►  pile lab-glpi12-a : glpi (glpi/glpi:12.0.2) + db (mariadb:11.8.9)
                                pile lab-glpi12-b : glpi (glpi/glpi:12.0.2) + db
                                pile lab-glpi11-a : glpi (glpi/glpi:11.0.13) + db
  http://localhost:8101 ──────► port publié par Swarm (réseau ingress)
                                réseau overlay lab-net : toutes les briques (GLPI joint les
                                connecteurs par leur nom), un réseau privé par instance pour sa base
volumes Docker lab-<instance>_{db,var,plugins}  (disque de Docker Desktop, F:\Docker)
F:\Dev\glpi-test-lab-data\backups  ◄── ./lab backup (base SQL, /var/glpi, plugins)
```

- **Docker Swarm à un nœud** (choix de l'issue #1, détails dans [docs/architecture.md](docs/architecture.md)) :
  une pile (`docker stack`) par instance GLPI ou par brique, nommée `lab-<nom>`.
- **Une MariaDB par instance**, joignable seulement par son GLPI.
- **Ports fixes** sur localhost, par plages : [docs/ports.md](docs/ports.md).
- **Installation automatique** de GLPI par l'image officielle (comptes glpi/glpi, tech/tech,
  normal/normal, post-only/postonly), puis `lab` règle l'interface en français et l'adresse de
  l'instance.

## Instances GLPI

Déclarées dans [instances.txt](instances.txt) :

| Instance | Version | Adresse | Connexion |
|---|---|---|---|
| glpi12-a | GLPI 12.0.2 | http://localhost:8101 | glpi / glpi |
| glpi12-b | GLPI 12.0.2 | http://localhost:8102 | glpi / glpi |
| glpi11-a | GLPI 11.0.13 | http://localhost:8111 | glpi / glpi |

Ajouter une instance : une ligne dans `instances.txt` (nom, version, port libre de la plage), puis
`./lab up <nom>`.

## Profils et mémoire

Profils déclarés dans [profiles.txt](profiles.txt). Mémoire réellement utilisée, mesurée avec
`./lab mem` (détails et méthode : [docs/memoire.md](docs/memoire.md)) :

| Profil | Contenu | Au repos | GRC déployé, pages ouvertes |
|---|---|---|---|
| `glpi12-a` (une instance) | GLPI 12 + MariaDB | 265 Mio | 375 Mio |
| `glpi11` | 1 instance GLPI 11 | 210 Mio | 370 Mio |
| `glpi12` | 2 instances GLPI 12 | 530 Mio | 690 Mio |
| `glpi` | 3 instances | 740 Mio | 950 Mio |

En pratique : **0,4 Gio par instance GLPI en usage**. Limites par conteneur : GLPI 768 Mio et
1,5 cœur, MariaDB 320 Mio et 1 cœur (réglables dans `.env` : `LAB_GLPI_MEMORY`, `LAB_DB_MEMORY`).

**Disque lent** : F: est un disque dur partagé avec Docker et glpi-test-env. La première
installation d'une instance y prend de 25 à 45 minutes, l'installation des tables de GRC de 9 à
19 minutes ; ensuite les pages répondent en 1 à 2 secondes et `lab down` / `lab up` gardent tout.

## Démarrage rapide

Depuis Git Bash :

```sh
cd /f/Dev/glpi-test-lab
./lab init              # .env et mots de passe, Swarm, réseau lab-net (une seule fois)
./lab up glpi           # toutes les instances GLPI (quelques minutes la première fois)
./lab status            # état, HTTP, verrous, mémoire
```

Tester un plugin sur une instance du labo, comme sur g12 :

```sh
eval "$(GRC_LOCK_LAB=1 GRC_LOCK_GLPI=11 sh /f/Dev/glpi-test-env/tools/grc-lock.sh take-any)"   # G12=glpi11-a
cd /f/Dev/glpi-test-env && REPO_OVERRIDE=<worktree> sh deploy-g12.sh grcmanager
sh /f/Dev/glpi-test-env/tools/grc-lock.sh release "$G12"
```

## Commande `lab`

| Commande | Effet |
|---|---|
| `./lab init` | crée `.env` (mots de passe), active Swarm si besoin, crée le réseau `lab-net` |
| `./lab up <profil…>` | démarre des profils, briques ou instances, attend l'installation de GLPI |
| `./lab down [--force] [<profil…>]` | arrête (tout le labo sans argument) ; les données restent |
| `./lab status` | instances (version, adresse, HTTP, verrou, mémoire) et autres briques |
| `./lab reset [--force] <instance>` | réinstalle l'instance de zéro (base, fichiers et plugins effacés) |
| `./lab logs <instance\|brique> [service] [--follow]` | journaux |
| `./lab list` | profils, instances et briques |
| `./lab mem` | mémoire utilisée par pile et au total |
| `./lab container <instance>` | conteneur GLPI de l'instance, pour `docker exec` |
| `./lab backup <instance\|profil>` | sauvegarde base, `/var/glpi` et plugins dans `F:\Dev\glpi-test-lab-data\backups` |

`down` et `reset` refusent d'arrêter une instance verrouillée par un agent (`grc-lock.sh`), sauf
avec `--force`. `lab` ne touche qu'aux piles `lab-*` : jamais aux conteneurs de glpi-test-env.

## Contenu du dépôt

| Chemin | Rôle |
|---|---|
| `lab` | commande unique (bash) |
| `instances.txt` | instances GLPI (nom, version, port) |
| `profiles.txt` | profils de `lab up` |
| `stack/` | un fichier de stack par brique (`glpi.yml` : une instance GLPI + sa base) |
| `.env.example` | modèle des réglages locaux (`.env` est généré) |
| `docs/` | architecture, ports, mémoire, compatibilité, procédures |
| `compat/` | modifications proposées aux scripts de glpi-test-env |

## Documentation

- [Architecture et choix techniques](docs/architecture.md)
- [Ports](docs/ports.md)
- [Mémoire par profil](docs/memoire.md)
- [Compatibilité avec glpi-test-env (verrous, déploiement, tests)](docs/compatibilite.md)
- [Ajouter une brique](docs/ajouter-une-brique.md)
