# Mémoire et disque par profil

## Méthode

`./lab mem` additionne la mémoire des conteneurs de chaque pile (`docker stats`, mémoire
résidente vue par Docker, cache de pages compris). Mesures du 22/11, Docker Desktop (WSL2) avec
16 Gio attribués à la machine virtuelle, poste chargé (instances g12, Wazuh, Harbor, k3s… en
marche à côté).

## Mesures

MESURES

## Plafonds

| Conteneur | Plafond (`.env`) | Remarque |
|---|---|---|
| GLPI | `LAB_GLPI_MEMORY=1G` | Apache + PHP ; monte pendant `plugin:install` et les tests PHPUnit |
| MariaDB | `LAB_DB_MEMORY=512M` | tampon InnoDB `LAB_DB_BUFFER_POOL=128M`, suffisant pour une base de test |

Un plafond atteint fait redémarrer le conteneur par Swarm : relever le plafond plutôt que de le
retirer.

## Disque

DISQUE
