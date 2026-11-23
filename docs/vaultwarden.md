# Brique Vaultwarden : comptes à privilèges de GRC

Vaultwarden est un serveur libre compatible Bitwarden (image officielle `vaultwarden/server`,
édition alpine). La brique sert à tester en vrai la page **GRC > Accès et comptes > Comptes
privilégiés** (parime/glpi-iso27001-management#859). Vaultwarden n'a pas l'API publique
d'organisation de Bitwarden. GRC lit donc ses données par l'import CSV, à partir d'un export fait
avec l'interface en ligne de commande officielle `bw`. Toutes les données sont factices.

```sh
./lab up vaultwarden                         # serveur, certificats, organisation de démonstration
bash stack/vaultwarden/hook.sh export        # membres.csv et elements.csv dans F:\Dev\glpi-test-lab-data\vaultwarden
bash stack/vaultwarden/grc/essai.sh <conteneur GLPI> <adresse GLPI> --purger   # essai de bout en bout
./lab reset vaultwarden                      # efface l'organisation et la recrée
```

## Le service

| | |
|---|---|
| Image | `vaultwarden/server:1.37.5-alpine` (un seul conteneur, base SQLite dans le volume `lab-vaultwarden_data`) |
| Adresse sur le poste | https://localhost:8150 (coffre web), https://localhost:8150/admin (administration) |
| Adresse depuis lab-net | https://vaultwarden:80 |
| Mémoire | 44 Mio au repos, limite 128 Mio et 0,5 cœur |
| Comptes | administration : `LAB_VAULTWARDEN_ADMIN_PASSWORD` de `.env` ; membres : `LAB_VAULTWARDEN_DEMO_PASSWORD` (mot de passe maître commun) |

- **HTTPS obligatoire** : `bw` refuse une adresse en `http://` (« Insecure URL not allowed »). Le
  crochet crée une autorité locale et un certificat pour `vaultwarden` et `localhost`, dans
  `secrets/vaultwarden/` (ignoré par git). Pour ouvrir le coffre web sans avertissement, importer
  `secrets/vaultwarden/ca.pem` dans le navigateur ; sinon, accepter l'avertissement.
- **Pas d'inscription libre** (`SIGNUPS_ALLOWED=false`) : les comptes de démonstration sont invités
  par la page d'administration, puis inscrits. Aucun courriel n'est envoyé, et les icônes des
  sites ne sont pas téléchargées.
- **Outils jetables** : `bw` 2026.10.1, jq, et Python avec `cryptography` sont dans une image
  construite sur le poste (`stack/vaultwarden/outils/Dockerfile`, `lab-vaultwarden-outils`). Elle
  est lancée avec `docker run --rm --read-only`, sans volume persistant : la session `bw` disparaît
  avec le conteneur.

## Données de démonstration (`stack/vaultwarden/seed.py`)

Ni `bw` ni Vaultwarden ne savent inscrire un compte ni créer une organisation. `seed.py` fait donc
ce que fait le coffre web, chiffrement côté client compris (PBKDF2 à 600 000 itérations, clés AES et
HMAC, paire RSA). Il suit le livre blanc de sécurité de Bitwarden
(https://bitwarden.com/help/bitwarden-security-white-paper/) et les routes du serveur
(https://github.com/dani-garcia/vaultwarden/tree/main/src/api). Il est rejouable : il ne crée que ce
qui manque.

Organisation **Labo GRC**, collections Infrastructure, Réseau et Applications.

| Membre | Rôle | Collections | Deux étapes | État GLPI (essai) | Écart attendu dans GRC |
|---|---|---|---|---|---|
| claire.martin@labo-grc.example | propriétaire | Infrastructure, Applications | oui (TOTP) | actif | aucun |
| bruno.lefevre@labo-grc.example | administrateur | Infrastructure, Réseau | **non** | actif | administrateur sans deux étapes |
| david.moreau@labo-grc.example | utilisateur | Réseau | non | **désactivé** | personne partie |
| emma.petit@labo-grc.example | utilisateur | Infrastructure, Applications | non | actif | aucun |
| prestataire@infogerance.example | utilisateur | Réseau | non | **aucun compte** | inconnu de GLPI |
| ancien.stagiaire@labo-grc.example | utilisateur, **révoqué** | Applications | non | aucun compte | aucun (révoqué) |

| Élément | Collection | Mot de passe changé il y a | Écarts attendus (délai de 12 mois) |
|---|---|---|---|
| Routeur cœur de réseau | Réseau | 3 ans | non renouvelé, personne partie |
| Pare-feu périmétrique | Réseau | 2 mois | personne partie |
| Base de données RH | Infrastructure | 14 mois | non renouvelé |
| iLO srv-app01 | Infrastructure | 1 mois | aucun |
| Console d'hébergement | Applications | jamais changé (créé le jour de l'amorçage) | aucun |
| Compte de service sauvegarde | Applications | 5 mois | aucun |

Les dates anciennes sont réelles côté serveur : `passwordRevisionDate` fait partie des données
envoyées par le client, et `seed.py` l'envoie à la date voulue. Les mots de passe des éléments sont
tirés au hasard à la création et ne sont écrits nulle part en clair. Le secret TOTP de la
propriétaire est dans `secrets/vaultwarden-2fa/` (ignoré par git), pour les connexions de `bw`.

## Export (`stack/vaultwarden/export.sh`)

`bash stack/vaultwarden/hook.sh export [dossier]` se connecte avec `bw login` (TOTP compris), puis
lit `bw list org-members`, `bw list org-collections`, `bw get org-collection` (membres de chaque
collection) et `bw list items`. jq ne garde que les colonnes reconnues par GRC :

| Fichier | Colonnes |
|---|---|
| `membres.csv` | `email`, `name`, `type`, `status`, `collections`, `twoFactorEnabled` |
| `elements.csv` | `id`, `name`, `collections`, `username`, `uri`, `passwordRevisionDate`, `creationDate` |
| `entete-export-natif.csv` | en-tête seul de `bw export --format csv` (pour vérifier que GRC le refuse) |

- Aucune colonne de secret : ni mot de passe, ni TOTP, ni notes, ni champs personnalisés.
- `type` et `status` sont les valeurs numériques de Bitwarden : 0 propriétaire, 1 administrateur,
  2 utilisateur ; 2 confirmé, -1 révoqué. GRC les reconnaît telles quelles.
- Les collections sont données **par leur nom** dans les deux fichiers, pour que GRC relie chaque
  élément aux membres qui y ont accès. Les identifiants de `collectionIds` donneraient le même
  résultat, mais sont illisibles dans GRC.
- Vaultwarden ne cite pas les propriétaires et les administrateurs dans les membres d'une
  collection, car ils voient tout. Leur colonne `collections` est donc vide.

## Essai de bout en bout (`stack/vaultwarden/grc/essai.sh`)

```sh
eval "$(sh /f/Dev/glpi-test-env/tools/grc-lock.sh take-any)"
(cd /f/Dev/glpi-test-env && REPO_OVERRIDE=<dossier de GRC> sh deploy-g12.sh grcmanager)
bash stack/vaultwarden/grc/essai.sh "$G12" "$G12_URL" --purger
sh /f/Dev/glpi-test-env/tools/grc-lock.sh release "$G12"
```

1. Export avec `bw`, dans un dossier temporaire de `F:\Dev\tmp`.
2. Comptes GLPI des membres (`grc/essai.php comptes`) : David Moreau est désactivé (parti), le
   prestataire n'a pas de compte.
3. Connexion à GLPI (glpi/glpi), puis import des deux fichiers par le formulaire de la page
   Comptes privilégiés, source « Bitwarden ou Vaultwarden », comme le ferait un utilisateur.
4. Import de l'en-tête de l'export natif de `bw` : GRC doit le refuser en entier (colonnes de
   secrets).
5. Écarts calculés par GRC comparés aux tableaux ci-dessus (`grc/essai.php verifier`).
6. Avec `--purger` : imports effacés par l'interface, comptes GLPI de l'essai supprimés.

### Résultat du 24/11 (instance g12b de glpi-test-env, GRC de la branche dev avec #859)

| Contrôle | Résultat |
|---|---|
| Export natif de `bw` (colonnes `notes`, `login_password`, `login_totp`…) | refusé en entier, rien d'importé |
| 6 membres : administrateur sans deux étapes, personne partie, inconnu de GLPI, révoqué sans écart, deux sans écart | tous conformes |
| Routeur cœur de réseau, Pare-feu périmétrique, Base de données RH, iLO, Compte de service sauvegarde | tous conformes |
| Console d'hébergement (mot de passe jamais changé) | **écart** : GRC signale « date inconnue » au lieu d'utiliser `creationDate` ([parime/glpi-iso27001-management#1145](https://github.com/parime/glpi-iso27001-management/issues/1145)) |

Tant que #1145 est ouverte, l'essai affiche cette ligne « CONNU » sans échouer ; elle repassera
« OK » quand GRC lira `creationDate`.

## Limites connues

- Le jeton d'administration est en clair dans l'environnement du service (Vaultwarden le signale au
  démarrage). Il vient de `.env`, généré sur le poste, et la page d'administration ne sert qu'au
  labo.
- Le crochet se connecte à l'administration à chaque `lab seed` : la limite de Vaultwarden est
  relevée à 20 connexions par 5 minutes (`ADMIN_RATELIMIT_MAX_BURST`).
- Un code TOTP déjà servi est refusé : deux connexions dans la même demi-minute attendent le pas
  suivant (jusqu'à 30 s).
