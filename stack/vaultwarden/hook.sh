#!/usr/bin/env bash
# Crochet de la brique vaultwarden (voir lib/brique.sh) : outils jetables (image construite sur le
# poste), puis organisation « Labo GRC » factice créée par seed.py.
# Page d'administration : https://github.com/dani-garcia/vaultwarden/wiki/Enabling-admin-page
# shellcheck disable=SC1091
. "${LAB_ROOT:-.}/lib/brique.sh"

DIR=$LAB_ROOT_W/stack/vaultwarden
BW_VERSION=${LAB_BW_CLI_VERSION:-2026.10.1}
OUTILS=lab-vaultwarden-outils:$BW_VERSION

# Image des outils (bw, jq, Python et cryptography), construite une fois par version de bw.
outils_image() {
  docker image inspect "$OUTILS" >/dev/null 2>&1 && return 0
  info "construction de l'image $OUTILS (bw $BW_VERSION, une seule fois)"
  docker build -q --build-arg "BW_VERSION=$BW_VERSION" -t "$OUTILS" "$DIR/outils" >/dev/null
}

# Lance une commande dans les outils, sur lab-net, avec les scripts en lecture seule, l'autorité
# locale (secrets/vaultwarden, monté en écriture pour `seed.py certs` seulement) et le secret TOTP
# de la propriétaire (secrets/vaultwarden-2fa, hors de l'empreinte des secrets Swarm) :
# outils <options docker…> -- <commande…>.
outils() {
  local opts=() tls=ro
  while [ "$1" != -- ]; do opts+=("$1"); shift; done
  shift
  [ "${1:-} ${3:-}" = "python3 certs" ] && tls=rw
  mkdir -p "$LAB_SECRETS_DIR/vaultwarden" "$LAB_SECRETS_DIR/vaultwarden-2fa"
  tool lab-net --read-only --tmpfs /home/node:uid=1000,gid=1000 --tmpfs /tmp \
    -v "$DIR:/outils:ro" -v "$LAB_SECRETS_DIR/vaultwarden:/tls:$tls" \
    -v "$LAB_SECRETS_DIR/vaultwarden-2fa:/secrets" \
    -e VW_URL=https://vaultwarden:80 -e NODE_EXTRA_CA_CERTS=/tls/ca.pem \
    -e "VW_PASSWORD=$LAB_VAULTWARDEN_DEMO_PASSWORD" \
    "${opts[@]}" "$OUTILS" "$@"
}

# Certificats TLS (l'interface « bw » refuse HTTP) : autorité locale et certificat du serveur.
prepare() {
  outils_image
  outils -- python3 /outils/seed.py certs
}

seed() {
  wait_for "Vaultwarden joignable (https://localhost:8150)" 1200 \
    http_ok --ssl-no-revoke --cacert "$LAB_SECRETS_DIR/vaultwarden/ca.pem" https://localhost:8150/alive
  outils_image
  outils -e "VW_ADMIN_TOKEN=$LAB_VAULTWARDEN_ADMIN_PASSWORD" -- python3 /outils/seed.py
  info "prêt : https://localhost:8150 (claire.martin@labo-grc.example, LAB_VAULTWARDEN_DEMO_PASSWORD de .env ; autorité : secrets/vaultwarden/ca.pem) ; export : bash stack/vaultwarden/hook.sh export"
}

# Export CSV des membres et des éléments de l'organisation, au format de GRC, sans aucun secret :
# bash stack/vaultwarden/hook.sh export [dossier] (par défaut $LAB_DATA_DIR/vaultwarden).
export_csv() {
  local out=${1:-${LAB_DATA_DIR:-F:/Dev/glpi-test-lab-data}/vaultwarden}
  mkdir -p "$out"
  out=$( (cd "$out" && pwd -W) 2>/dev/null || echo "$out")
  outils_image
  outils -v "$out:/export" -- sh /outils/export.sh /export
  info "export écrit dans $out (membres.csv, elements.csv)"
}

# Les secrets TOTP d'une organisation effacée ne servent plus.
reset() { rm -f "$LAB_SECRETS_DIR"/vaultwarden-2fa/totp-*; }
# Pas de connexion GLPI : GRC importe les exports CSV (Vaultwarden n'a pas l'API publique
# d'organisation de Bitwarden). Essai de bout en bout : stack/vaultwarden/grc/essai.sh.
connect() { :; }

case "${1:?action attendue : prepare, seed, reset, connect ou export}" in
  export) shift; export_csv "$@" ;;
  *) "$1" ;;
esac
