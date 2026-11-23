#!/usr/bin/env bash
# Crochet de la brique harbor (voir lib/brique.sh).
#   prepare : clé de signature des jetons et son certificat, clé de chiffrement, htpasswd du registre
#             interne (secrets/harbor/, hors dépôt) ;
#   seed    : projet « demo » (public, analyse à l'envoi), compte robot en lecture seule pour GLPI,
#             images anciennes copiées depuis Docker Hub (crane), analyses Trivy, pile
#             lab-demo-harbor dont les images viennent de Harbor.
# API de Harbor 2.15 (swagger officiel) : https://github.com/goharbor/harbor/blob/v2.15.5/api/v2.0/swagger.yaml
#   GET /api/v2.0/ping, GET/POST /api/v2.0/projects, GET/POST/DELETE /api/v2.0/robots,
#   GET /api/v2.0/projects/{p}/repositories/{r}/artifacts/{ref}?with_scan_overview=true,
#   POST /api/v2.0/projects/{p}/repositories/{r}/artifacts/{ref}/scan.
# shellcheck disable=SC1091
. "$LAB_ROOT/lib/brique.sh"

API=http://localhost:8130/api/v2.0
REG=localhost:8130
# Images anciennes (vulnérabilités connues, mises à jour disponibles), plateforme linux/amd64 seule.
IMAGES="nginx:1.25.3-alpine nginx:1.25.4-alpine httpd:2.4.57-alpine redis:7.0.15-alpine node:18.20.4-alpine"
CRANE_IMAGE=${LAB_CRANE_IMAGE:-gcr.io/go-containerregistry/crane:v0.22.1}

hc() { curl -fsS -u "admin:$LAB_HARBOR_ADMIN_PASSWORD" -H 'Content-Type: application/json' "$@"; }

prepare() {
  # Paire de clés des jetons du registre (comme `prepare` de l'installateur : RSA 4096, 10 ans).
  # Format PKCS#1 (« BEGIN RSA PRIVATE KEY ») exigé par Harbor : OpenSSL 3 écrit du PKCS#8 par
  # défaut, que harbor-core refuse (« unable to get PrivateKey from PEM type: PRIVATE KEY »).
  local key="$LAB_SECRETS_DIR/harbor/private_key.pem"
  if [ -s "$key" ] && ! grep -q 'BEGIN RSA PRIVATE KEY' "$key"; then
    rm -f "$key" "$LAB_SECRETS_DIR/harbor/root.crt"
  fi
  if [ ! -s "$key" ] || [ ! -s "$LAB_SECRETS_DIR/harbor/root.crt" ]; then
    mkdir -p "$LAB_SECRETS_DIR/harbor"
    openssl genrsa -traditional -out "$key" 4096 2>/dev/null
    MSYS2_ARG_CONV_EXCL='*' openssl req -new -x509 -key "$key" -days 3650 -subj "/CN=harbor-token-issuer" \
      -out "$LAB_SECRETS_DIR/harbor/root.crt"
    info "secret généré : secrets/harbor/private_key.pem (PKCS#1) et root.crt"
  fi
  # Clé de chiffrement des mots de passe enregistrés : exactement 16 caractères.
  secret_file harbor/secretkey gen_secret 8
  secret_file harbor/registry_passwd htpasswd_bcrypt harbor_registry_user "$LAB_HARBOR_REGISTRY_PASSWORD"

  # Volumes écrits par l'utilisateur harbor (uid 10000) des images, alors qu'un volume neuf
  # appartient à root (« mkdir /storage/docker: permission denied ») : créés d'avance, avec
  # l'étiquette de la pile (pour `lab reset harbor`), et donnés à l'uid 10000.
  local v args=()
  for v in registry job_logs trivy trivy_reports; do
    docker volume inspect "lab-harbor_$v" >/dev/null 2>&1 \
      || docker volume create --label com.docker.stack.namespace=lab-harbor "lab-harbor_$v" >/dev/null
    args+=(-v "lab-harbor_$v:/v/$v")
  done
  docker run --rm "${args[@]}" "${LAB_ALPINE_IMAGE:-alpine:3.20}" chown 10000:10000 /v/registry /v/job_logs /v/trivy /v/trivy_reports
}

# crane : identifiants de Harbor dans un config.json monté en lecture seule le temps de la copie.
crane() {
  local cfg="$LAB_SECRETS_DIR/harbor/crane"
  mkdir -p "$cfg"
  "$PY" -c 'import base64, json, sys
print(json.dumps({"auths": {sys.argv[1]: {"auth": base64.b64encode(sys.argv[2].encode()).decode()}}}))' \
    "$REG" "admin:$LAB_HARBOR_ADMIN_PASSWORD" > "$cfg/config.json"
  # Réseau de l'hôte (machine virtuelle de Docker Desktop) : localhost:8130 y est le port publié.
  docker run --rm --network host -e DOCKER_CONFIG=/cfg -v "$cfg:/cfg:ro" "$CRANE_IMAGE" "$@"
}

scan_status() {
  hc "$API/projects/demo/repositories/$1/artifacts/$2?with_scan_overview=true" | "$PY" -c 'import sys, json
d = json.load(sys.stdin)
o = next(iter((d.get("scan_overview") or {}).values()), {})
print(o.get("scan_status", "none"))'
}

seed() {
  wait_for "API Harbor joignable (http://localhost:8130)" 2400 http_ok "$API/ping"
  wait_for "Harbor accepte l'administrateur" 600 hc "$API/users/current"

  if ! hc "$API/projects?name=demo" | "$PY" -c 'import sys, json
sys.exit(0 if any(p["name"] == "demo" for p in json.load(sys.stdin) or []) else 1)'; then
    # Public : le Swarm tire les images de lab-demo-harbor sans identifiants (pas de docker login sur C:).
    hc -X POST "$API/projects" -d '{"project_name":"demo","metadata":{"public":"true","auto_scan":"true"}}'
    info "projet demo créé (public, analyse Trivy à l'envoi)"
  fi

  # Compte robot en lecture seule, recréé si son secret n'est plus dans .env.
  if [ -z "${LAB_HARBOR_ROBOT_SECRET:-}" ]; then
    local id resp
    # Anciens robots du même nom (secret perdu) : supprimés ; liste vide si l'API hésite encore.
    for id in $(hc "$API/robots?q=name%3D~glpi-lecture" 2>/dev/null | "$PY" -c 'import sys, json
try:
    print(" ".join(str(r["id"]) for r in json.load(sys.stdin) or []))
except ValueError:
    pass'); do
      hc -X DELETE "$API/robots/$id" >/dev/null
    done
    resp=$(hc -X POST "$API/robots" -d '{"name":"glpi-lecture","description":"GLPI Inventaire Docker (lecture seule, labo)",
      "duration":-1,"disable":false,"level":"project","permissions":[{"kind":"project","namespace":"demo","access":[
      {"resource":"repository","action":"pull"},{"resource":"repository","action":"list"},
      {"resource":"artifact","action":"read"},{"resource":"artifact","action":"list"},
      {"resource":"tag","action":"list"},{"resource":"scan","action":"read"}]}]}')
    env_set LAB_HARBOR_ROBOT_NAME "$(printf '%s' "$resp" | json_get name)"
    env_set LAB_HARBOR_ROBOT_SECRET "$(printf '%s' "$resp" | json_get secret)"
    info "compte robot créé : $LAB_HARBOR_ROBOT_NAME (secret dans .env)"
  fi

  local img repo tag st
  for img in $IMAGES; do
    repo=${img%%:*}; tag=${img#*:}
    hc "$API/projects/demo/repositories/$repo/artifacts/$tag" >/dev/null 2>&1 && continue
    info "copie de $img dans $REG/demo (Docker Hub, linux/amd64)"
    crane copy --platform linux/amd64 --insecure "docker.io/library/$img" "$REG/demo/$img"
  done
  rm -f "$LAB_SECRETS_DIR/harbor/crane/config.json"

  # Analyses : relancées pour les artefacts sans rapport (l'analyse à l'envoi échoue tant que la
  # base Trivy n'est pas téléchargée, plusieurs minutes au premier démarrage).
  for img in $IMAGES; do
    repo=${img%%:*}; tag=${img#*:}
    st=$(scan_status "$repo" "$tag")
    case "$st" in
      Success|Running|Pending) ;;
      *) hc -X POST "$API/projects/demo/repositories/$repo/artifacts/$tag/scan" >/dev/null && info "analyse demandée : $img ($st)" ;;
    esac
  done
  deploy_demo
  info "prêt : http://localhost:8130 (admin, LAB_HARBOR_ADMIN_PASSWORD de .env) ; analyses : ./lab seed harbor pour les relancer"
}

# Pile lab-demo-harbor : services dont les images viennent de Harbor (localhost:8130/demo/…), pour
# relier services et vulnérabilités dans l'Inventaire Docker. Déployée par Portainer (utilisateur
# glpi-lecture) si la brique portainer est prête, sinon directement.
deploy_demo() {
  docker stack ls --format '{{.Name}}' | grep -qx lab-demo-harbor && return 0
  if [ -n "${LAB_PORTAINER_GLPI_TOKEN:-}" ] && [ -n "${LAB_PORTAINER_ENDPOINT_ID:-}" ] \
     && http_ok -H "X-API-Key: $LAB_PORTAINER_GLPI_TOKEN" "http://localhost:8120/api/endpoints/$LAB_PORTAINER_ENDPOINT_ID"; then
    local pk="X-API-Key: $LAB_PORTAINER_GLPI_TOKEN" swarm body
    swarm=$(curl -fsS -H "$pk" "http://localhost:8120/api/endpoints/$LAB_PORTAINER_ENDPOINT_ID/docker/swarm" | json_get ID)
    body=$("$PY" -c 'import json, sys
print(json.dumps({"name": "lab-demo-harbor", "swarmID": sys.argv[1],
                  "stackFileContent": open(sys.argv[2], encoding="utf-8").read()}))' "$swarm" "$LAB_ROOT_W/stack/demo-harbor.yml")
    curl -fsS -H "$pk" -H 'Content-Type: application/json' -X POST \
      "http://localhost:8120/api/stacks/create/swarm/string?endpointId=$LAB_PORTAINER_ENDPOINT_ID" -d "$body" >/dev/null
    info "pile lab-demo-harbor déployée par Portainer (glpi-lecture)"
  else
    docker stack deploy --detach=true -c "$LAB_ROOT_W/stack/demo-harbor.yml" lab-demo-harbor >/dev/null
    info "pile lab-demo-harbor déployée (sans Portainer : ./lab up portainer puis ./lab seed harbor pour qu'il la voie)"
  fi
}

reset() {
  env_unset LAB_HARBOR_ROBOT_NAME LAB_HARBOR_ROBOT_SECRET
  if docker stack ls --format '{{.Name}}' | grep -qx lab-demo-harbor; then docker stack rm lab-demo-harbor >/dev/null; fi
}

connect() {
  [ -n "${LAB_HARBOR_ROBOT_SECRET:-}" ] || die "compte robot absent : ./lab seed harbor"
  json_obj name="Labo - Harbor" type=harbor url=http://harbor:8130 allow_http:=1 \
    username="$LAB_HARBOR_ROBOT_NAME" api_key="$LAB_HARBOR_ROBOT_SECRET" registry_host="$REG" \
    comment="Harbor 2.15 du labo (glpi-test-lab), projet demo, compte robot en lecture seule, Trivy"
}

"${1:?action attendue : prepare, seed, reset ou connect}"
