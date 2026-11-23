#!/usr/bin/env bash
# Essai de bout en bout : export de l'organisation « Labo GRC » de Vaultwarden avec « bw », import
# des deux CSV dans GRC par l'interface web (comme un utilisateur), puis comparaison des écarts
# calculés par GRC avec les écarts attendus. Depuis la racine du dépôt :
#   bash stack/vaultwarden/grc/essai.sh <conteneur GLPI> <adresse GLPI> [--purger]
# Avec une instance de glpi-test-env (verrou take-any, GRC déployé) :
#   eval "$(sh /f/Dev/glpi-test-env/tools/grc-lock.sh take-any)"
#   bash stack/vaultwarden/grc/essai.sh "$G12" "$G12_URL" --purger
#   sh /f/Dev/glpi-test-env/tools/grc-lock.sh release "$G12"
# Connexion glpi/glpi (LAB_GLPI_USER, LAB_GLPI_PASSWORD pour en changer). --purger retire ensuite
# les imports et les comptes GLPI de l'essai.
set -euo pipefail
export MSYS_NO_PATHCONV=1
c=${1:?conteneur GLPI attendu (par exemple g12c)}
url=${2:?adresse GLPI attendue (par exemple http://localhost:8094)}
purger=${3:-}
root=$(pwd)
[ -f "$root/stack/vaultwarden/hook.sh" ] || { echo "à lancer depuis la racine de glpi-test-lab" >&2; exit 2; }
say() { echo "essai vaultwarden : $*" >&2; }

work=$(mktemp -d "${LAB_TMP_DIR:-F:/Dev/tmp}/essai-vaultwarden.XXXXXX")
trap 'rm -rf "$work"' EXIT
jar=$work/cookies
page=$url/plugins/grcmanager/front/privilegedvault.php

say "export de Vaultwarden (bw)"
bash stack/vaultwarden/hook.sh export "$work/export"

say "comptes GLPI des membres ($c)"
docker cp stack/vaultwarden/grc/essai.php "$c:/tmp/lab-essai-vaultwarden.php" >/dev/null
php_essai() { docker exec -u www-data -w /var/www/glpi "$c" php /tmp/lab-essai-vaultwarden.php "$@"; }
php_essai comptes

# Jeton CSRF d'une page (le formulaire de connexion de GLPI 12 n'en a pas : chaîne vide).
csrf() {
  { curl -fsS -b "$jar" -c "$jar" "$1" | grep -o 'name="_glpi_csrf_token" value="[^"]*"\|glpi:csrf_token" content="[^"]*"' \
    | head -1 | sed 's/.*\(value\|content\)="//;s/"$//'; } || true
}
say "connexion à $url"
token=$(csrf "$url/")
curl -fsS -o /dev/null -b "$jar" -c "$jar" --data-urlencode "login_name=${LAB_GLPI_USER:-glpi}" \
  --data-urlencode "login_password=${LAB_GLPI_PASSWORD:-glpi}" --data-urlencode "_glpi_csrf_token=$token" \
  -d noAUTO=1 "$url/front/login.php"
[ "$(curl -s -o /dev/null -w '%{http_code}' -b "$jar" -c "$jar" "$page")" = 200 ] \
  || { say "page Comptes privilégiés inaccessible ($page)"; exit 1; }

# Import par le formulaire de la page : source Bitwarden ou Vaultwarden, nature, fichier.
importer() {
  local kind=$1 file=$2
  curl -fsS -L -o "$work/reponse.html" -b "$jar" -c "$jar" -F import_vault=1 -F source=bitwarden \
    -F "kind=$kind" -F "vault_file=@$file;type=text/csv" -F "_glpi_csrf_token=$(csrf "$page")" "$page"
}
say "import des membres puis des éléments"
importer members "$work/export/membres.csv"
importer entries "$work/export/elements.csv"
grep -q 'prestataire@infogerance.example' "$work/reponse.html" \
  || { say "la page ne montre pas les membres importés"; exit 1; }

# L'export natif de Bitwarden (bw export --format csv) porte les mots de passe : GRC doit le refuser
# en entier. Seul son en-tête est gardé par export.sh.
say "refus attendu de l'export natif (en-tête : $(cat "$work/export/entete-export-natif.csv"))"
importer entries "$work/export/entete-export-natif.csv"
refus=0
# Message d'erreur citant la première colonne refusée (« notes »), entre guillemets ou chevrons.
grep -qE '(&quot;|&#34;|"|«[^a-z]{0,8})notes' "$work/reponse.html" && refus=1
[ $refus = 1 ] && echo "OK     refus      export natif de bw (colonnes de secrets)" \
  || echo "ÉCHEC  refus      export natif de bw accepté ou sans message"

rc=0
php_essai verifier || rc=1
[ $refus = 1 ] || rc=1

if [ "$purger" = --purger ]; then
  say "purge : imports et comptes GLPI de l'essai"
  for kind in members entries; do
    curl -fsS -o /dev/null -b "$jar" -c "$jar" -d clear_vault=1 -d source=bitwarden -d "kind=$kind" \
      --data-urlencode "_glpi_csrf_token=$(csrf "$page")" "$page"
  done
  php_essai purger
fi
docker exec -u root "$c" rm -f /tmp/lab-essai-vaultwarden.php
exit $rc
