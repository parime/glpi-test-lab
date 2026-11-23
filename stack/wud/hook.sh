#!/usr/bin/env bash
# Crochet de la brique wud (voir lib/brique.sh) : utilisateur glpi-lecture au rôle « ro ».
# API de WUD 9 (https://getwud.github.io/wud/) : GET /api/app, POST /api/users (administrateur),
# GET /api/containers (ce que lit l'Inventaire Docker).
# shellcheck disable=SC1091
. "$LAB_ROOT/lib/brique.sh"

API=http://localhost:8122/api

seed() {
  wait_for "API WUD 9 joignable (http://localhost:8122)" 1800 \
    http_ok -u "admin:$LAB_WUD_ADMIN_PASSWORD" "$API/app"
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' -u "admin:$LAB_WUD_ADMIN_PASSWORD" -X POST "$API/users" \
    -H 'Content-Type: application/json' \
    -d "$(json_obj username=glpi-lecture password="$LAB_WUD_GLPI_PASSWORD" role=ro)")
  case "$code" in
    200|201) info "utilisateur glpi-lecture créé (rôle ro)" ;;
    409) ;;
    *) die "création de l'utilisateur glpi-lecture : HTTP $code" ;;
  esac
  wait_for "glpi-lecture lit les conteneurs suivis" 300 http_ok -u "glpi-lecture:$LAB_WUD_GLPI_PASSWORD" "$API/containers"
  info "prêt : http://localhost:8122 (admin, LAB_WUD_ADMIN_PASSWORD de .env)"
}

prepare() { :; }
reset() { :; }

connect() {
  json_obj name="Labo - WUD 9" type=wud url=http://wud:3000 allow_http:=1 \
    username=glpi-lecture api_key="$LAB_WUD_GLPI_PASSWORD" \
    comment="What's Up Docker 9 du labo (glpi-test-lab), rôle ro, conteneurs de lab-demo"
}

"${1:?action attendue : prepare, seed, reset ou connect}"
