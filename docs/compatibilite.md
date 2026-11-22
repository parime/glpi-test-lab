# Compatibilité avec glpi-test-env

Les agents prennent une instance avec `grc-lock.sh take-any`, y déploient un plugin avec
`deploy-g12.sh` et lancent les tests avec `test-g12.sh`, scripts de `F:\Dev\glpi-test-env` (hors de
ce dépôt). Le labo s'y branche **sans changer le comportement par défaut** : il faut le demander.

## Modification proposée

Fichier [compat/glpi-test-env.patch](../compat/glpi-test-env.patch), appliqué le 22/11 sur le poste
(copie des originaux : `F:\Dev\glpi-test-env\.sauvegarde-avant-lab-20261122\`). Pour l'appliquer
ailleurs :

```sh
cd /f/Dev/glpi-test-env && patch -p1 < /f/Dev/glpi-test-lab/compat/glpi-test-env.patch
```

### `deploy-g12.sh`, `test-g12.sh`, `prepare-g12-test-vendors.sh`

Six lignes ajoutées en tête, rien d'autre : si `G12` ne désigne pas un conteneur existant, le
script cherche le conteneur GLPI de l'instance du labo de ce nom (étiquette `lab.instance`).

```sh
if [ -n "${G12:-}" ] && ! docker inspect --type container "$G12" >/dev/null 2>&1; then
  lab_c=$(docker ps -q -f "label=lab.instance=$G12" -f label=lab.role=glpi | head -1)
  [ -n "$lab_c" ] || { echo "instance $G12 introuvable (ni conteneur, ni instance du labo en marche)" >&2; exit 1; }
  G12=$lab_c
fi
```

Sans `G12`, ou avec `g12`, `g12b`, `g12c`, `g12d`, les scripts font exactement la même chose
qu'avant.

### `tools/grc-lock.sh`

Deux variables facultatives :

| Variable | Effet |
|---|---|
| `GRC_LOCK_LAB=1` | `take-any` et `status` proposent aussi les instances du labo en marche (lues dans `F:\Dev\glpi-test-lab\instances.txt`), après g12b à g12d |
| `GRC_LOCK_LAB=only` | seulement les instances du labo |
| `GRC_LOCK_GLPI=11` (ou `12`) | seulement les instances de cette version majeure |
| `GRC_LOCK_LAB_DIR` | emplacement du dépôt du labo (défaut `/f/Dev/glpi-test-lab`) |

Une instance du labo n'est proposée qu'une fois installée et réglée par `lab up` (fichier témoin
`/var/glpi/config/.lab-initialise`), jamais pendant sa première installation. En mode labo,
`take-any` exporte en plus `G12_GLPI` (11 ou 12). Les verrous restent les mêmes
dossiers (`F:\Dev\glpi-test-env\.grc-lock-<instance>`), avec les mêmes règles de reprise. Sans ces
variables, la sortie et le choix des instances sont identiques à l'ancienne version. Le fichier a
été remplacé d'un bloc (renommage) pour ne pas gêner les `take-any` en attente pendant la mise à
jour.

## Utilisation par un agent

Tout dans le même appel Bash, comme aujourd'hui :

```sh
# GLPI 11 (seulement dans le labo)
eval "$(GRC_LOCK_LAB=1 GRC_LOCK_GLPI=11 sh /f/Dev/glpi-test-env/tools/grc-lock.sh take-any)"
cd /f/Dev/glpi-test-env && REPO_OVERRIDE=<worktree> sh deploy-g12.sh grcmanager
sh prepare-g12-test-vendors.sh        # une fois par instance (dépendances de test dans /tmp)
sh test-g12.sh grcmanager 'php vendor/bin/phpunit -c phpunit-integration.xml.dist'
sh /f/Dev/glpi-test-env/tools/grc-lock.sh release "$G12"
```

Sans verrou (par exemple pour un essai à la main) : `G12=glpi12-a sh deploy-g12.sh grcmanager`.

## Différences avec g12, g12b à g12d

| | g12, g12b à g12d | instances du labo |
|---|---|---|
| Origine | copies de g12 (`g12-slot.sh`) avec données de démonstration | installation neuve de GLPI (`lab up`, `lab reset`) |
| Conteneur | nom fixe | tâche Swarm, retrouvée par l'étiquette `lab.instance` |
| Dépendances de test (`/tmp/grcdev.tar`…) | présentes | à poser avec `prepare-g12-test-vendors.sh` (perdues si Swarm relance la tâche) |
| Plugins | dans le conteneur | volume (`F:\Dev\glpi-test-lab-data\<instance>\plugins`), conservés au redémarrage |
| Données de démonstration | `seed-demo-data.php` déjà passé | à charger (lot à venir) |

## Bascule (lot #7)

Quand les instances du labo auront fait leurs preuves : `GRC_LOCK_LAB=1` par défaut dans
`grc-lock.sh`, données de démonstration et dépendances de test chargées par `lab up`, consigne des
agents mise à jour, puis arrêt de g12b à g12d et de g12.
