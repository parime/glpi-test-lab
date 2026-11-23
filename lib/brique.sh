#!/usr/bin/env bash
# Fonctions communes aux crochets des briques (stack/<brique>/hook.sh).
# `lab` lance chaque crochet avec bash, depuis la racine du dépôt, .env chargé (set -a) :
#   bash stack/<brique>/hook.sh prepare   avant `docker stack deploy` (secrets, fichiers générés)
#   bash stack/<brique>/hook.sh seed      après le déploiement : comptes d'API, données de démonstration
#   bash stack/<brique>/hook.sh reset     après l'effacement des volumes : oublie les jetons générés
#   bash stack/<brique>/hook.sh connect   affiche les connexions à créer dans GLPI (JSON, une par ligne)
# Chaque action est rejouable sans effet de bord (on vérifie avant de créer).
set -euo pipefail
export MSYS_NO_PATHCONV=1
# Python de Windows : entrées et sorties en UTF-8 (sinon cp1252, et les accents envoyés aux API
# arrivent invalides).
export PYTHONUTF8=1 PYTHONIOENCODING=utf-8

LAB_ROOT=${LAB_ROOT:-$(pwd)}
# Chemin lisible par docker.exe et python.exe sous Git Bash (F:/Dev/...), inchangé sous Linux.
LAB_ROOT_W=${LAB_ROOT_W:-$( (cd "$LAB_ROOT" && pwd -W) 2>/dev/null || echo "$LAB_ROOT")}
LAB_SECRETS_DIR=${LAB_SECRETS_DIR:-$LAB_ROOT_W/secrets}
PY=$(command -v python3 2>/dev/null || command -v python)
# python3 de WindowsApps (alias du Microsoft Store) ne fonctionne pas : préférer python s'il marche.
if ! "$PY" -c 'import sys' >/dev/null 2>&1; then PY=$(command -v python); fi

BRIQUE=${BRIQUE:-$(basename "$(dirname "$0")")}

# Toujours la dernière version de .env (un crochet précédent a pu y ajouter des jetons).
if [ -f "$LAB_ROOT/.env" ]; then
  set -a
  # shellcheck disable=SC1091
  . "$LAB_ROOT/.env"
  set +a
fi

info() { echo "lab [$BRIQUE] : $*" >&2; }
die() { echo "lab [$BRIQUE] : $*" >&2; exit 1; }

gen_secret() { od -An -N"${1:-16}" -tx1 /dev/urandom | tr -d ' \n'; }

# Ajoute ou remplace une variable dans .env (valeur entre apostrophes, lue telle quelle par bash et
# par `docker stack deploy` : le nom du robot Harbor contient « $ »).
env_set() {
  local key=$1 value=$2
  case "$value" in *"'"*) die "apostrophe interdite dans la valeur de $key" ;; esac
  "$PY" - "$LAB_ROOT_W/.env" "$key" "$value" <<'PYEOF'
import re, sys
path, key, value = sys.argv[1:4]
s = open(path, encoding="utf-8").read()
line = key + "='" + value + "'"
if re.search(r"(?m)^" + re.escape(key) + r"=", s):
    s = re.sub(r"(?m)^" + re.escape(key) + r"=.*$", lambda m: line, s)
else:
    s += ("" if s.endswith("\n") or s == "" else "\n") + line + "\n"
open(path, "w", encoding="utf-8", newline="\n").write(s)
PYEOF
  export "$key=$value"
}

# Retire des variables de .env (jetons à régénérer après un `lab reset <brique>`).
env_unset() {
  local key
  for key in "$@"; do
    sed -i "/^$key=/d" "$LAB_ROOT/.env"
    unset "$key"
  done
}

# Lecture d'une clé JSON (chemin pointé, index numériques permis) depuis l'entrée standard.
json_get() {
  "$PY" -c 'import sys, json
d = json.load(sys.stdin)
for k in sys.argv[1].split("."):
    if k == "":
        continue
    d = d[int(k)] if isinstance(d, list) else (d or {}).get(k)
print("" if d is None else d)' "$1"
}

# Encode des paires clé valeur en objet JSON (valeurs en chaînes ; « clé:=valeur » pour du JSON brut).
json_obj() {
  "$PY" -c 'import sys, json
o = {}
for a in sys.argv[1:]:
    if ":=" in a and a.index(":=") + 1 == a.index("="):
        k, v = a.split(":=", 1); o[k] = json.loads(v)
    else:
        k, v = a.split("=", 1); o[k] = v
print(json.dumps(o))' "$@"
}

# Attend qu'une commande réussisse : wait_for <description> <secondes> <commande…>.
# Disque F: lent : les délais passés par les crochets sont généreux (10 à 40 minutes).
wait_for() {
  local what=$1 timeout=$2 start
  shift 2
  start=$(date +%s)
  until "$@" >/dev/null 2>&1; do
    if [ $(($(date +%s) - start)) -ge "$timeout" ]; then
      die "délai dépassé ($((timeout / 60)) min) : $what"
    fi
    sleep 5
  done
  info "$what"
}

http_ok() { curl -fsS -m 10 -o /dev/null "$@"; }

# Lance un outil (crane, htpasswd…) dans un conteneur jetable relié à lab-net, sans volume.
tool() {
  local net=$1
  shift
  docker run --rm -i --network "$net" "$@"
}

# Écrit un fichier de secret s'il n'existe pas : secret_file <chemin relatif> <commande qui l'écrit sur stdout…>.
secret_file() {
  local rel=$1 f
  shift
  f="$LAB_SECRETS_DIR/$rel"
  [ -s "$f" ] && return 0
  mkdir -p "$(dirname "$f")"
  "$@" > "$f.tmp"
  mv "$f.tmp" "$f"
  info "secret généré : secrets/$rel"
}

# Empreinte bcrypt pour htpasswd (registre, Harbor) : image officielle httpd.
htpasswd_bcrypt() {
  docker run --rm "${LAB_HTTPD_IMAGE:-httpd:2.4.66-alpine}" htpasswd -nbB "$1" "$2" | tr -d '\r' | sed '/^$/d'
}
