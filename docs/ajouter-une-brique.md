# Ajouter une brique

Une brique (Portainer, Zabbix, Forgejo…) est un fichier `stack/<brique>.yml`, déployé par
`./lab up <brique>` sous le nom de pile `lab-<brique>`.

1. Écrire `stack/<brique>.yml` (format compose 3, compatible `docker stack deploy`) :
   - images à une **version précise** (jamais `latest`), logiciels **gratuits** uniquement ;
   - services rattachés au réseau externe `lab-net` s'ils doivent être joints par GLPI, avec un
     alias parlant ;
   - ports publiés dans la plage 8120 à 8199 (noter le port dans [ports.md](ports.md)) ;
   - plafond mémoire (`deploy.resources.limits.memory`) ;
   - mots de passe lus dans l'environnement (`${LAB_<BRIQUE>_PASSWORD:?…}`), avec la variable
     ajoutée à `.env.example` (vide) et générée par `./lab init` si besoin ;
   - données : volumes nommés ; pour les poser sous `F:\Dev\glpi-test-lab-data`, suivre le modèle
     de `stack/glpi.bind.yml`.
2. Ajouter le profil dans `profiles.txt` si la brique fait partie d'un groupe (par exemple
   `docker portainer wud harbor forgejo`).
3. Vérifier : `./lab up <brique>`, `./lab status`, `./lab mem`, puis `./lab down <brique>`.
4. Reporter la mémoire mesurée dans [memoire.md](memoire.md) et le README.

La CI valide chaque fichier de `stack/` avec `docker compose config`.
