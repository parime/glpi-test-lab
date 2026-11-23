#!/usr/bin/env bash
# Crochet de la brique forgejo (voir lib/brique.sh) : administrateur lab-admin (ligne de commande
# `forgejo admin user create`), utilisateur glpi-lecture et son jeton en lecture, organisation demo
# et ses dépôts (fichiers de stack/forgejo/demo/<dépôt>/), étiquette et tickets de sécurité.
# Ligne de commande : https://forgejo.org/docs/latest/admin/command-line/
# API (Swagger servi par l'instance, http://localhost:8140/api/swagger) :
#   GET /api/v1/version, POST /api/v1/admin/users, POST /api/v1/users/{u}/tokens, POST /api/v1/orgs,
#   POST /api/v1/orgs/{org}/repos, GET/POST /api/v1/repos/{o}/{r}/contents/{chemin},
#   GET/POST /api/v1/repos/{o}/{r}/labels, GET/POST /api/v1/repos/{o}/{r}/issues.
# Corps JSON toujours produits par json_obj (accents échappés en \uXXXX) : curl de Git Bash
# convertit ses arguments dans la page de code de Windows, et un « é » brut arriverait invalide.
# shellcheck disable=SC1091
. "$LAB_ROOT/lib/brique.sh"

API=http://localhost:8140/api/v1
DEMO="$LAB_ROOT/stack/forgejo/demo"

fa() { curl -fsS -u "lab-admin:$LAB_FORGEJO_ADMIN_PASSWORD" -H 'Content-Type: application/json' "$@"; }
exists() { curl -fs -o /dev/null -u "lab-admin:$LAB_FORGEJO_ADMIN_PASSWORD" "$1"; }

# Un fichier du dépôt : GET …/contents/<chemin> répond 200 même sur un dépôt vide, d'où le test
# du type renvoyé.
file_exists() {
  curl -fs -u "lab-admin:$LAB_FORGEJO_ADMIN_PASSWORD" "$1" 2>/dev/null | "$PY" -c 'import sys, json
try:
    d = json.load(sys.stdin)
except ValueError:
    sys.exit(1)
sys.exit(0 if isinstance(d, dict) and d.get("type") == "file" else 1)'
}

container() { docker ps -q -f label=com.docker.swarm.service.name=lab-forgejo_forgejo | head -1; }

seed() {
  wait_for "API Forgejo joignable (http://localhost:8140)" 1800 http_ok "$API/version"
  local c out
  c=$(container)
  [ -n "$c" ] || die "conteneur Forgejo introuvable"
  if ! exists "$API/users/lab-admin"; then
    out=$(docker exec -u git "$c" forgejo admin user create --admin --username lab-admin \
      --password "$LAB_FORGEJO_ADMIN_PASSWORD" --email lab-admin@lab.test --must-change-password=false 2>&1) \
      || case "$out" in *"already exists"*) ;; *) die "création de lab-admin : $out" ;; esac
    info "administrateur lab-admin créé"
  fi

  if ! exists "$API/users/glpi-lecture"; then
    fa -X POST "$API/admin/users" -d "$(json_obj username=glpi-lecture email=glpi-lecture@lab.test \
      password="$LAB_FORGEJO_GLPI_PASSWORD" must_change_password:=false full_name="GLPI (lecture seule)")" >/dev/null
    info "utilisateur glpi-lecture créé"
  fi
  if [ -z "${LAB_FORGEJO_GLPI_TOKEN:-}" ]; then
    env_set LAB_FORGEJO_GLPI_TOKEN "$(curl -fsS -u "glpi-lecture:$LAB_FORGEJO_GLPI_PASSWORD" \
      -H 'Content-Type: application/json' -X POST "$API/users/glpi-lecture/tokens" \
      -d "{\"name\":\"glpi-lecture-$(date +%Y%m%d%H%M%S)\",\"scopes\":[\"read:repository\",\"read:issue\",\"read:organization\",\"read:user\"]}" \
      | json_get sha1)"
    info "jeton en lecture de glpi-lecture créé (LAB_FORGEJO_GLPI_TOKEN dans .env)"
  fi

  if ! exists "$API/orgs/demo"; then
    fa -X POST "$API/orgs" -d "$(json_obj username=demo full_name="Démonstration (fictif)" visibility=public)" >/dev/null
    info "organisation demo créée"
  fi

  local d repo f rel
  for d in "$DEMO"/*/; do
    repo=$(basename "$d")
    if ! exists "$API/repos/demo/$repo"; then
      fa -X POST "$API/orgs/demo/repos" -d "$(json_obj name="$repo" \
        description="Dépôt fictif du labo (dépendances vulnérables connues)" auto_init:=false private:=false default_branch=main)" >/dev/null
      info "dépôt demo/$repo créé"
    fi
    while IFS= read -r f; do
      rel=${f#"$d"}
      file_exists "$API/repos/demo/$repo/contents/$rel" && continue
      fa -X POST "$API/repos/demo/$repo/contents/$rel" -d "$("$PY" -c 'import base64, json, sys
print(json.dumps({"content": base64.b64encode(open(sys.argv[1], "rb").read()).decode(),
                  "message": "Ajout de " + sys.argv[2] + " (données fictives du labo)"}))' "$(cygpath -m "$f" 2>/dev/null || echo "$f")" "$rel")" >/dev/null
    done < <(find "$d" -type f | sort)
    seed_issues "$repo"
  done
  info "prêt : http://localhost:8140/demo (lab-admin, LAB_FORGEJO_ADMIN_PASSWORD de .env)"
}

# Étiquette « sécurité » et un ticket par dépôt (une seule fois, repéré par son titre).
seed_issues() {
  local repo=$1 label title body
  label=$(fa "$API/repos/demo/$repo/labels" | "$PY" -c 'import sys, json
print(next((str(l["id"]) for l in json.load(sys.stdin) if l["name"] == "sécurité"), ""))')
  if [ -z "$label" ]; then
    label=$(fa -X POST "$API/repos/demo/$repo/labels" -d "$(json_obj name=sécurité color="#d73a4a" \
      description="Vulnérabilité ou correctif de sécurité")" | json_get id)
  fi
  case "$repo" in
    boutique-web) title="Mettre à jour lodash (CVE-2020-8203)"
      body="lodash 4.17.15 est vulnérable à une pollution de prototype (CVE-2020-8203), corrigée en 4.17.19." ;;
    api-commandes) title="Django 3.2.0 : passer à une version maintenue"
      body="Django 3.2.0 est touché par CVE-2021-31542 (corrigée en 3.2.1) ; la branche 3.2 n'est plus maintenue." ;;
    portail-php) title="guzzlehttp/guzzle 7.4.0 : en-têtes de cookies (CVE-2022-29248)"
      body="Corrigée en 7.4.3." ;;
    *) return 0 ;;
  esac
  if ! fa "$API/repos/demo/$repo/issues?state=all&type=issues&limit=50" | "$PY" -c 'import sys, json
sys.exit(0 if any(i["title"] == sys.argv[1] for i in json.load(sys.stdin)) else 1)' "$title"; then
    fa -X POST "$API/repos/demo/$repo/issues" -d "$(json_obj title="$title" body="$body" labels:="[$label]")" >/dev/null
    info "ticket de sécurité créé dans demo/$repo"
  fi
}

prepare() { :; }
reset() { env_unset LAB_FORGEJO_GLPI_TOKEN; }
# Pas de connecteur Forgejo dans les plugins (GRC : GitHub et GitLab seulement).
connect() { :; }

"${1:?action attendue : prepare, seed, reset ou connect}"
