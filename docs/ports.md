# Ports

Tous les services sont publiés sur `localhost` par le réseau ingress de Swarm.

| Plage | Usage |
|---|---|
| 8090 à 8099 | **réservée à glpi-test-env** (scenario 8090, g12 8092, g12b 8093, g12c 8094, g12d 8095) |
| 8100 à 8109 | instances GLPI 12 du labo |
| 8110 à 8119 | instances GLPI 11 du labo |
| 8120 à 8199 | autres briques du labo (lots #3 à #8) |

## Attribués

| Port | Pile | Service |
|---|---|---|
| 8101 | lab-glpi12-a | GLPI 12.0.2 |
| 8102 | lab-glpi12-b | GLPI 12.0.2 |
| 8111 | lab-glpi11-a | GLPI 11.0.13 |

## Déjà pris sur le poste (hors labo, à éviter)

514/udp, 1514-1515, 3010, 6445, 8025, 8080, 8443, 8880, 9200, 9910, 9943, 55000 (Wazuh, WUD,
Portainer, Harbor, k3s… lancés hors du labo).
