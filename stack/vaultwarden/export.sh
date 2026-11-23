#!/bin/sh
# Export de l'organisation « Labo GRC » au format d'import de GRC (Comptes privilégiés, #859), avec
# l'interface en ligne de commande officielle de Bitwarden « bw », comme le ferait un client :
#   https://bitwarden.com/help/cli/ (commandes list, get, login)
# Lancé dans le conteneur jetable lab-vaultwarden-outils par `bash stack/vaultwarden/hook.sh export`.
# Écrit dans <dossier> :
#   membres.csv  : email, name, type, status, collections, twoFactorEnabled
#   elements.csv : id, name, collections, username, uri, passwordRevisionDate, creationDate
# Aucune colonne de secret : jq ne garde que ces champs (ni mot de passe, ni TOTP, ni notes, ni
# champs personnalisés). Les collections sont données par leur nom dans les deux fichiers, pour que
# GRC relie les éléments aux membres qui y ont accès.
set -eu
out=${1:?dossier de sortie attendu}
email=${VW_EXPORT_EMAIL:-claire.martin@labo-grc.example}
org_name=${VW_ORG_NAME:-Labo GRC}
export BW_PASSWORD="${VW_PASSWORD:?mot de passe maître absent}"

bw config server "$VW_URL" >/dev/null
# Connexion en deux étapes de la propriétaire (secret TOTP créé par seed.py dans secrets/vaultwarden) ;
# un code déjà servi est refusé, on réessaie alors au pas suivant.
totp() {
  python3 -B -c 'import sys; sys.path.insert(0, "/outils"); import seed; print(seed.totp(open(sys.argv[1]).read().strip()))' \
    "/secrets/totp-${email%%@*}"
}
session=""
for _essai in 1 2 3; do
  if [ -f "/secrets/totp-${email%%@*}" ]; then
    session=$(bw login "$email" --passwordenv BW_PASSWORD --method 0 --code "$(totp)" --raw 2>/dev/null) && break
  else
    session=$(bw login "$email" --passwordenv BW_PASSWORD --raw 2>/dev/null) && break
  fi
  sleep $((31 - $(date +%s) % 30))
done
[ -n "$session" ] || { echo "lab [vaultwarden] : connexion de $email refusée par Vaultwarden" >&2; exit 1; }
export BW_SESSION="$session"
bw sync >/dev/null

org=$(bw list organizations | jq -r --arg n "$org_name" '.[] | select(.name == $n) | .id')
[ -n "$org" ] || { echo "lab [vaultwarden] : organisation « $org_name » absente (./lab seed vaultwarden)" >&2; exit 1; }

# Collections : nom, et membres qui y ont accès (bw get org-collection donne leurs identifiants).
bw list org-collections --organizationid "$org" > /tmp/collections.json
: > /tmp/acces.jsonl
for id in $(jq -r '.[].id' /tmp/collections.json); do
  bw get org-collection "$id" --organizationid "$org" \
    | jq -c '{name: .name, users: [.users[]?.id]}' >> /tmp/acces.jsonl
done

bw list org-members --organizationid "$org" > /tmp/membres.json
jq -r --slurpfile acces /tmp/acces.jsonl '
  ["email", "name", "type", "status", "collections", "twoFactorEnabled"],
  (.[] | . as $m
    | [.email, .name, .type, .status,
       ([$acces[] | select(.users | index($m.id)) | .name] | join(";")),
       .twoFactorEnabled])
  | @csv' /tmp/membres.json > "$out/membres.csv"

bw list items --organizationid "$org" \
  | jq -r --slurpfile cols /tmp/collections.json '
  ($cols[0] | map({key: .id, value: .name}) | from_entries) as $nom
  | ["id", "name", "collections", "username", "uri", "passwordRevisionDate", "creationDate"],
    (.[] | select(.type == 1)
      | [.id, .name, ([.collectionIds[] | $nom[.] // .] | join(";")),
         (.login.username // ""), (.login.uris[0].uri // ""),
         (.login.passwordRevisionDate // ""), (.creationDate // "")])
  | @csv' > "$out/elements.csv"

# En-tête seul de l'export natif (bw export --format csv) : il porte les colonnes de secrets
# (login_password, login_totp, notes, fields) et sert à vérifier que GRC le refuse. Le fichier
# complet reste dans /tmp du conteneur jetable (tmpfs), effacé à la sortie.
bw export --organizationid "$org" --format csv --output /tmp/natif.csv >/dev/null
head -1 /tmp/natif.csv | tr -d '\r' > "$out/entete-export-natif.csv"
rm -f /tmp/natif.csv

bw logout >/dev/null 2>&1 || true
echo "lab [vaultwarden] : $(($(wc -l < "$out/membres.csv") - 1)) membres, $(($(wc -l < "$out/elements.csv") - 1)) éléments exportés" >&2
