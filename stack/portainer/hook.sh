#!/usr/bin/env bash
# Crochet de la brique portainer (voir lib/brique.sh) : mot de passe administrateur, utilisateur
# standard glpi-lecture et son jeton d'API, pile de démonstration lab-demo déployée par Portainer.
# API de Portainer CE (référence officielle) : https://docs.portainer.io/api/docs
#   POST /api/auth, GET /api/endpoints, GET /api/endpoints/{id}/docker/swarm, POST /api/users,
#   PUT /api/endpoints/{id} (UserAccessPolicies), POST /api/users/{id}/tokens (rawAPIKey),
#   GET /api/stacks, POST /api/stacks/create/swarm/string.
# shellcheck disable=SC1091
. "$LAB_ROOT/lib/brique.sh"

API=http://localhost:8120/api

stack_gone() { [ -z "$(docker ps -aq -f "label=com.docker.stack.namespace=$1")" ]; }

login() {
  curl -fsS -X POST "$API/auth" -H 'Content-Type: application/json' \
    -d "$(json_obj username="$1" password="$2")" | json_get jwt
}

prepare() {
  # Lu une seule fois par Portainer, au premier démarrage (volume vide).
  secret_file portainer/admin_password printf '%s' "$LAB_PORTAINER_ADMIN_PASSWORD"
}

seed() {
  wait_for "API Portainer joignable (http://localhost:8120)" 1800 http_ok "$API/system/status"
  local jwt eid swarm uid ujwt
  jwt=$(login admin "$LAB_PORTAINER_ADMIN_PASSWORD")
  pc() { curl -fsS -H "Authorization: Bearer $jwt" "$@"; }
  endpoint() { pc "$API/endpoints" | "$PY" -c 'import sys, json
print(next((str(e["Id"]) for e in json.load(sys.stdin) if e["Name"] == "primary"), ""))'; }
  # L'environnement « primary » est créé au démarrage par -H tcp://tasks.agent:9001.
  has_endpoint() { [ -n "$(endpoint)" ]; }
  wait_for "environnement Swarm « primary » (agent joint)" 900 has_endpoint
  eid=$(endpoint)
  wait_for "Swarm vu par l'agent" 600 pc "$API/endpoints/$eid/docker/swarm"
  swarm=$(pc "$API/endpoints/$eid/docker/swarm" | json_get ID)

  # Utilisateur standard (Portainer CE n'a pas de rôle « lecture seule » : réservé à Business).
  uid=$(pc "$API/users" | "$PY" -c 'import sys, json
print(next((str(u["Id"]) for u in json.load(sys.stdin) if u["Username"] == "glpi-lecture"), ""))')
  if [ -z "$uid" ]; then
    uid=$(pc -X POST "$API/users" -H 'Content-Type: application/json' \
      -d "$(json_obj username=glpi-lecture password="$LAB_PORTAINER_GLPI_PASSWORD" role:=2)" | json_get Id)
    info "utilisateur glpi-lecture créé (rôle standard)"
  fi
  pc -X PUT "$API/endpoints/$eid" -H 'Content-Type: application/json' \
    -d "{\"UserAccessPolicies\":{\"$uid\":{\"RoleId\":0}}}" >/dev/null

  ujwt=$(login glpi-lecture "$LAB_PORTAINER_GLPI_PASSWORD")
  uc() { curl -fsS -H "Authorization: Bearer $ujwt" "$@"; }
  if [ -z "${LAB_PORTAINER_GLPI_TOKEN:-}" ]; then
    env_set LAB_PORTAINER_GLPI_TOKEN "$(uc -X POST "$API/users/$uid/tokens" -H 'Content-Type: application/json' \
      -d "$(json_obj description=glpi-inventaire-docker password="$LAB_PORTAINER_GLPI_PASSWORD")" | json_get rawAPIKey)"
    info "jeton d'API de glpi-lecture créé (LAB_PORTAINER_GLPI_TOKEN dans .env)"
  fi

  # Réseau commun lab-net, créé hors Portainer donc réservé aux administrateurs : rendu public dans
  # Portainer, sinon glpi-lecture ne peut pas y rattacher lab-demo (« forbidden to join this network »).
  local net
  net=$(docker network inspect -f '{{.Id}}' lab-net)
  if ! pc "$API/endpoints/$eid/docker/networks/$net" | "$PY" -c 'import sys, json
rc = (json.load(sys.stdin).get("Portainer") or {}).get("ResourceControl") or {}
sys.exit(0 if rc.get("Public") else 1)'; then
    pc -X POST "$API/resource_controls" -H 'Content-Type: application/json'       -d "{\"ResourceID\":\"$net\",\"Type\":4,\"Public\":true}" >/dev/null
    info "réseau lab-net public dans Portainer"
  fi

  # Pile déployée par Portainer mais en échec (ancienne tentative) : supprimée, puis recréée.
  local failed
  failed=$(uc "$API/stacks" | "$PY" -c 'import sys, json
for s in json.load(sys.stdin):
    if s["Name"] == "lab-demo" and (s.get("DeploymentStatus") or [{}])[-1].get("Status") == 4:
        print(s["Id"])')
  if [ -n "$failed" ]; then
    uc -X DELETE "$API/stacks/$failed?endpointId=$eid" >/dev/null || true
    info "ancienne pile lab-demo en échec supprimée de Portainer"
  fi

  # Pile de démonstration déployée par glpi-lecture : elle lui appartient, il la voit avec son jeton.
  if ! uc "$API/stacks" | "$PY" -c 'import sys, json
sys.exit(0 if any(s["Name"] == "lab-demo" for s in json.load(sys.stdin)) else 1)'; then
    if docker stack ls --format '{{.Name}}' | grep -qx lab-demo; then
      info "lab-demo existe déjà hors Portainer (./lab up demo) : arrêtée puis redéployée par Portainer"
      docker stack rm lab-demo >/dev/null
      wait_for "lab-demo arrêtée" 300 stack_gone lab-demo
    fi
    local body
    body=$("$PY" -c 'import json, sys
print(json.dumps({"name": "lab-demo", "swarmID": sys.argv[1],
                  "stackFileContent": open(sys.argv[2], encoding="utf-8").read()}))' "$swarm" "$LAB_ROOT_W/stack/demo.yml")
    uc -X POST "$API/stacks/create/swarm/string?endpointId=$eid" -H 'Content-Type: application/json' -d "$body" >/dev/null
    info "pile lab-demo déployée par Portainer (utilisateur glpi-lecture)"
  fi
  has_demo() { [ -n "$(docker service ls -q -f label=com.docker.stack.namespace=lab-demo)" ]; }
  wait_for "services de lab-demo créés (sinon : état de la pile dans Portainer)" 600 has_demo
  env_set LAB_PORTAINER_ENDPOINT_ID "$eid"
  info "prêt : http://localhost:8120 (admin, mot de passe LAB_PORTAINER_ADMIN_PASSWORD de .env)"
}

reset() {
  env_unset LAB_PORTAINER_GLPI_TOKEN LAB_PORTAINER_ENDPOINT_ID
  if docker stack ls --format '{{.Name}}' | grep -qx lab-demo; then docker stack rm lab-demo >/dev/null; fi
}

connect() {
  [ -n "${LAB_PORTAINER_GLPI_TOKEN:-}" ] || die "jeton absent : ./lab seed portainer"
  json_obj name="Labo - Portainer" type=portainer url=http://portainer:9000 allow_http:=1 \
    api_key="$LAB_PORTAINER_GLPI_TOKEN" \
    comment="Portainer CE du labo (glpi-test-lab), utilisateur standard glpi-lecture, pile lab-demo"
}

"${1:?action attendue : prepare, seed, reset ou connect}"
