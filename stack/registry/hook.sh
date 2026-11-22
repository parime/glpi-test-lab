#!/usr/bin/env bash
# Crochet de la brique registry (voir lib/brique.sh) : htpasswd du compte glpi-lecture, dépôts de
# démonstration copiés depuis Docker Hub avec crane (linux/amd64 seulement).
# API Docker Registry v2 : https://distribution.github.io/distribution/spec/api/
# shellcheck disable=SC1091
. "$LAB_ROOT/lib/brique.sh"

REG=localhost:8135
IMAGES="nginx:1.25.3-alpine nginx:1.25.4-alpine nginx:1.27.0-alpine redis:7.0.15-alpine"
CRANE_IMAGE=${LAB_CRANE_IMAGE:-gcr.io/go-containerregistry/crane:v0.22.1}

prepare() {
  secret_file registry/htpasswd htpasswd_bcrypt glpi-lecture "$LAB_REGISTRY_GLPI_PASSWORD"
}

crane() {
  local cfg="$LAB_SECRETS_DIR/registry/crane"
  mkdir -p "$cfg"
  "$PY" -c 'import base64, json, sys
print(json.dumps({"auths": {sys.argv[1]: {"auth": base64.b64encode(sys.argv[2].encode()).decode()}}}))' \
    "$REG" "glpi-lecture:$LAB_REGISTRY_GLPI_PASSWORD" > "$cfg/config.json"
  docker run --rm --network host -e DOCKER_CONFIG=/cfg -v "$cfg:/cfg:ro" "$CRANE_IMAGE" "$@"
}

seed() {
  # 401 attendu sans identifiants : le registre répond.
  wait_for "registre joignable (http://localhost:8135)" 1200 http_ok -u "glpi-lecture:$LAB_REGISTRY_GLPI_PASSWORD" "http://$REG/v2/"
  local img
  for img in $IMAGES; do
    if http_ok -u "glpi-lecture:$LAB_REGISTRY_GLPI_PASSWORD" \
       -H 'Accept: application/vnd.docker.distribution.manifest.v2+json, application/vnd.oci.image.manifest.v1+json' \
       "http://$REG/v2/demo/${img%%:*}/manifests/${img#*:}"; then
      continue
    fi
    info "copie de $img dans $REG/demo"
    crane copy --platform linux/amd64 --insecure "docker.io/library/$img" "$REG/demo/$img"
  done
  rm -f "$LAB_SECRETS_DIR/registry/crane/config.json"
  info "prêt : http://localhost:8135/v2/_catalog (glpi-lecture, LAB_REGISTRY_GLPI_PASSWORD de .env)"
}

reset() { :; }
# Pas de type de connexion « registre » dans l'Inventaire Docker : il lit les registres par ses
# connexions Harbor et par Docker Hub. Le registre sert aux tests de l'API v2 (RegistryClient).
connect() { :; }

"${1:?action attendue : prepare, seed, reset ou connect}"
