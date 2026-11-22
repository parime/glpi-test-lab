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
