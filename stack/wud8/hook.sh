#!/usr/bin/env bash
# Crochet de la brique wud8 (voir lib/brique.sh) : empreinte htpasswd (MD5 « apr1 ») du compte
# glpi-lecture, lue par WUD 8 dans WUD_AUTH_BASIC_GLPI_HASH.
# Authentification de WUD 8 : https://github.com/getwud/wud/blob/8.4.0/website/docs/configuration/authentications/basic/README.md
# shellcheck disable=SC1091
. "$LAB_ROOT/lib/brique.sh"

API=http://localhost:8123/api

prepare() {
  if [ -z "${LAB_WUD8_GLPI_HASH:-}" ]; then
    # Empreinte seule (sans « utilisateur: »), comme l'attend WUD_AUTH_BASIC_<NOM>_HASH.
    env_set LAB_WUD8_GLPI_HASH "$(openssl passwd -apr1 "$LAB_WUD8_GLPI_PASSWORD" | tr -d '\r')"
    info "empreinte htpasswd de glpi-lecture générée (LAB_WUD8_GLPI_HASH dans .env)"
  fi
}

seed() {
  wait_for "API WUD 8 joignable (http://localhost:8123)" 1800 \
    http_ok -u "glpi-lecture:$LAB_WUD8_GLPI_PASSWORD" "$API/app"
  info "prêt : http://localhost:8123 (glpi-lecture, LAB_WUD8_GLPI_PASSWORD de .env)"
}

reset() { :; }

connect() {
  json_obj name="Labo - WUD 8" type=wud url=http://wud8:3000 allow_http:=1 \
    username=glpi-lecture api_key="$LAB_WUD8_GLPI_PASSWORD" \
    comment="What's Up Docker 8 du labo (glpi-test-lab), authentification basique"
}

"${1:?action attendue : prepare, seed, reset ou connect}"
