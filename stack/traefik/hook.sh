#!/usr/bin/env bash
# Crochet de la brique traefik (voir lib/brique.sh) : empreinte htpasswd (MD5 « apr1 ») du compte
# glpi-lecture, pour l'intergiciel basicauth qui protège l'API des deux versions.
# Intergiciel BasicAuth : https://doc.traefik.io/traefik/reference/routing-configuration/http/middlewares/basicauth/
# shellcheck disable=SC1091
. "$LAB_ROOT/lib/brique.sh"

prepare() {
  if [ -z "${LAB_TRAEFIK_GLPI_HASH:-}" ]; then
    env_set LAB_TRAEFIK_GLPI_HASH "$(openssl passwd -apr1 "$LAB_TRAEFIK_GLPI_PASSWORD" | tr -d '\r')"
    info "empreinte htpasswd de glpi-lecture générée (LAB_TRAEFIK_GLPI_HASH dans .env)"
  fi
}

seed() {
  local p
  for p in 8145 8146; do
    wait_for "API Traefik joignable (http://localhost:$p)" 1200 \
      http_ok -u "glpi-lecture:$LAB_TRAEFIK_GLPI_PASSWORD" "http://localhost:$p/api/version"
  done
  info "prêt : API http://localhost:8145/api/http/routers (Traefik 3), :8146 (Traefik 2), glpi-lecture"
}

reset() { :; }

connect() {
  json_obj name="Labo - Traefik 3" type=traefik url=http://traefik:8080 allow_http:=1 \
    username=glpi-lecture api_key="$LAB_TRAEFIK_GLPI_PASSWORD" \
    comment="Traefik 3 du labo (glpi-test-lab), fournisseur Swarm, routeurs de lab-demo"
  json_obj name="Labo - Traefik 2" type=traefik url=http://traefik2:8080 allow_http:=1 \
    username=glpi-lecture api_key="$LAB_TRAEFIK_GLPI_PASSWORD" \
    comment="Traefik 2 du labo (glpi-test-lab), fournisseur Docker en mode Swarm"
}

"${1:?action attendue : prepare, seed, reset ou connect}"
