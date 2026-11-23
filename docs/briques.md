# Briques Docker (lot #3) : Portainer, WUD, Harbor, registre, Forgejo, Traefik

Ces briques donnent de vraies données aux connecteurs de l'Inventaire Docker, et des dépôts de test
pour la sécurité du code de GRC. Ce sont des logiciels libres ou des éditions gratuites, avec des
images officielles épinglées. Toutes les données sont fictives.

```sh
./lab up docker          # tout le profil (Harbor compris), comptes d'API et données de démonstration
./lab up docker-leger    # sans Harbor ni Forgejo
./lab connect glpi12-b   # connexions « Labo - … » dans l'Inventaire Docker de glpi12-b
./lab seed harbor        # recrée ce qui manque (analyses Trivy relancées, etc.)
./lab reset harbor       # efface les volumes de la brique et la recrée (nouveaux jetons)
```

## Briques

| Brique | Image | Adresse sur le poste | Adresse depuis GLPI (lab-net) | Compte pour GLPI |
|---|---|---|---|---|
| `portainer` | `portainer/portainer-ce:2.45.4`, agent `portainer/agent:2.45.4` | http://localhost:8120 | http://portainer:9000 | jeton d'API de `glpi-lecture` |
| `wud` | `getwud/wud:9.9.0` | http://localhost:8122 | http://wud:3000 | `glpi-lecture` (rôle ro), authentification basique |
| `wud8` | `getwud/wud:8.4.0` | http://localhost:8123 | http://wud8:3000 | `glpi-lecture`, authentification basique |
| `harbor` | `goharbor/*:v2.15.5` (9 services, Trivy compris) | http://localhost:8130 | http://harbor:8130 | compte robot `robot$demo+glpi-lecture` |
| `registry` | `registry:2.8.3` | http://localhost:8135 | http://docker-registry:5000 | `glpi-lecture`, authentification basique |
| `forgejo` | `codeberg.org/forgejo/forgejo:15.0.12` | http://localhost:8140 | http://forgejo:3000 | jeton en lecture de `glpi-lecture` |
| `traefik` | `traefik:v3.7.19` et `traefik:v2.11.63` | API :8145 (v3), :8146 (v2), entrée web :8147 | http://traefik:8080, http://traefik2:8080 | `glpi-lecture`, authentification basique |

Mots de passe, jetons et secrets se trouvent **uniquement dans `.env`** (ignoré par git) et dans
`secrets/` (clés de Harbor, htpasswd), tous deux générés sur le poste. Ne jamais les recopier dans
une issue, une PR ou une capture. Comptes administrateurs : `admin` (Portainer, WUD 9, Harbor),
`lab-admin` (Forgejo).

## Données de démonstration

| Où | Contenu |
|---|---|
| pile `lab-demo` (stack/demo.yml) | nginx 1.25.3 (2 réplicas), httpd 2.4.57, redis 7.0.15, memcached 1.6.21, un service arrêté (0 réplica) ; déployée **par Portainer** au nom de `glpi-lecture`, suivie par WUD (`wud.watch=true`), routée par Traefik (routeurs HTTP et TCP, intergiciels) |
| pile `lab-demo-harbor` (stack/demo-harbor.yml) | httpd, node 18 (fin de support), redis, **tirés de Harbor** (`localhost:8130/demo/…`) : l'Inventaire Docker relie ces services aux vulnérabilités de Harbor |
| Harbor, projet `demo` (public, analyse à l'envoi) | nginx 1.25.3 et 1.25.4, httpd 2.4.57, redis 7.0.15, node 18.20.4 (linux/amd64), analysés par Trivy |
| registre `registry:2` | `demo/nginx` (3 étiquettes), `demo/redis` |
| Forgejo, organisation `demo` | `boutique-web` (npm : lodash, minimist, axios vulnérables), `api-commandes` (pip : Django 3.2.0, requests, PyYAML), `portail-php` (Composer : guzzle, twig) ; étiquette « sécurité » et un ticket de sécurité par dépôt |

## Branchement dans GLPI : `lab connect`

`./lab connect <instance…>` demande aux briques démarrées leurs connexions (crochet `connect`), puis
lance `tools/glpi-connections.php` dans le conteneur GLPI. Ce script :

- crée ou met à jour les connexions de l'Inventaire Docker nommées « Labo - Portainer »,
  « Labo - WUD 9 », « Labo - WUD 8 », « Labo - Harbor », « Labo - Traefik 3 » et « Labo - Traefik 2 ».
  Il passe par la classe du plugin, qui chiffre les secrets avec la clé de l'instance ;
- autorise les contextes du plugin vers les réseaux privés (GLPI 12 les refuse par défaut). Ces
  contextes sont écrits dans `/var/glpi/config/local_define.php`, sur le volume de l'instance.
  GLPI ne lit que `/var/www/glpi/config/local_define.php`, qui n'est pas sur un volume :
  `stack/glpi.yml` y monte donc une inclusion du premier fichier (config Swarm). Une instance
  déployée avant ce montage reçoit une copie provisoire de l'inclusion, qui dure jusqu'au prochain
  `./lab up <instance>`.

Le plugin doit être installé avant le branchement :

```sh
G12=glpi12-b REPO_OVERRIDE=<dossier du plugin> sh /f/Dev/glpi-test-env/deploy-g12.sh dockerinventory
```

Il n'y a pas de connexion pour Forgejo : GRC ne lit que GitHub et GitLab, et aucun plugin n'a de
connecteur Forgejo ou Gitea. Il n'y en a pas non plus pour le registre `registry:2` :
l'Inventaire Docker n'a pas de type de connexion « registre », et lit les registres par Harbor et
par Docker Hub.

## Fonctionnement

- **Crochets** : chaque brique a son `stack/<brique>/hook.sh`, avec les actions `prepare` (secrets,
  avant le déploiement), `seed` (comptes et données, après), `reset` (oubli des jetons) et `connect`.
  Les fonctions communes sont dans `lib/brique.sh`. Tout est rejouable : on vérifie avant de créer.
  Les délais d'attente sont longs (10 à 40 minutes), car le disque F: est lent.
- **Configs et secrets Swarm** : ils sont immuables. Leur nom contient donc une empreinte des
  fichiers (`LAB_CONFIG_VERSION`), si bien qu'un fichier modifié donne une nouvelle config au
  prochain `lab up`.
- **Socket Docker** : l'agent Portainer, WUD et Traefik lisent le socket de Docker Desktop (WUD et
  Traefik en lecture seule). C'est le déploiement officiel de ces logiciels sur Swarm, puisque les
  services Swarm ne peuvent pas être privilégiés (pas de Docker dans Docker). Ils voient donc
  aussi les conteneurs hors labo (g12…), mais :
  - WUD ne suit que les conteneurs marqués `wud.watch=true` ;
  - Traefik ne publie que les services marqués `traefik.enable=true` ;
  - l'utilisateur standard `glpi-lecture` de Portainer ne voit que ce que Portainer lui a donné
    (`lab-demo`, `lab-demo-harbor`).
  L'administrateur de Portainer voit tout : ne s'en servir que pour le labo.
- **Harbor sans son installateur** : `stack/harbor.yml` reprend les services de la composition
  générée par l'installateur officiel (mêmes images `goharbor/*`). Ses fichiers de configuration,
  dans `stack/harbor/`, sont adaptés des modèles de goharbor/harbor (Apache 2.0). Le conteneur de
  journaux est retiré, et le nombre de travailleurs et de connexions réduit. `EXT_ENDPOINT` vaut
  `http://localhost:8130` : le Docker du poste tire ainsi les images de Harbor sans réglage, car
  localhost est un registre HTTP permis d'office. Le projet `demo` est public pour la même raison
  (pas de `docker login`, dont les identifiants iraient sur C:).
- **Copie des images** : `crane` (go-containerregistry) tourne dans un conteneur jetable, sur le
  réseau de la machine virtuelle de Docker. Ses identifiants restent dans `secrets/` le temps de la
  copie, puis sont effacés.
- **Non monté (payant)** : Portainer Business (journal d'activité, rôles fins de
  parime/glpi-docker-inventory#81).

## Robustesse

- Toutes les briques sont des services Swarm (`restart_policy: any`), avec leurs données dans des
  volumes Docker nommés. Leurs tests de santé ont un long délai de démarrage (15 à 30 min), car le
  disque est lent et une relance en pleine initialisation (PostgreSQL de Harbor) casserait tout.
- Essai du 23/11 : arrêt brutal (`docker kill`) des 26 conteneurs des briques et des piles de
  démonstration. Swarm a relancé les 25 services seul, en 7 min 35 s (disque chargé). Aucune
  commande n'a été nécessaire. `./lab connect --import` a ensuite tout relu sans erreur : jetons,
  compte robot, images et analyses étaient intacts.
- `docker desktop restart` n'a pas été essayé : il arrête aussi les instances g12 à g12d de
  glpi-test-env, qui ne repartent pas seules (voir architecture.md). L'essai du lot #2 a montré que
  les services Swarm, eux, repartent après ce redémarrage.

## Vérifier ce que lisent les connecteurs

```sh
./lab connect --import glpi12-a
```

Pour chaque connexion « Labo - … », la commande lance le test de connexion puis l'import, comme le
fait la tâche automatique. Résultat du 23/11 sur glpi12-a (GLPI 12.0.2, Inventaire Docker de main) :

| Connexion | Test | Import |
|---|---|---|
| Portainer | 1 environnement visible avec la clé | 2 piles, 8 services, 1 nœud |
| WUD 9 | WUD 9.9.0, 5 conteneurs suivis | 5 conteneurs, 4 services suivis |
| WUD 8 | WUD 8.4.0, 5 conteneurs suivis | 5 conteneurs, 4 services suivis |
| Traefik 3 et 2 | 3 routes HTTP | 4 routes, 3 signalements |
| Harbor | registre et API acceptent le robot | 2 projets, 4 dépôts, 5 artefacts, tous analysés (de 74 à 98 vulnérabilités par image, dont des critiques) |

## Limites connues

- Portainer CE n'a pas de rôle « lecture seule » : `glpi-lecture` est un utilisateur standard. Son
  jeton permettrait des écritures sur `lab-demo`, mais le plugin n'appelle que des GET.
- `lab-net` est rendu public dans Portainer, sinon un utilisateur standard ne peut pas y rattacher
  une pile.
- WUD vérifie les registres toutes les 6 heures, à cause de la limite des requêtes anonymes de
  Docker Hub.
- Harbor : au premier démarrage, la base Trivy est téléchargée, et les analyses à l'envoi échouent
  tant qu'elle n'est pas prête. `./lab seed harbor` relance les analyses sans rapport.
